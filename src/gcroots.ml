(* pp GC roots manifest — M5 stage C Store GC (docs/PLAN-m5-distribution.md
   "Store GC"): "roots: the last N epochs' desired-state root hashes".

   NOT the frozen journal grammar: journal.ml's `Epoch` entry is the
   append-only, never-rotated, greppable audit-log record of a pass's root
   hash — this is GC's OWN bookkeeping, capped to the last
   [Runtime.gc_keep_epochs] entries, recording enough to REPLAY a root
   program (files, --grant specs, --bytecode, --reconcile/--supervise/
   --member-name/--desired-object) — mark-by-replay's load-bearing
   precondition (the contract's own finding: traces do not record
   child-keys, so there is no on-disk node graph to walk; the only way to
   discover which store artifacts a root's closure actually touches is to
   re-run the SAME program, not merely remember a hash).

   One line per root, a plain Codec-encoded (Types.value) VMap — reusing
   the store's own canonical text codec rather than inventing a third
   bespoke line grammar (store.ml's trace lines and token.ml's token line
   already are two; this is data all the way down, so Codec fits directly,
   no hand-rolled parser needed). *)

open Types

let roots_path () : string = Filename.concat Store.store_root "gc-roots"

type root = {
  gr_hash : string;
  gr_bytecode : bool;
  gr_grants : string list;
  gr_files : string list;
  gr_reconcile_root : string option;
  gr_supervise : bool;
  gr_member_name : string option;
  gr_desired_object : (string * string) option;  (* (hash, shared-root) *)
}

let strs_to_value (l : string list) : value =
  VVector (Array.of_list (List.map (fun s -> VString s) l))

let value_to_strs (v : value) : string list =
  match v with
  | VVector arr ->
      Array.to_list arr
      |> List.filter_map (function VString s -> Some s | _ -> None)
  | _ -> []

let opt_to_value = function None -> VNil | Some s -> VString s
let value_to_opt = function VString s -> Some s | _ -> None

let root_to_value (r : root) : value =
  VMap [
    (VKeyword "hash", VString r.gr_hash);
    (VKeyword "bytecode", VBool r.gr_bytecode);
    (VKeyword "grants", strs_to_value r.gr_grants);
    (VKeyword "files", strs_to_value r.gr_files);
    (VKeyword "reconcile-root", opt_to_value r.gr_reconcile_root);
    (VKeyword "supervise", VBool r.gr_supervise);
    (VKeyword "member-name", opt_to_value r.gr_member_name);
    (VKeyword "desired-object",
     match r.gr_desired_object with
     | None -> VNil
     | Some (h, root) -> VVector [| VString h; VString root |]);
  ]

let value_to_root (v : value) : root option =
  match v with
  | VMap kvs ->
      let find k = List.assoc_opt (VKeyword k) kvs in
      let bool_of = function Some (VBool b) -> b | _ -> false in
      (match find "hash" with
       | Some (VString hash) ->
           let desired_object = match find "desired-object" with
             | Some (VVector [| VString h; VString root |]) -> Some (h, root)
             | _ -> None
           in
           Some {
             gr_hash = hash;
             gr_bytecode = bool_of (find "bytecode");
             gr_grants = (match find "grants" with Some v -> value_to_strs v | None -> []);
             gr_files = (match find "files" with Some v -> value_to_strs v | None -> []);
             gr_reconcile_root =
               (match find "reconcile-root" with Some v -> value_to_opt v | None -> None);
             gr_supervise = bool_of (find "supervise");
             gr_member_name =
               (match find "member-name" with Some v -> value_to_opt v | None -> None);
             gr_desired_object = desired_object;
           }
       | _ -> None)
  | _ -> None

let read_all () : root list =
  let path = roots_path () in
  if not (Sys.file_exists path) then []
  else
    String.split_on_char '\n' (Store.read_raw path)
    |> List.filter (fun l -> l <> "")
    |> List.filter_map (fun line ->
         match Codec.decode_value line with
         | Some v -> value_to_root v
         | None -> None)

(* Append [r], then drop everything but the last [keep] lines (oldest
   first, so the tail is the most recent) — GC's own retention policy, NOT
   an audit trail (unlike journal.ml's Epoch, which never rotates). *)
let record ~(keep : int) (r : root) : unit =
  Store.ensure_dir Store.store_root;
  let existing =
    let path = roots_path () in
    if Sys.file_exists path then
      String.split_on_char '\n' (Store.read_raw path) |> List.filter (fun l -> l <> "")
    else []
  in
  match Codec.encode_value (root_to_value r) with
  | None -> ()  (* every field here is plain data; unreachable in practice *)
  | Some line ->
      let updated = existing @ [line] in
      let n = List.length updated in
      let kept = if keep > 0 && n > keep then
          List.filteri (fun i _ -> i >= n - keep) updated
        else updated
      in
      Store.atomic_write (roots_path ()) (String.concat "\n" kept ^ "\n")
