(* pp islands — content-addressed remote/local modules.

   An island is a module that lives elsewhere, referenced by URI and pinned
   INLINE in the island form by the canonical content hash of its source
   tree:

     (island file:./lib "a1b2…64hex")
     (island <github:owner/repo#ref> "a1b2…64hex")

   The pin is part of the code — `Identity.hash_expr` folds uri+pin — so island
   identity is structural (LAW 20): no lockfile, no synthetic trace cell,
   and a pinned island form is a CLOSED expression (paste it anywhere, it
   denotes the same bytes). Refs (`#main`) live in the URI and matter only
   at fetch time; the pin argument must be the 64-hex content hash.

   ~/.pp/islands is a pure content-addressed cache:

     ~/.pp/islands/
       index        — append-only resolution log (advisory, never authoritative)
       src/<pin>/   — immutable materialized tree; entry.pp is the module root

   Resolution NEVER touches the network. Fetching (git:/github:) happens
   only under --fetch-islands / --update (Island.fetch_enabled) —
   the loader's runtime authority (LAW 24), not a user capability. An
   unpinned island form is a hard error naming the fix: eval stays pure and
   hermetic; the only impure step lives in `pp --update`. *)

open Core_model

let fetch_enabled = ref false

let update_mode = ref false  (* --update: re-resolve and rewrite inline pins *)

(* ---- URI surface ---- *)

type scheme = SFile | SGit | SGitHub

type uri = {
  scheme : scheme;
  raw : string;              (* as written in the island form *)
  locator : string;          (* path (file:) / url (git:) / owner/repo (github:) *)
  ref_hint : string option;  (* after '#'; used only at fetch/update time *)
}

let parse_uri (raw : string) : uri =
  let strip prefix =
    if String.starts_with ~prefix raw then
      Some (String.sub raw (String.length prefix)
              (String.length raw - String.length prefix))
    else None
  in
  let split_ref s =
    match String.index_opt s '#' with
    | Some i ->
        (String.sub s 0 i,
         Some (String.sub s (i + 1) (String.length s - i - 1)))
    | None -> (s, None)
  in
  let make scheme rest =
    let locator, ref_hint = split_ref rest in
    if locator = "" then failwith ("island: empty locator in URI: " ^ raw);
    { scheme; raw; locator; ref_hint }
  in
  match strip "file:" with
  | Some rest -> make SFile rest
  | None ->
  match strip "git:" with
  | Some rest -> make SGit rest
  | None ->
  match strip "github:" with
  | Some rest -> make SGitHub rest
  | None ->
      failwith ("island: unknown scheme in URI: " ^ raw
                ^ " (expected file:, git:, or github:)")

(* A pin is the 64-hex canonical tree hash — anything else in pin position
   is an error (refs go in the URI after '#'). *)
let is_pin (s : string) : bool =
  String.length s = 64
  && String.for_all (fun c ->
       (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) s

let short (p : string) : string =
  if String.length p > 12 then String.sub p 0 12 else p

(* ---- The content-addressed cache ---- *)

let islands_root () =
  let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
  Filename.concat (Filename.concat home ".pp") "islands"

let cache_src_root () = Filename.concat (islands_root ()) "src"
let cached_tree (pin : string) = Filename.concat (cache_src_root ()) pin

(* One hasher in the project: the pin IS Store.tree_hash (the same canonical
   tree digest the `run` effect's coarse cells use). Don't invent a second. *)
let canonical_tree_hash (dir : string) : string = Store.tree_hash dir

let verify_pin ~(dir : string) ~(pin : string) : (unit, string) result =
  let h = canonical_tree_hash dir in
  if h = pin then Ok () else Error h

(* Advisory resolution log — fetch history for `pp island-pins`/debugging.
   Never consulted to decide a pin: the source text is the only authority. *)
let log_resolution ~(uri : string) ~(pin : string) : unit =
  try
    Store.ensure_dir (islands_root ());
    let oc = open_out_gen [Open_append; Open_creat] 0o644
               (Filename.concat (islands_root ()) "index") in
    Printf.fprintf oc "%s\t%s\t%.0f\n" uri pin (Unix.time ());
    close_out oc
  with _ -> ()

let rm_rf (path : string) : unit =
  let entries = ref [] in
  Fswalk.walk ~root:path ~cb:(fun ~rel:_ ~path visit ->
    match visit with
    | Fswalk.Entry st -> entries := (path, st.Unix.st_kind = Unix.S_DIR) :: !entries
    | _ -> ());
  List.iter (fun (p, is_dir) ->
    try if is_dir then Unix.rmdir p else Sys.remove p with _ -> ())
    (List.rev !entries)

(* Copy a source tree into the cache. Regular files and directories only:
   anything else would make the copy's tree hash lie about the source. *)
let rec copy_tree (src : string) (dst : string) : unit =
  match (Unix.lstat src).Unix.st_kind with
  | Unix.S_DIR ->
      Store.ensure_dir dst;
      let names = Sys.readdir src in
      Array.sort compare names;
      Array.iter (fun n ->
        copy_tree (Filename.concat src n) (Filename.concat dst n)) names
  | Unix.S_REG ->
      let ic = open_in_bin src in
      let content = really_input_string ic (in_channel_length ic) in
      close_in ic;
      let oc = open_out_bin dst in
      output_string oc content;
      close_out oc;
      (* Preserve the exec bit (does not affect the tree hash). *)
      (try
         let perm = (Unix.stat src).Unix.st_perm in
         if perm land 0o111 <> 0 then Unix.chmod dst perm
       with _ -> ())
  | _ ->
      failwith ("island: unsupported file kind in island source: " ^ src)

(* Materialize [src_dir] into the cache and return its pin. Idempotent: an
   existing entry with the same pin is reused. Publication is atomic
   (copy to temp, re-hash the copy, rename), so a crash never leaves a
   half-tree at src/<pin>/. *)
let materialize ~(uri : string) ~(src_dir : string) : string =
  if not (Sys.file_exists src_dir && Sys.is_directory src_dir) then
    failwith ("island: source is not a directory: " ^ uri
              ^ " (" ^ src_dir ^ ")");
  let pin = canonical_tree_hash src_dir in
  let dst = cached_tree pin in
  if not (Sys.file_exists dst) then begin
    Store.ensure_dir (cache_src_root ());
    let tmp = dst ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
    rm_rf tmp;
    (try copy_tree src_dir tmp with e -> rm_rf tmp; raise e);
    (match verify_pin ~dir:tmp ~pin with
     | Ok () -> ()
     | Error h ->
         rm_rf tmp;
         failwith (Printf.sprintf
           "island: source for %s changed while copying (%s vs %s)"
           uri (short pin) (short h)));
    (try Unix.rename tmp dst
     with _ -> rm_rf tmp (* lost a benign race: same content already there *))
  end;
  log_resolution ~uri ~pin;
  pin

(* ---- Fetch (git:/github:) — runtime authority, opt-in (LAW 24, §3.5) ---- *)

(* Clone the URI's ref into a temp dir with git's plumbing only (no hooks:
   --template= gives an empty template dir, and clone never runs the
   remote's hooks), strip .git, and materialize the tree. See
   docs/THREAT-MODEL-islands.md. *)
let fetch_git (u : uri) : string =
  if not !fetch_enabled then
    failwith ("island: fetching is disabled; run pp --fetch-islands (or --update) for "
              ^ u.raw);
  let url = match u.scheme with
    | SGitHub -> "https://github.com/" ^ u.locator
    | SGit -> u.locator
    | SFile -> failwith "island: internal: fetch_git on a file: URI"
  in
  let tmp = Filename.temp_file "pp-island" "" in
  Sys.remove tmp;  (* reuse the unique name as a directory *)
  let cleanup () = rm_rf tmp in
  Fun.protect ~finally:cleanup (fun () ->
    let (code, _out, err) =
      Process.exec ["git"; "clone"; "--quiet"; "--template="; url; tmp] in
    if code <> 0 then
      failwith ("island: git clone failed for " ^ u.raw ^ ": " ^ String.trim err);
    (match u.ref_hint with
     | Some r ->
         let (code, _out, err) =
           Process.exec ["git"; "-C"; tmp; "checkout"; "--quiet"; r] in
         if code <> 0 then
           failwith ("island: git checkout of ref " ^ r ^ " failed for "
                     ^ u.raw ^ ": " ^ String.trim err)
     | None -> ());
    rm_rf (Filename.concat tmp ".git");
    let pin = materialize ~uri:u.raw ~src_dir:tmp in
    Journal.append (Journal.IslandFetch { uri = u.raw; pin });
    pin)

(* Fetch/derive a fresh pin for a URI — the impure step behind `pp --update`
   (and first-fetch). file: re-hashes the local source dir; git:/github:
   clone the ref. *)
let repin (u : uri) : string =
  match u.scheme with
  | SFile -> materialize ~uri:u.raw ~src_dir:u.locator
  | SGit | SGitHub -> fetch_git u

(* ---- Resolution: pin -> immutable cached tree (never the network) ---- *)

let unpinned_error (u : uri) : 'a =
  failwith ("island: no pin for " ^ u.raw ^ "; run pp --update")

(* Resolve an island form to the directory of its pinned tree. Verifies the
   cache against the pin on every resolve (tamper check). For file: URIs a
   missing cache entry may be filled from the local source dir — but only
   when the source hashes to the pin exactly, so the fill cannot change what
   the pin denotes. git:/github: cache misses fetch only under
   --fetch-islands, and the fetched content must match the pin. *)
let resolve ~(uri : string) ~(pin : string option) : string =
  let u = parse_uri uri in
  match pin with
  | None -> unpinned_error u
  | Some p when not (is_pin p) ->
      failwith ("island: pin for " ^ u.raw
                ^ " must be a 64-hex content hash, got \"" ^ p
                ^ "\" (refs go in the URI: <scheme:locator#ref>)")
  | Some p ->
      let dir = cached_tree p in
      if Sys.file_exists dir then begin
        (match verify_pin ~dir ~pin:p with
         | Ok () -> ()
         | Error h ->
             failwith (Printf.sprintf
               "island: cache tamper detected for %s: src/%s now hashes %s"
               u.raw (short p) (short h)));
        (* Drift visibility (`pp why`): the pin still governs, but tell the
           user when the local source has moved past it. *)
        (if !Store.why_mode && u.scheme = SFile
            && Sys.file_exists u.locator && Sys.is_directory u.locator then
           match verify_pin ~dir:u.locator ~pin:p with
           | Ok () -> ()
           | Error h ->
               Store.why "island %s: source dir now hashes %s but the pin is %s — run pp --update"
                 u.raw (short h) (short p));
        dir
      end
      else begin
        match u.scheme with
        | SFile ->
            if not (Sys.file_exists u.locator) then
              failwith ("island: pin " ^ short p ^ " not cached and source missing for "
                        ^ u.raw);
            (match verify_pin ~dir:u.locator ~pin:p with
             | Ok () -> ignore (materialize ~uri:u.raw ~src_dir:u.locator); dir
             | Error h ->
                 failwith (Printf.sprintf
                   "island: source dir for %s hashes %s but the pin is %s — run pp --update to re-pin"
                   u.raw (short h) (short p)))
        | SGit | SGitHub ->
            if not !fetch_enabled then
              failwith ("island: pin " ^ short p ^ " for " ^ u.raw
                        ^ " is not in the cache; run pp --fetch-islands")
            else begin
              let fetched = fetch_git u in
              if fetched <> p then
                failwith (Printf.sprintf
                  "island: fetched %s for %s but the pin is %s — the ref moved; \
                   run pp --update to accept the new content"
                  (short fetched) u.raw (short p));
              dir
            end
      end

(* The module root inside a pinned tree. entry.pp is brace surface
   (the default), entry.ppb a permanent brace alias, entry.ppl the sexpr/AST
   surface — all fully supported; entry.pp wins when several exist. The
   reader is chosen by extension (Reader_braces.read_dispatch), so a pinned
   tree may ship whichever surface it was authored in. *)
let entry_file (tree_dir : string) : string =
  let e = Filename.concat tree_dir "entry.pp" in
  if Sys.file_exists e then e
  else
    let eb = Filename.concat tree_dir "entry.ppb" in
    if Sys.file_exists eb then eb
    else
      let el = Filename.concat tree_dir "entry.ppl" in
      if Sys.file_exists el then el
      else failwith ("island: pinned tree has no entry.pp: " ^ tree_dir)

(* ---- Syntactic walk: every island form in an expression ---- *)

let rec islands_in (e : expr) : (string * string option) list =
  match e with
  | EIsland (uri, pin) -> [(uri, pin)]
  | ELiteral _ | ESymbol _ | ELoad _ | ELoadModule _ -> []
  | EIf (a, b, c) -> islands_in a @ islands_in b @ islands_in c
  | ELet (bs, b) | ELetStar (bs, b) ->
      List.concat_map (fun (_, e) -> islands_in e) bs @ islands_in b
  | EFn (_, b) | EDef (_, _, b) | EDefNode (_, _, b) -> islands_in b
  | EApply (f, args) -> islands_in f @ List.concat_map islands_in args
  | EQuote _ -> []  (* quoted data is not evaluated *)
  | EForce e | EDelay e | ENode e | EDefValue (_, e) | EImport e
  | ELocated (_, e) -> islands_in e
  | EDo es | EModule es -> List.concat_map islands_in es
  | EWithCaps (a, b) | EWithConfig (a, b) | ETyped (a, b) ->
      islands_in a @ islands_in b
  | EPerform (_, args) -> List.concat_map islands_in args
  | EWithHandler (hs, b) ->
      List.concat_map (fun (_, h) -> islands_in h) hs @ islands_in b
  | EConfig (k, d) ->
      islands_in k @ (match d with Some d -> islands_in d | None -> [])
  | EMatch (scrutinee, arms) ->
      islands_in scrutinee @ List.concat_map (fun (_, guard, body) ->
        (match guard with Some g -> islands_in g | None -> []) @ islands_in body) arms

(* ---- `pp --update`: rewrite inline pins in a source file ----

   Conservative textual splice. For each island form: derive the fresh pin
   (repin), then
     - pinned form: replace every token-delimited occurrence of the old pin
       (same pin string ⇒ same content ⇒ same new pin);
     - unpinned form: find the unique occurrence of the URI as written and
       insert the pin (as a quoted string) before the form's closing paren.
   Any ambiguity ⇒ print the exact replacement and make no change to that
   form — never half-write a file. Returns (updated, skipped). *)

let is_token_char (c : char) : bool =
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  || c = '-' || c = '_' || c = ':' || c = '.' || c = '/' || c = '#'

let find_delimited (hay : string) (needle : string) : int list =
  let n = String.length needle and h = String.length hay in
  let rec go i acc =
    if i + n > h then List.rev acc
    else if String.sub hay i n = needle
            && (i = 0 || not (is_token_char hay.[i - 1]))
            && (i + n = h || not (is_token_char hay.[i + n]))
    then go (i + n) (i :: acc)
    else go (i + 1) acc
  in
  go 0 []

let splice (text : string) (at : int) (len : int) (replacement : string) : string =
  String.sub text 0 at ^ replacement
  ^ String.sub text (at + len) (String.length text - at - len)

let update_file (path : string) : int * int =
  let ic = open_in_bin path in
  let original = really_input_string ic (in_channel_length ic) in
  close_in ic;
  let exprs = Reader_braces.read_dispatch ~source:path ~path original in
  let forms =
    List.sort_uniq compare (List.concat_map islands_in exprs) in
  let text = ref original in
  let updated = ref 0 and skipped = ref 0 in
  let skip uri msg suggestion =
    incr skipped;
    Printf.eprintf "[update] %s: %s\n  apply by hand: %s\n%!" uri msg suggestion
  in
  List.iter (fun (uri, old_pin) ->
    let u = parse_uri uri in
    let fresh = repin u in
    match old_pin with
    | Some p when p = fresh -> ()  (* already current *)
    | Some p when is_pin p ->
        (match find_delimited !text p with
         | [] ->
             skip uri "old pin not found in file text"
               ("replace " ^ short p ^ "… with " ^ fresh)
         | _ :: _ ->
             (* Replace every delimited occurrence: same pin = same content,
                so every occurrence re-pins to the same fresh hash. *)
             let rec replace_all t =
               match find_delimited t p with
               | at :: _ -> replace_all (splice t at (String.length p) fresh)
               | [] -> t
             in
             text := replace_all !text;
             incr updated)
    | Some p ->
        skip uri ("existing pin argument is not a 64-hex hash: " ^ p)
          ("write (island " ^ uri ^ " \"" ^ fresh ^ "\")")
    | None ->
        (* Insert after the URI as written. Try the delimited forms first
           (<uri>, "uri") — a bare-URI search would also match INSIDE them —
           and use the first candidate with exactly one hit. *)
        let candidates = ["<" ^ uri ^ ">"; "\"" ^ uri ^ "\""; uri] in
        let hit =
          List.fold_left (fun acc c ->
            match acc with
            | Some _ -> acc
            | None ->
                (match find_delimited !text c with
                 | [at] -> Some (at, String.length c)
                 | _ -> None))
            None candidates
        in
        (match hit with
         | Some (at, len) ->
             (match String.index_from_opt !text (at + len) ')' with
              | Some close ->
                  (* The argument separator is surface-specific —
                     brace files (island("URI", "PIN")) take a comma, sexpr
                     files ((island URI "PIN")) plain whitespace. *)
                  let sep =
                    if Reader_braces.file_uses_braces path then ", " else " " in
                  text := splice !text close 0 (sep ^ "\"" ^ fresh ^ "\"");
                  incr updated
              | None -> skip uri "no closing paren found after URI"
                          ("add pin \"" ^ fresh ^ "\" to the form"))
         | None -> skip uri "URI not found uniquely in file text"
                     ("add pin \"" ^ fresh ^ "\" to the form")))
    forms;
  if !text <> original then begin
    let tmp = path ^ ".pp-update." ^ string_of_int (Unix.getpid ()) in
    let oc = open_out_bin tmp in
    output_string oc !text;
    close_out oc;
    Unix.rename tmp path
  end;
  (!updated, !skipped)

(* ---- `pp island-pins`: list island forms + cache status ---- *)

let print_pins (path : string) : unit =
  let ic = open_in_bin path in
  let source = really_input_string ic (in_channel_length ic) in
  close_in ic;
  let exprs = Reader_braces.read_dispatch ~source:path ~path source in
  let forms = List.sort_uniq compare (List.concat_map islands_in exprs) in
  if forms = [] then Printf.printf "(no island forms in %s)\n" path
  else
    List.iter (fun (uri, pin) ->
      match pin with
      | None -> Printf.printf "%s\t(unpinned)\n" uri
      | Some p when not (is_pin p) ->
          Printf.printf "%s\t(invalid pin: %s)\n" uri p
      | Some p ->
          let dir = cached_tree p in
          let status =
            if not (Sys.file_exists dir) then "uncached"
            else match verify_pin ~dir ~pin:p with
              | Ok () -> "cached"
              | Error _ -> "TAMPERED"
          in
          Printf.printf "%s\t%s\t%s\n" uri p status)
      forms
