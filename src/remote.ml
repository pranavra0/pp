(* pp remote placement — dispatches a batch of node misses to a named
   cluster member over the cluster transport (transport/tokens/sync live in
   src/transport.ml + src/token.ml).

   Wires Scheduler's [Remote member] policy to that transport: this
   module is compiled AFTER Evaluator, Transport, and Token (all three sit
   ABOVE Scheduler in the dependency graph — Transport calls
   Evaluator.cell_authorized_for, and Evaluator calls Scheduler — so this
   is the one place that can call all four), and wires itself into
   [Scheduler.remote_dispatch_hook] at [init] time, exactly the
   cycle-breaking indirection evaluator.ml already uses for
   Primitives.*_ref.

   THE CORE MOVE: a cluster member is a SEPARATE `pp` process with its own
   $HOME (Store.store_root is a process-wide singleton — see transport.ml's
   header). Rather than inventing a "force only key K" wire protocol
   (which would need a derivation/eval split the scheduler's process-pool
   design deliberately avoids elsewhere too), the member is simply handed the SAME top-level
   program (byte-identical source; both sides are ordinary files on the
   CI-loopback's shared disk, or scp'd identically in a real deployment)
   and runs it as an ordinary `pp` invocation, under `--schedule serial` —
   so it calls Evaluator.run_node_body itself, via its OWN completely
   normal main.ml control flow, no second "evaluate on member" function
   anywhere. Whatever nodes that run forces (our assigned batch keys, plus
   duplicate computation across machines is SOUND by determinism, LAW 37)

   land in the member's OWN store; the dispatcher then pulls each assigned
   key back via the serve-hit/recv-hit pair — the same
   re-hash-on-receive choke point every other synced artifact goes
   through. *)

open Types
open Codec

(* ---- Members file: ambient config, never --grant (contract: an address
   is not an authority ceiling — LAW 34's own distinction). One member per
   line, "<name> <store-root-path>" — the store-root is what
   Transport.LocalDir treats as its abstract [t] (conventionally another
   node's own $HOME/.pp/store). Blank lines and '#' comments ignored. *)

let members_path () : string =
  match Sys.getenv_opt "PP_CLUSTER_MEMBERS" with
  | Some p -> p
  | None -> Filename.concat (Sys.getenv "HOME") ".pp/cluster/members"

let load_members () : (string * string) list =
  let path = members_path () in
  if not (Sys.file_exists path) then []
  else
    String.split_on_char '\n' (Store.read_raw path)
    |> List.filter_map (fun line ->
         let line = String.trim line in
         if line = "" || line.[0] = '#' then None
         else
           match String.split_on_char ' ' line |> List.filter (fun s -> s <> "") with
           | name :: root :: _ -> Some (name, root)
           | _ -> None)

let find_member_root (name : string) : string option =
  List.assoc_opt name (load_members ())

(* A member's $HOME is needed to spawn its `pp` subprocess (a distinct
   process environment, not merely a distinct transport target); derived by
   stripping store.ml's own, exact, well-known suffix rather than guessed —
   a members-file entry that doesn't follow the convention fails loudly
   (degrading that dispatch to local, per the caller) instead of spawning
   a subprocess against the wrong tree. *)
let store_suffix = ".pp/store"

let member_home_of_root (root : string) : (string, string) result =
  let root =
    let n = String.length root in
    if n > 0 && root.[n - 1] = '/' then String.sub root 0 (n - 1) else root
  in
  let slen = String.length store_suffix and rlen = String.length root in
  if rlen > slen + 1 && String.sub root (rlen - slen) slen = store_suffix then
    Ok (String.sub root 0 (rlen - slen - 1))
  else
    Error (Printf.sprintf
      "member store root %s does not end in /%s — cannot derive its $HOME"
      root store_suffix)

(* ---- Wire format for the pre-seed pin list ----
   "(pin \"CELL-ID\" \"BLOB-HASH\")" per line — the same hand-rolled,
   quoted-string style token.ml/transport.ml already use for their own
   bespoke line formats (Codec.quote_string/parse_quoted_string reused,
   not a new escaping dialect). *)

let quote = Codec.quote_string

let pin_line (cell : string) (hash : string) : string =
  Printf.sprintf "(pin %s %s)\n" (quote cell) (quote hash)


let parse_pin_line (line : string) : (string * string) option =
  expect_lit line 0 "(pin " >>= fun i ->
  Codec.parse_quoted_string line i >>= fun (cell, i) ->
  expect_char line i ' ' >>= fun i ->
  Codec.parse_quoted_string line i >>= fun (hash, i) ->
  expect_char line i ')' >>= fun _ -> Some (cell, hash)

(* ---- `(pin-probe "NAME" <codec-value>)` ----
   Generalizes the pin file
   to cover a probe's OWN value directly (not a blob-backed cell), so a
   program that folds `(probe NAME)` into its desired state can be pinned
   too. The value half is not a quoted string — it is Codec.encode_value's
   own grammar (e.g. "(i 42)", "(s \"x\")") embedded verbatim, since that
   grammar is already a well-formed, self-delimiting parenthesized token
   stream; wrapping it in ANOTHER quoted-string layer would just be a
   second, redundant escaping dialect for the same bytes. [line] must have
   already been trimmed (no trailing newline) by the caller, exactly like
   [parse_pin_line] assumes. *)
let pin_probe_line (name : string) (value_text : string) : string =
  Printf.sprintf "(pin-probe %s %s)\n" (quote name) value_text

let parse_pin_probe_line (line : string) : (string * string) option =
  expect_lit line 0 "(pin-probe " >>= fun i ->
  Codec.parse_quoted_string line i >>= fun (name, i) ->
  expect_char line i ' ' >>= fun i ->
  let n = String.length line in
  if n > 0 && i <= n - 1 && line.[n - 1] = ')' then
    Some (name, String.sub line i (n - 1 - i))
  else None

(* ---- Member side: pre-seed observation pins from the wire BEFORE anything
   runs — the soundness crux of remote placement ----

   [read_file_cell]/[observe_cell] (store.ml) both consult [run_pins]
   FIRST, unconditionally, before ever touching disk for a `file:` cell —
   that check already exists and is untouched by this module. Populating
   [run_pins] here, before [run_files] ever executes a single expression,
   means the FIRST observation of every pre-seeded cell finds a pin already
   present: the code path that would read this member's own disk for that
   cell is structurally unreachable, not merely avoided by convention. A
   member that never received a pin for some OTHER cell still observes its
   own disk for that cell — untouched: `tool:` cells are
   deliberately NOT pre-seeded, since the member's own toolchain is a
   legitimate distinct observation.

   The dispatcher pushes each pinned blob DIRECTLY into this member's own
   store before ever spawning it ([ship_and_pull]'s [push_blob] call below,
   straight into member_store_root — the push direction is the TRUSTED one
   in this threat model, verified against local content before writing,
   same as every other LocalDir push), so by the time this member process
   starts, the blob already sits in ITS OWN blobs/ dir — nothing to pull
   over a transport from here. What this function still re-verifies,
   belt-and-suspenders, is that the blob's bytes actually hash to the
   claimed name before trusting it as a pin (the same re-hash-before-trust
   discipline every other synced artifact gets, applied to a same-machine
   direct write instead of a pull).

   A `(pin-probe "NAME" <value>)` line is handled the same
   pass, populating the session's probe cache directly — no blob, no
   CAS, no re-hash-before-trust step, since the value's bytes travel
   in-line in the pin file itself rather than by content-addressed
   reference. [probe_value_for] (primitives.ml) consults
   probe cache first, unconditionally, before ever calling a
   registered probe's observe-fn — so a pre-seeded entry here short-
   circuits the observe-fn for the whole pass exactly like an
   already-observed value would mid-pass.

   Also called directly by main.ml's standalone `--pin-file` flag —
   the SAME function, sans the --remote-node token/keys/reply
   ceremony (which was always separate wiring in main.ml, never part of
   this function's own signature). *)
let preseed_pins_from_file ~(pins_file : string) : unit =
  if Sys.file_exists pins_file then
    String.split_on_char '\n' (Store.read_raw pins_file)
    |> List.iter (fun line ->
         let line = String.trim line in
         if line <> "" then
           if String.length line >= 11 && String.sub line 0 11 = "(pin-probe " then
             match parse_pin_probe_line line with
             | None -> failwith ("pp: --pin-file: unparseable pin-probe line: " ^ line)
             | Some (name, value_text) ->
                 (match Codec.decode_value value_text with
                  | None ->
                      failwith ("pp: --pin-file: pin-probe " ^ name
                                ^ ": undecodable value: " ^ value_text)
                  | Some v -> Session.set_probe (Effect.perform Dynamic_scope.Get_session) name v)
           else
             match parse_pin_line line with
             | None -> failwith ("pp: --pin-file: unparseable pin line: " ^ line)
             | Some (cell, hash) ->
                 (match Store.load_blob hash with
                  | None ->
                      failwith (Printf.sprintf
                        "pp: --pin-file: pinned blob %s not found in this \
                         process's own store (a --remote-node member expects \
                         the dispatcher to have pushed it directly before \
                         spawning; a plain --pin-file expects the blob \
                         already present locally)" hash)
                  | Some content ->
                      if Hasher.hash_string content <> hash then
                        failwith (Printf.sprintf
                          "pp: --pin-file: blob %s failed to re-verify \
                           (corrupt) — refusing to pin" hash)
                      else Session.set_run_pin (Effect.perform Dynamic_scope.Get_session) cell hash))

(* ---- "blob:<hash>" refs embedded in a node's RESULT value ----

   The `blob`/`blob-get` pair (primitives.ml) is deliberately NOT a traced
   cell — a node's small metadata result carries a "blob:<sha256>" string
   reference instead of inlining bytes (so a compile node's result stays
   small; blob-get's own comment: "the ref in a node's key or free vars
   already pins exactly these bytes"). Transport.decide's blob_hashes are
   derived only from `tr_reads` (Cell.File cells) — sound for "a node
   returns the file it slurped", but INCOMPLETE for
   "a node returns a blob ref to bytes it wrote/ingested itself"
   (the `(blob (slurp OUTPUT-FILE))` compile pattern — no `file:`
   cell records the OUTPUT file at all, since reading back a node's own
   just-written sandbox output is not a world-observation, LAW 18). Remote
   placement must ship these too, or a dispatcher-side consumer of the
   pulled result (e.g. `link`'s `blob-get`) finds the metadata but not the
   bytes it names. Scans a value's own STRUCTURE (VMap/VVector/VPair/VSet
   spine — never forces anything already-forced-by-Codec.decode_value) for
   "blob:" + exactly 64 lowercase-hex chars, the same shape blob-get's own
   prefix check already assumes. *)
(* Factored out to src/blobref.ml (src/store.ml's GC mark-by-
   replay needs the identical scan and is compiled before this module) —
   [blob_refs_in] here is just a re-export so every existing call site in
   this file keeps working unchanged. *)
let blob_refs_in = Blobref.blob_refs_in

(* ---- Member side: serve the dispatcher's assigned keys after running ----

   Reuses Transport.serve_hit VERBATIM, once per key, against THIS
   process's own (just-populated) store — zero new authority/serving code;
   this is exactly the cluster transport's serve-hit path, just driven internally by
   `--remote-node` instead of by a second `pp --serve-hit` invocation per
   key (an optimization: one subprocess handles run + serve for the whole
   assigned batch). The ONE addition on top of serve_hit itself: on a hit,
   also push any "blob:" refs embedded in the result value (see
   blob_refs_in above) into shared_root — belt-and-suspenders, ignoring a
   ref that doesn't actually name a local blob (a coincidental string that
   merely matches the shape). *)
let serve_assigned_keys host ~(token_text : string) ~(keys_file : string)
    ~(shared_root : string) ~(reply_file : string) : unit =
  let keys =
    String.split_on_char '\n' (Store.read_raw keys_file)
    |> List.filter (fun l -> String.trim l <> "")
  in
  let replies = List.map (fun key -> Transport.serve_hit host ~key ~token_text ~shared_root) keys in
  List.iter (fun reply ->
    match Transport.parse_reply_text reply with
    | Some (Transport.RHit { result_hash; _ }) ->
        (match Store.load_object ~key:result_hash with
         | None -> ()
         | Some v ->
             List.iter (fun h -> try Transport.LocalDir.push_blob shared_root ~hash:h with _ -> ())
               (blob_refs_in v))
    | _ -> ())
    replies;
  Store.atomic_write reply_file (String.concat "" replies)

(* ---- Dispatcher side ---- *)

(* Pre-observe the granted source scope — EVERY regular file under
   every fs-read-granting root this process currently holds
   (Capabilities.list_fs_paths already flattens CapCompose/CapRestrict, so
   this covers exactly what [cell_authorized_for]/[check_fs_read] would
   authorize a read of). Coarse-but-sound (a documented residual: pre-observing
   the whole scope costs more the larger the grant), not a
   per-node-free-var-precise walk — deliberately: precision would require
   guessing which files a not-yet-run node body will read, and a wrong
   guess would silently observe wrong bytes, which heuristic predictive file
   shipping cannot rule out. *)
let walk_files (path : string) (acc : (string * string) list ref) : unit =
  Fswalk.walk ~root:path ~cb:(fun ~rel:_ ~path visit ->
    match visit with
    | Fswalk.Entry { Unix.st_kind = Unix.S_REG; _ } ->
        (try acc := (Store.file_cell_id path, Store.read_raw path) :: !acc
         with _ -> ())
    | _ -> ())

let pre_observe_granted_scope invocation : (string * string * string) list =
  let roots =
    Capability.list_fs_paths (Capability.compose (Invocation.initial_capabilities invocation))
    |> List.filter_map (fun ((p : Paths.canonical), m) -> match m with
         | Capability.Read | Capability.ReadWrite -> Some (p :> string)
         | Capability.Write -> None)
    |> List.sort_uniq compare
  in
  let acc = ref [] in
  List.iter (fun root -> walk_files root acc) roots;
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  List.filter_map (fun (cell, content) ->
    if Hashtbl.mem seen cell then None
    else begin
      Hashtbl.add seen cell ();
      Some (cell, Hasher.hash_string content, content)
    end)
    (List.rev !acc)

(* Cluster tokens minted for a remote batch are short-lived — long enough
   for one build's worth of remote compute, never a standing grant. *)
let remote_ttl_seconds = 600

let spawn_member ~(exe : string) ~(argv : string list) ~(env : string array)
    ~(log_file : string) : int =
  let fd_out = Unix.openfile log_file [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let fd_in = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
  let pid =
    Fun.protect ~finally:(fun () -> Unix.close fd_in; Unix.close fd_out)
      (fun () -> Unix.create_process_env exe (Array.of_list (exe :: argv)) env fd_in fd_out fd_out)
  in
  let (_, status) = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED s | Unix.WSTOPPED s -> 128 + s

let member_env (member_home : string) : string array =
  let is_home kv = String.length kv >= 5 && String.sub kv 0 5 = "HOME=" in
  Array.append
    (Array.of_list (List.filter (fun kv -> not (is_home kv))
                      (Array.to_list (Unix.environment ()))))
    [| "HOME=" ^ member_home |]

(* Ship [closed] (already filtered to data-closed jobs) to [member_home]:
   pre-observe + push the granted scope's blobs directly into the member's
   OWN store (a direct push, not a neutral relay — push
   is the TRUSTED direction in this threat model, verified against local
   content before writing, same as every other LocalDir push), mint a
   token from this process's OWN top-level grant specs (never
   wider than this process's own authority), spawn the member as an
   ordinary second `pp` invocation of the identical program under
   `--schedule serial` (run_node_body, no second force path),
   then pull each assigned key back via the serve-hit/
   recv-hit pair through a neutral shared-root scratch dir (the
   PULL direction, re-hash-verified same as every other sync).

   Never raises: any failure anywhere in this pipeline (unreachable member,
   a nonzero/crashed subprocess, a malformed reply, a failed pull) leaves
   the affected keys as an ordinary store Miss — the caller (force_deep's
   plain recursive walk) computes them in-process exactly like a dead local
   race/parallel worker. Worker/member failure degrades to local, never a
   wrong answer or a hang. *)
let ship_and_pull host invocation ~(member_home : string) (closed : Scheduler.job list) : unit =
  let scratch = Filename.temp_file "pp-remote" "" in
  Sys.remove scratch;
  Unix.mkdir scratch 0o755;
  Fun.protect ~finally:(fun () -> try Sandbox.remove_tree scratch with _ -> ()) (fun () ->
    let member_store_root = Filename.concat member_home store_suffix in
    let pins = pre_observe_granted_scope invocation in
    List.iter (fun (_, hash, content) ->
      ignore (Store.store_blob content);
      Transport.LocalDir.push_blob member_store_root ~hash)
      pins;
    let pins_file = Filename.concat scratch "pins" in
    Store.atomic_write pins_file
      (String.concat "" (List.map (fun (c, h, _) -> pin_line c h) pins));
    let secret = Cap_token.load_secret host and cluster_id = Cap_token.load_cluster_id host in
    let token_text =
      Cap_token.mint host ~secret ~cluster_id ~specs:(Invocation.initial_grant_specs invocation)
        ~ttl_seconds:remote_ttl_seconds
    in
    let token_file = Filename.concat scratch "token" in
    Store.atomic_write token_file token_text;
    let keys_file = Filename.concat scratch "keys" in
    Store.atomic_write keys_file
      (String.concat "" (List.map (fun j -> j.Scheduler.j_key ^ "\n") closed));
    (* Test-only synchronization seam: a real
       dispatcher-to-member gap is a NETWORK delay, which a single-machine
       test cannot otherwise force deterministically between "pins pushed"
       and "member spawned" — the exact window a real world-drift race
       occupies. Unset in every normal invocation (no --help surface, like
       the other internal cluster test entries above); when set, runs a shell
       command (e.g. mutating the shared world) between the two. *)
    (match Sys.getenv_opt "PP_REMOTE_TEST_HOOK" with
     | Some cmd when cmd <> "" -> ignore (Sys.command cmd)
     | _ -> ());
    let reply_file = Filename.concat scratch "reply" in
    let shared_root = Filename.concat scratch "shared" in
    let exe = Sys.executable_name in
    let argv =
      ["--remote-node"; token_file; pins_file; shared_root; keys_file; reply_file;
       "--schedule"; "serial"]
      @ Invocation.program_files invocation
    in
    let log_file = Filename.concat scratch "log" in
    let code = spawn_member ~exe ~argv ~env:(member_env member_home) ~log_file in
    (* Test-only, paired with PP_REMOTE_TEST_HOOK above: runs once the
       member has exited, before the dispatcher pulls back and re-checks
       its OWN Store.hit against the CURRENT world. *)
    (match Sys.getenv_opt "PP_REMOTE_TEST_HOOK_AFTER" with
     | Some cmd when cmd <> "" -> ignore (Sys.command cmd)
     | _ -> ());
    if code <> 0 then
      Store.why "remote: member subprocess for %s exited %d (see %s) — \
                 degrading this batch to local compute"
        member_home code log_file
    else if Sys.file_exists reply_file then
      String.split_on_char '\n' (Store.read_raw reply_file)
      |> List.iter (fun line ->
           let line = String.trim line in
           if line <> "" then
             try
               match Transport.recv_hit ~reply_text:line ~shared_root with
               | Transport.RHit { result_hash; _ } ->
                   (* blob_refs_in, mirrored on the pull side: a "blob:"
                      ref embedded in the (just-pulled, re-hash-verified)
                      result value names bytes serve_assigned_keys already
                      pushed to shared_root above — pull those too, same
                      re-hash-on-receive choke point as everything else. *)
                   (match Store.load_object ~key:result_hash with
                    | None -> ()
                    | Some v ->
                        List.iter (fun h ->
                          try Transport.LocalDir.pull_blob shared_root ~hash:h
                          with _ -> ())
                          (blob_refs_in v))
               | Transport.RMiss _ | Transport.RDeny _ -> ()
             with e ->
               Store.why "remote: recv-hit failed (%s) — that key stays a \
                          local miss and recomputes in-process"
                 (Printexc.to_string e)))

(* The Scheduler.remote_dispatch_hook target: filters [jobs] to the
   data-closed subset (contract point 2 — the codec's non-data predicate,
   Evaluator.is_data_closed, at this new decision point) and ships only
   those; every non-data-closed job is left untouched here and falls
   through to the ordinary local Miss path in the caller (force_deep_plain)
   — "filter them back into the local pool" IS "don't touch them", since
   that pool is simply whatever runs next in-process. An unknown member, or
   any exception anywhere in the pipeline, degrades the WHOLE batch to
   local the same way (never a partial-crash, never a hang). *)
let dispatch_remote host invocation ~(member : string) (jobs : Scheduler.job list) : unit =
  try
    match find_member_root member with
    | None ->
        Store.why "remote: unknown cluster member %s (see %s) — batch stays local"
          member (members_path ())
    | Some root ->
        (match member_home_of_root root with
         | Error msg -> Store.why "remote: %s — batch stays local" msg
         | Ok member_home ->
             let closed = List.filter (fun j -> Evaluator.is_data_closed j.Scheduler.j_thunk) jobs in
             if closed <> [] then ship_and_pull host invocation ~member_home closed)
  with e ->
    Store.why "remote: dispatch to %s failed (%s) — batch stays local"
      member (Printexc.to_string e)

let init host invocation : unit =
  Scheduler.state.remote_dispatch <- dispatch_remote host invocation
