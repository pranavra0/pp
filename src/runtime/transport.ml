open Pp_kernel
(* pp transport — cross-machine sync of hash-named store artifacts, plus
   the capability-gated single-hit control path
   (docs/THREAT-MODEL-cluster.md is the gate this implements against).

   THE LOAD-BEARING INVARIANT: the receiving side re-hashes EVERY artifact
   against its claimed name before it is ever written into THIS node's own
   store. The transport is untrusted for integrity (a MITM or a compromised
   peer can corrupt bytes in flight); a mismatch is a hard error naming the
   artifact, never a silent accept — the islands invariant
   (docs/THREAT-MODEL-islands.md), generalized to a second wire.

   This is made structural, not merely conventional: [ingest_object],
   [ingest_blob], and [ingest_trace_lines] below are the ONLY functions in
   this module that write a remote-sourced artifact into the local store,
   and every one of them verifies before it stores — there is no sibling
   "trust it" entry point for a pull or a serve-hit reply to call instead.
   Every receive path (LocalDir.pull_*, [recv_hit]) funnels through them. *)

open Core_model
open Codec
open Source_error

let raise_integrity message =
  raise (Error (Transport (Integrity { artifact = "wire"; message })))

let raise_unavailable peer message =
  raise (Error (Transport (Unavailable { peer; message })))

(* ---- The abstract shape: local-dir today, ssh later ----

   Push/pull of hash-named
   artifacts (objects|blobs|traces) + a control request/reply channel in
   the store's canonical text (a captured message is inspectable like a
   trace — no new wire format). [t] is "the other side" — a second
   store-shaped root directory for local-dir, a host spec for ssh. *)
module type TRANSPORT = sig
  type t

  val push_object : t -> hash:string -> unit
  val push_blob : t -> hash:string -> unit
  val push_trace : t -> key:string -> unit
  val pull_object : t -> hash:string -> unit
  val pull_blob : t -> hash:string -> unit
  val pull_trace : t -> key:string -> unit

  val control : t -> request:string -> string
end

(* ---- The unbypassable re-hash-on-receive choke point ----

   Every artifact that ever enters THIS node's own store from a remote
   source passes through exactly one of these three functions, and every
   one of them verifies BEFORE writing. There is no raw "just copy the
   bytes in" helper anywhere else in this module for a pull or a
   serve-hit reply to call instead — structurally, not just by
   convention, so a mismatch cannot be silently accepted (T1). *)

(* [text] is the canonical object encoding claimed to hash to
   [claimed_hash] — a VALUE's content hash (Identity.hash_value), NOT a hash
   of [text] itself (Trace_repository's header: objects are addressed by the hash
   of the value, not of its encoding). *)
let ingest_object ~(claimed_hash : string) (text : string) : unit =
  match Codec.decode_value text with
  | None ->
      raise_integrity
        (Printf.sprintf
           "object %s: received bytes do not decode as a pp value \
            (corrupt or tampered in transit) — refusing to accept"
           claimed_hash)
  | Some v ->
      let actual = Identity.hash_value v in
      if actual <> claimed_hash then
        raise_integrity
          (Printf.sprintf
             "object %s: content hashes to %s, not its claimed name — \
              refusing to accept (corrupt or tampered in transit)"
             claimed_hash actual)
      else Object_repository.put Object_repository.default ~key:claimed_hash ~value:v

let ingest_blob ~(claimed_hash : string) (content : string) : unit =
  let actual = Hasher.hash_string content in
  if actual <> claimed_hash then
    raise_integrity
      (Printf.sprintf
         "blob %s: content hashes to %s, not its claimed name — refusing \
          to accept (corrupt or tampered in transit)" claimed_hash actual)
  else ignore (Blob_repository.put Blob_repository.default content)

(* Traces have no self-describing content hash: their filename is a NODE
   KEY (H(code, free-var value hashes) — see Trace_repository/identity.ml), not
   derivable from the trace text itself, so there is no "does this hash to
   its name" check to run here. The receive-time analog of "re-hash
   against the claimed name" for a trace SET is structural validity: every
   line must parse under the EXACT grammar a local trace file is written
   in (Trace_repository.of_line) — a line that fails to parse is a HARD ERROR
   here, unlike the local loader's silent drop (which exists for local
   disk-corruption tolerance, not for a byte an untrusted wire just handed
   us: never silently accept). Accepted lines are unioned into the local
   SET via Trace_repository.put, reused verbatim (R9 merge semantics, the same
   de-dup rule a local writer already uses). *)
let ingest_trace_lines ~(key : string) (raw : string) : unit =
  let lines = String.split_on_char '\n' raw |> List.filter (fun l -> l <> "") in
  if lines = [] then
    raise_integrity
      (Printf.sprintf "trace %s: empty (corrupt or tampered in transit)" key);
  List.iter (fun line ->
    match Trace_repository.of_line line with
    | None ->
        raise_integrity
          (Printf.sprintf
             "trace %s: unparseable line — refusing to accept (corrupt or \
              tampered in transit): %s" key line)
    | Some tr ->
        Trace_repository.put Trace_repository.default
          ~key:(Identity_types.Cache_key.of_string key)
          ~outcome:tr.Trace_repository.outcome
          ~result_hash:tr.Trace_repository.result_hash ~reads:tr.Trace_repository.reads)
    lines

(* ---- LocalDir: a second store-shaped root on one machine ----

   The CI loopback: both "sides" of a sync are
   ordinary directories on the SAME machine (typically each node's own
   $HOME/.pp/store, or a throwaway shared drop directory), so every exit
   test here runs with zero real network/ssh infra. Layout mirrors
   Trace_repository's own (<root>/objects/<hash>, <root>/blobs/<hash>,
   <root>/traces/<key>) but is managed by plain file I/O here rather than
   through the default repositories, because their layout is fixed at startup
   from $HOME — a single process can only ever
   BE one store, never address a second one directly. Two distinct nodes
   are therefore two distinct `pp` process invocations (differing only in
   $HOME), exactly the pattern the rest of the test suite already uses for
   isolation; this module's push/pull work
   between "my own store" (read via repository reads, written via
   repository writes — the process's own singleton) and an
   arbitrary root path passed in as [t]. *)
module LocalDir = struct
  type t = string

  let objects_dir (root : t) = Filename.concat root "objects"
  let blobs_dir (root : t) = Filename.concat root "blobs"
  let traces_dir (root : t) = Filename.concat root "traces"

  (* ---- push: the local repositories -> an arbitrary root ----
     Push re-checks its OWN local content against the hash it is about to
     advertise before writing — belt-and-suspenders; the load-bearing
     check is on the receiving side (pull, below), since push is not what
     an adversary controls in the MITM threat model. *)

  let push_object (root : t) ~(hash : string) : unit =
    match Object_repository.get Object_repository.default ~key:hash with
    | None ->
        raise_unavailable root (Printf.sprintf
          "transport: push-object %s: no such object in the local store" hash)
    | Some v ->
        (match Codec.encode_value v with
         | None ->
             (* T5 non-regression, made explicit rather than assumed:
                Object_repository.get Object_repository.default only ever decodes via Codec.decode_value,
                whose grammar contains no code/capability/sealed
                constructor at all — this branch should be unreachable —
                but push refuses to ship on any doubt, never "ship and
                hope". *)
             raise_unavailable root (Printf.sprintf
               "transport: push-object %s: refusing to ship a value that \
                does not re-encode as data (sealed/non-data invariant \
                violation — should be unreachable)" hash)
         | Some content ->
             if Identity.hash_value v <> hash then
               raise_unavailable root (Printf.sprintf
                 "transport: push-object %s: local object does not hash \
                  to its own claimed name (local store corruption) — \
                  refusing to push" hash)
             else begin
               Store_layout.ensure_dir (objects_dir root);
               Store_layout.atomic_replace (Filename.concat (objects_dir root) hash) content
             end)

  let push_blob (root : t) ~(hash : string) : unit =
    match Blob_repository.get Blob_repository.default hash with
    | None ->
        raise_unavailable root (Printf.sprintf
          "transport: push-blob %s: no such blob in the local store" hash)
    | Some content ->
        if Hasher.hash_string content <> hash then
          raise_unavailable root (Printf.sprintf
            "transport: push-blob %s: local blob does not hash to its own \
             claimed name (local store corruption) — refusing to push" hash)
        else begin
          Store_layout.ensure_dir (blobs_dir root);
          Store_layout.atomic_replace (Filename.concat (blobs_dir root) hash) content
        end

  let read_lines_if_exists (path : string) : Trace_repository.trace list =
    if Sys.file_exists path then
      String.split_on_char '\n' (Cell_repository.read_raw path)
      |> List.filter (fun l -> l <> "")
      |> List.filter_map Trace_repository.of_line
    else []

  (* Push exactly [traces] (a caller-chosen subset — see [serve_hit]'s
     authorization filtering below) into the remote root's trace SET for
     [key], merged with whatever is already there (R9's key -> SET is the
     merge mechanism, same de-dup rule Trace_repository.put Trace_repository.default already uses
     locally). *)
  let push_trace_filtered (root : t) ~(key : string) ~(traces : Trace_repository.trace list) : unit =
    if traces <> [] then begin
      Store_layout.ensure_dir (traces_dir root);
      let path = Filename.concat (traces_dir root) key in
      let existing = read_lines_if_exists path in
      let merged =
        List.fold_left (fun acc tr -> if List.mem tr acc then acc else acc @ [tr])
          existing traces
      in
      let content = String.concat "" (List.map (fun t -> Trace_repository.to_line t ^ "\n") merged) in
      Store_layout.atomic_replace path content
    end

  let push_trace (root : t) ~(key : string) : unit =
    let mine = Trace_repository.load Trace_repository.default
      ~key:(Identity_types.Cache_key.of_string key) in
    if mine = [] then
      raise_unavailable root (Printf.sprintf
        "transport: push-trace %s: no local traces for this node key" key)
    else push_trace_filtered root ~key ~traces:mine

  (* ---- pull: an arbitrary root -> MY store ----
     Every byte read here goes straight into [ingest_object]/[ingest_blob]/
     [ingest_trace_lines] above and nowhere else — the unbypassable
     re-hash-on-receive path (T1). *)

  let pull_object (root : t) ~(hash : string) : unit =
    let path = Filename.concat (objects_dir root) hash in
    if not (Sys.file_exists path) then
      raise_unavailable root (Printf.sprintf "transport: pull-object %s: not found at %s" hash root)
    else ingest_object ~claimed_hash:hash (Cell_repository.read_raw path)

  let pull_blob (root : t) ~(hash : string) : unit =
    let path = Filename.concat (blobs_dir root) hash in
    if not (Sys.file_exists path) then
      raise_unavailable root (Printf.sprintf "transport: pull-blob %s: not found at %s" hash root)
    else ingest_blob ~claimed_hash:hash (Cell_repository.read_raw path)

  let pull_trace (root : t) ~(key : string) : unit =
    let path = Filename.concat (traces_dir root) key in
    if not (Sys.file_exists path) then
      raise_unavailable root (Printf.sprintf "transport: pull-trace %s: not found at %s" key root)
    else ingest_trace_lines ~key (Cell_repository.read_raw path)

  (* Control has no generic realization for local-dir without a listening
     peer process (there is no daemon); nothing calls this — the
     request/reply-FILE convention actually
     exercised is [serve_hit]/[recv_hit] below, driven by two `pp` CLI
     invocations (one per simulated node). See the module header for why:
     Store_layout.root Store_layout.default's process-wide singleton means a
     single process can only ever serve hits against ITS OWN store, so
     "control" here is realized at the CLI layer rather than through this
     function. *)
  let control (_ : t) ~(request : string) : string =
    ignore request;
    raise_unavailable "local-dir"
      "transport: LocalDir.control is not used this stage — see \
       Transport.serve_hit / Transport.recv_hit"
end

(* Conformance check only (never instantiated): proves LocalDir's shape
   satisfies TRANSPORT despite carrying an extra helper
   ([push_trace_filtered]) the signature doesn't mention. *)
module LocalDir_conforms : TRANSPORT = LocalDir

(* ---- ssh: STUBBED ----

   scp/rsync for artifacts, `ssh <host> pp --worker-control` for control —
   drops in behind the exact
   same TRANSPORT shape once a real second machine is needed. Every
   operation is a clear "not yet" error naming itself, never a silent
   no-op. *)
module Ssh : TRANSPORT = struct
  type t = string (* a host spec, e.g. "user@host" *)

  let not_yet (op : string) (host : t) : 'a =
    raise_unavailable host (Printf.sprintf
      "pp: transport ssh: %s not implemented (host %s) — local-dir is the \
       only transport; ssh drops in behind the identical TRANSPORT shape" op host)

  let push_object host ~hash:_ = not_yet "push_object" host
  let push_blob host ~hash:_ = not_yet "push_blob" host
  let push_trace host ~key:_ = not_yet "push_trace" host
  let pull_object host ~hash:_ = not_yet "pull_object" host
  let pull_blob host ~hash:_ = not_yet "pull_blob" host
  let pull_trace host ~key:_ = not_yet "pull_trace" host
  let control host ~request:_ = not_yet "control" host
end

(* ---- Serve-hit: the capability-gated single-hit control path ----

   Given (node-key, token), the serving side verifies the token, then
   calls Cache_policy.lookup ~authorized:(cell_authorized_for
   (token_to_caps token)) — zero new authority code, just the
   existing LAW 23b gate fed a wire-verified capability list. On a hit, exactly the trace(s) the token's
   own capabilities cover are pushed (never an unauthorized trace, even
   though cache policy's own gate would also refuse to serve it later — this
   is defense in depth against leaking cell names/paths as metadata, LAW
   23c's spirit applied at the sync boundary, not just at read time). *)

type decision =
  | DHit of { result_hash : string; traces : Trace_repository.trace list; blob_hashes : string list }
  | DMiss
  | DDeny of string

let decide host ~(key : string) ~(token_text : string) : decision =
  match Cap_token.token_to_caps host token_text with
  | Error reason -> DDeny reason
  | Ok caps ->
      let authorized = Observation.authorized_id caps in
      (match Cache_policy.lookup Cache_policy.default
               ~key:(Identity_types.Cache_key.of_string key) ~authorized with
       | Cache_policy.Miss -> DMiss
       | Cache_policy.HitOk v | Cache_policy.HitFailed v ->
           (match Codec.encode_value v with
            | None ->
                (* T5 guard: Cache_policy.lookup Cache_policy.default can only ever have produced [v] by
                   decoding an on-disk object, whose grammar contains no
                   code/capability/sealed constructor — unreachable in
                   practice, but serve-hit refuses to ship on any doubt. *)
                failwith (Printf.sprintf
                  "serve-hit: refusing to serve node %s: its result does \
                   not re-encode as data (sealed/non-data invariant \
                   violation — should be unreachable)" key)
            | Some _ ->
                let result_hash = Identity.hash_value v in
                let traces = Trace_repository.load Trace_repository.default
                  ~key:(Identity_types.Cache_key.of_string key) in
                (* Only the trace(s) whose ENTIRE closure this token's caps
                   cover — never leak a cell name/path the token doesn't
                   authorize, even when a DIFFERENT trace for the same key
                   is what made this a hit. *)
                let authorized_traces =
                  List.filter (fun tr ->
                    List.for_all (fun (c, _) -> authorized c) tr.Trace_repository.reads)
                    traces
                in
                let blob_hashes =
                  List.sort_uniq compare
                    (List.concat_map (fun tr ->
                       List.filter_map (fun (c, h) ->
                         match Cell.parse (Identity_types.Cell_id.to_string c) with
                         | Cell.File _ ->
                             Some (Identity_types.Observed_hash.to_string h)
                         | _ -> None)
                         tr.Trace_repository.reads)
                       authorized_traces)
                in
                DHit { result_hash; traces = authorized_traces; blob_hashes }))

(* ---- Control wire format (canonical text) ----

     (serve-hit-reply hit "KEY" "RESULT-HASH" ("BLOB-HASH" ...))
     (serve-hit-reply miss "KEY")
     (serve-hit-reply deny "KEY" "REASON")

   Deliberately does NOT embed artifact bytes — the reply just names hashes
   to push/pull; the artifacts themselves move (and are re-hash-verified)
   through the ALREADY-TESTED push/pull path above, so there is exactly one
   code path that ever writes a remote-sourced artifact into a store,
   whether it arrived via a bulk sync or via serve-hit. *)

let quote = Codec.quote_string

let reply_of_decision (key : string) (d : decision) : string =
  match d with
  | DDeny reason -> Printf.sprintf "(serve-hit-reply deny %s %s)\n" (quote key) (quote reason)
  | DMiss -> Printf.sprintf "(serve-hit-reply miss %s)\n" (quote key)
  | DHit { result_hash; blob_hashes; _ } ->
      Printf.sprintf "(serve-hit-reply hit %s %s (%s))\n"
        (quote key) (quote result_hash)
        (String.concat " " (List.map quote blob_hashes))

(* The serving side: decide, then (only on a hit) push into [shared_root] —
   nothing is EVER written to [shared_root] on a miss or a deny (T5's "no
   bytes cross on denial" is structural: the push calls are inside the
   DHit arm only, not a separate "push if authorized" flag a caller could
   forget to check). Returns the reply text to hand back to the requester. *)
let serve_hit host ~(key : string) ~(token_text : string) ~(shared_root : string) : string =
  let d = decide host ~key ~token_text in
  (match d with
   | DHit { result_hash; traces; blob_hashes } ->
       LocalDir.push_object shared_root ~hash:result_hash;
       LocalDir.push_trace_filtered shared_root ~key ~traces;
       List.iter (fun h -> LocalDir.push_blob shared_root ~hash:h) blob_hashes
   | DMiss | DDeny _ -> ());
  reply_of_decision key d

(* ---- Reply parser (hand-rolled, same style as Token/Trace_repository) ---- *)

type reply_decision =
  | RHit of { key : string; result_hash : string; blob_hashes : string list }
  | RMiss of string
  | RDeny of string * string

let parse_reply_text (text : string) : reply_decision option =
  let text = String.trim text in
  let len = String.length text in
  expect_lit text 0 "(serve-hit-reply " >>= fun i ->
  match String.index_from_opt text i ' ' with
  | None -> None
  | Some sp ->
      let kind = String.sub text i (sp - i) in
      let i = sp + 1 in
      Codec.parse_quoted_string text i >>= fun (key, i) ->
      (match kind with
       | "miss" -> expect_char text i ')' >>= fun _ -> Some (RMiss key)
       | "deny" ->
           expect_char text i ' ' >>= fun i ->
           Codec.parse_quoted_string text i >>= fun (reason, i) ->
           expect_char text i ')' >>= fun _ -> Some (RDeny (key, reason))
       | "hit" ->
           expect_char text i ' ' >>= fun i ->
           Codec.parse_quoted_string text i >>= fun (result_hash, i) ->
           expect_char text i ' ' >>= fun i ->
           expect_char text i '(' >>= fun i ->
           let rec loop i acc =
             if i < len && text.[i] = ')' then Some (List.rev acc, i + 1)
             else
               Codec.parse_quoted_string text i >>= fun (h, i) ->
               let i = if i < len && text.[i] = ' ' then i + 1 else i in
               loop i (h :: acc)
           in
           loop i [] >>= fun (hashes, i) ->
           expect_char text i ')' >>= fun _ ->
           Some (RHit { key; result_hash; blob_hashes = hashes })
       | _ -> None)

(* The requesting side: parse the reply, then (only on a hit) pull each
   named artifact from [shared_root] — every pull re-hash-verifies before
   accepting (ingest_object/ingest_blob/ingest_trace_lines above), so a
   tampered reply payload or a tampered shared-root artifact is rejected
   here exactly as it would be for a bulk sync. *)
let recv_hit ~(reply_text : string) ~(shared_root : string) : reply_decision =
  match parse_reply_text reply_text with
  | None ->
      raise_integrity
        ("serve-hit reply: unrecognized or malformed: " ^ String.trim reply_text)
  | Some (RHit { key; result_hash; blob_hashes } as d) ->
      LocalDir.pull_object shared_root ~hash:result_hash;
      LocalDir.pull_trace shared_root ~key;
      List.iter (fun h -> LocalDir.pull_blob shared_root ~hash:h) blob_hashes;
      d
  | Some d -> d
