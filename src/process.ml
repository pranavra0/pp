(* pp `run` process effect (D13) — execute an external command.

   (perform run CMD ARG...) ⇒ {"exit" int, "out" string, "err" string}

   Authority: `--grant process` (CapProcess) is required at perform time;
   there is no way to mint it from user code (LAW 22). A denial raises
   Capability_error, which node caching deliberately does not memoize
   (authority is not identity — LAW 15).

   Trace soundness (DESIGN Q2's coarse-cell floor): a run inside a node
   records
     - `tool:<resolved-binary>` — content hash of the executable, and
     - `tree:<root>`           — whole-tree content hash of every
                                 fs-read-granted root at run time,
   so a cached node that ran a process re-runs when the tool or anything
   under a granted tree changes — including files the process read that pp
   itself never saw. Reads outside granted roots (system headers etc.) are
   the documented staleness hole the future `toolchain:` closure cell covers.

   Sandbox (LAW 18 / Q2 sandbox v1): inside a node the child process runs
   with the node's scratch directory as cwd, so relative outputs land in
   node-local scratch and never in the caller's tree. The sandbox does not
   fail-close absolute paths — it is a hygiene mechanism; the trace cells
   above are the soundness mechanism. *)

open Types

let has_process_cap () =
  List.exists Capabilities.check_process !Runtime.current_capabilities

(* Resolve a command to the binary that will execute: as-is when it contains
   a slash, else the first match on $PATH. The resolved path is what the
   `tool:` cell observes. *)
let resolve_cmd (cmd : string) : string option =
  if String.contains cmd '/' then
    (if Sys.file_exists cmd then Some cmd else None)
  else
    let path = try Sys.getenv "PATH" with Not_found -> "" in
    let rec find = function
      | [] -> None
      | dir :: rest ->
          let p = Filename.concat dir cmd in
          if dir <> "" && Sys.file_exists p then Some p else find rest
    in
    find (String.split_on_char ':' path)

let record_tool_cell (resolved : string) : unit =
  match Store.hash_file_opt resolved with
  | Some h -> Runtime.record_read (Cell.(to_string (Tool (Runtime.canonical_path resolved)))) h
  | None -> ()

(* The coarse-cell soundness floor (Q2): one whole-tree hash per fs-read
   grant. Used by plain `run` and as run-dep!'s fallback when the tool
   produced no depfile. *)
let record_tree_cells () : unit =
  List.iter (function
    | CapFilesystem { path; mode = (Read | ReadWrite) } ->
        let cpath = Runtime.canonical_path path in
        Runtime.record_read (Cell.(to_string (Tree cpath))) (Store.tree_hash cpath)
    | _ -> ())
    !Runtime.current_capabilities

let record_run_observations (resolved : string) : unit =
  record_tool_cell resolved;
  record_tree_cells ()

let read_all_exn (path : string) : string =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let s = really_input_string ic len in
  close_in ic; s

let read_all (path : string) : string =
  try read_all_exn path with _ -> ""

(* Execute argv, capturing stdout/stderr; cwd is the node sandbox when inside
   a node (created on demand), the process cwd otherwise. Every execution is
   journaled — "null rebuild executes zero external processes" is proved by
   the journal, not asserted (ROADMAP Phase-1 exit criterion 1). *)
let exec (argv : string list) : int * string * string =
  (try Journal.append (Journal.Exec argv) with _ -> ());
  let out_f = Filename.temp_file "pp-run" ".out" in
  let err_f = Filename.temp_file "pp-run" ".err" in
  let cleanup () =
    (try Sys.remove out_f with _ -> ());
    (try Sys.remove err_f with _ -> ())
  in
  Fun.protect ~finally:cleanup (fun () ->
    let fd_out = Unix.openfile out_f [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let fd_err = Unix.openfile err_f [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let fd_in = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
    let saved_cwd = Unix.getcwd () in
    (match Runtime.current_sandbox ~create:true with
     | Some d -> (try Unix.chdir d with _ -> ())
     | None -> ());
    let pid =
      Fun.protect
        ~finally:(fun () -> try Unix.chdir saved_cwd with _ -> ())
        (fun () ->
           Unix.create_process (List.hd argv) (Array.of_list argv)
             fd_in fd_out fd_err)
    in
    Unix.close fd_in; Unix.close fd_out; Unix.close fd_err;
    let (_, status) = Unix.waitpid [] pid in
    let code = match status with
      | Unix.WEXITED n -> n
      | Unix.WSIGNALED s | Unix.WSTOPPED s -> 128 + s
    in
    (code, read_all out_f, read_all err_f))

let run_effect (args : value list) : value =
  if not (has_process_cap ()) then
    raise (Capability_error "capability error: no process authority for run");
  let argv = List.map (function
    | VString s -> s
    | v -> failwith ("run expects string command/arguments, got " ^ string_of_value v))
    args
  in
  match argv with
  | [] -> failwith "run expects a command"
  | cmd :: _ ->
      let resolved = match resolve_cmd cmd with
        | Some p -> p
        | None -> failwith ("run: command not found: " ^ cmd)
      in
      (* Observations are recorded against the PRE-run world: a tool that
         mutates a granted tree leaves a never-verifying trace behind, which
         re-runs — the sound answer for a non-hermetic tool. *)
      record_run_observations resolved;
      let (code, out, err) = exec argv in
      VMap [ (VString "exit", VInt code);
             (VString "out",  VString out);
             (VString "err",  VString err) ]

(* ---- Depfile adapter (Q2 refinement) ----

   (perform run-dep! DEPFILE CMD ARG...) — like `run`, but after the exec the
   Makefile-style depfile the tool wrote (`cc -MD -MF` and friends) is parsed
   and the EXACT files the tool read become the trace cells:
     granted dep      → precise `file:` cell (via read_file_cell, so it is
                        also Q11-pinned and CAS-ingested)
     out-of-grant dep → `tool:` cell (a system read under process authority)
   and NO coarse `tree:` cells are recorded — the refinement that shrinks the
   trace below the Q2 soundness floor. A missing/unreadable depfile falls
   back to the coarse floor. The adapter trusts the tool's report; that trust
   is per-tool and explicit (you chose run-dep!). *)

(* "target: dep dep \\\n dep" → the dep paths. Line continuations become
   spaces; everything through the first ':' is the target and is dropped. *)
let parse_depfile (content : string) : string list =
  let buf = Buffer.create (String.length content) in
  let n = String.length content in
  let i = ref 0 in
  while !i < n do
    if !i + 1 < n && content.[!i] = '\\' && content.[!i + 1] = '\n' then begin
      Buffer.add_char buf ' '; i := !i + 2
    end else begin
      Buffer.add_char buf content.[!i]; incr i
    end
  done;
  let s = Buffer.contents buf in
  let body =
    match String.index_opt s ':' with
    | Some idx -> String.sub s (idx + 1) (String.length s - idx - 1)
    | None -> s
  in
  String.split_on_char '\n' body
  |> List.concat_map (String.split_on_char ' ')
  |> List.concat_map (String.split_on_char '\t')
  |> List.filter (fun p -> p <> "")

let record_depfile_cells (deps : string list) : unit =
  List.iter (fun dep ->
    if Sys.file_exists dep then begin
      if List.exists (fun cap -> Capabilities.check_fs_read cap dep)
           !Runtime.current_capabilities
      then ignore (Store.read_file_cell dep)
      else
        match Store.hash_file_opt dep with
        | Some h -> Runtime.record_read (Cell.(to_string (Tool (Runtime.canonical_path dep)))) h
        | None -> ()
    end)
    deps

let run_dep_effect (args : value list) : value =
  match args with
  | VString depfile :: (VString _ :: _ as cmd_args) ->
      if not (has_process_cap ()) then
        raise (Capability_error "capability error: no process authority for run-dep!");
      let argv = List.map (function
        | VString s -> s
        | v -> failwith ("run-dep! expects string arguments, got " ^ string_of_value v))
        cmd_args
      in
      let cmd = List.hd argv in
      let resolved = match resolve_cmd cmd with
        | Some p -> p
        | None -> failwith ("run-dep!: command not found: " ^ cmd)
      in
      record_tool_cell resolved;
      let (code, out, err) = exec argv in
      (* The depfile is a sandbox output, not an observation: read it raw. *)
      let dep_path =
        match Runtime.sandbox_resolve ~create:false depfile with
        | Some p -> p
        | None -> depfile
      in
      (match (try Some (read_all_exn dep_path) with _ -> None) with
       | Some content -> record_depfile_cells (parse_depfile content)
       | None -> record_tree_cells ()  (* no depfile ⇒ coarse-but-sound *));
      VMap [ (VString "exit", VInt code);
             (VString "out",  VString out);
             (VString "err",  VString err) ]
  | _ -> failwith "run-dep! expects a depfile path, a command, and arguments"

(* ---- write-file with the LAW 18 node/scripting split ----
   Shared by both backends' builtin write-file. Inside a node: a relative
   path writes node-local sandbox scratch (capability-free, unrecorded); an
   absolute path is an error — reconciled-domain writes go through the
   reconciler, never node bodies. Scripting tier: unchanged, capability-
   checked, writes anywhere granted. *)
let write_file_effect ~(has_cap : string -> bool) (path : string)
    (content : string) : value =
  match Runtime.sandbox_resolve ~create:true path with
  | Some scratch ->
      (try
         let ch = open_out scratch in
         output_string ch content;
         close_out ch;
         VNil
       with Sys_error msg -> failwith ("write-file: " ^ msg))
  | None ->
      if !Runtime.trace_stack <> [] then
        failwith ("write-file: node writes are sandbox-scratch only (LAW 18): "
                  ^ path)
      else begin
        if not (has_cap path) then
          raise (Capability_error
                   ("write-file: capability error: no write access for " ^ path));
        (try
           let ch = open_out path in
           output_string ch content;
           close_out ch;
           (* Q11 coherence: pp's own write supersedes the run's pinned
              snapshot of this cell — later node reads must see the new
              content, not the pre-write pin. *)
           Store.unpin_file path;
           VNil
         with Sys_error msg -> failwith ("write-file: " ^ msg))
      end

(* ---- capability-free sandbox read, shared by slurp/read-file ----
   Returns Some contents when [path] resolves into the innermost node's
   scratch (relative path, sandbox exists); such reads are node-local and
   deliberately unrecorded. *)
let sandbox_read (path : string) : string option =
  match Runtime.sandbox_resolve ~create:false path with
  | Some scratch ->
      (try
         let ic = open_in scratch in
         let s = really_input_string ic (in_channel_length ic) in
         close_in ic;
         Some s
       with _ -> None)
  | None -> None

(* ---- M4 sealed cells: read dispatch shared by slurp/read-file ----

   Sandbox scratch (above) takes precedence, unchanged. Outside a sandbox,
   the GRANT decides the shape of the result, never the program text
   (PLAN-m4-cells.md "Sealed cells": "program text stays deployment-
   agnostic"):
     - covered by a CapFilesystem read grant (with or without ALSO a
       CapSecret grant) → ordinary VString, exactly as before M4. Both-
       grants deliberately resolves to plain fs behavior: the deployment
       that also handed out an fs grant over the same path is saying "not
       secret HERE" (PLAN-m4-cells.md).
     - covered by CapSecret and NOT by CapFilesystem → VSealed, read via
       Store.read_sealed_cell (bytes pinned in Runtime.sealed_pins,
       in-memory only — store_blob/the CAS is never called for this path).
     - covered by neither → Capability_error, worded by the caller (`slurp`
       and `read-file` keep their own pre-M4 message text via [cap_err]). *)
let read_dispatch ~(tag : string) ~(cap_err : string -> string) (path : string) : value =
  match sandbox_read path with
  | Some content -> VString content
  | None ->
      let fs_ok =
        List.exists (fun cap -> Capabilities.check_fs_read cap path)
          !Runtime.current_capabilities
      in
      if fs_ok then
        (try VString (Store.read_file_cell path)
         with Sys_error msg -> failwith (tag ^ ": " ^ msg))
      else
        let secret_ok =
          List.exists (fun cap -> Capabilities.check_secret cap path)
            !Runtime.current_capabilities
        in
        if secret_ok then
          (try VSealed (Store.read_sealed_cell path)
           with Sys_error msg -> failwith (tag ^ ": " ^ msg))
        else
          raise (Capability_error (cap_err path))

(* ---- M4 network: `(perform http-get url)` / `(perform http-post url body)` ----

   Implemented by forking curl via [exec] above (E6: zero new OCaml
   networking/TLS surface) but AUTHORIZED against CapNetwork host[:port] —
   not CapProcess: granularity, "may read this host" is a much narrower
   grant than "may exec anything" (PLAN-m4-cells.md "Network"). Banned
   inside node bodies (trace_stack guard, the same LAW-31 pattern
   `Fenced.register` and `write-file`'s node arm use) — network reads are
   not convergent and are not the sanctioned nondeterminism mechanism
   (probes are, LAW 37/38); legal in probe observe-fns (which run with
   trace_stack forced to [] — Primitives.probe_value_for), domain
   observe/apply (stage 2), and the script tier. *)

let has_network_cap ~(host : string) ~(port : int option) : bool =
  List.exists (fun cap -> Capabilities.check_network cap ~host ~port)
    !Runtime.current_capabilities

(* Parse an http(s) URL into (scheme, host, port); port defaults to the
   scheme's standard port when the URL omits one, so a `--grant
   net:host:PORT` still matches a URL that never spells the port out.
   Deliberately minimal — no userinfo, no IPv6 literal brackets; documented
   residuals, not needed for curl (curl gets the WHOLE url verbatim; this
   parse exists only to name the (host, port) pair the authority check
   tests). Anything other than http/https is a hard error (PLAN-m4-cells.md:
   "anything else = error"). *)
let parse_http_url (url : string) : string * string * int =
  let strip prefix =
    let n = String.length prefix in
    if String.length url >= n && String.sub url 0 n = prefix then
      Some (String.sub url n (String.length url - n))
    else None
  in
  let (scheme, rest, default_port) =
    match strip "https://" with
    | Some rest -> ("https", rest, 443)
    | None ->
        (match strip "http://" with
         | Some rest -> ("http", rest, 80)
         | None -> failwith ("http: unsupported url scheme (only http/https supported): " ^ url))
  in
  let host_port =
    match String.index_opt rest '/' with
    | Some i -> String.sub rest 0 i
    | None -> rest
  in
  if host_port = "" then failwith ("http: url has no host: " ^ url);
  match String.index_opt host_port ':' with
  | Some i ->
      let host = String.sub host_port 0 i in
      let port_s = String.sub host_port (i + 1) (String.length host_port - i - 1) in
      (match int_of_string_opt port_s with
       | Some p -> (scheme, host, p)
       | None -> failwith ("http: invalid port in url: " ^ url))
  | None -> (scheme, host_port, default_port)

let curl_bin () : string =
  match resolve_cmd "curl" with
  | Some p -> p
  | None -> failwith "http: curl not found on PATH"

(* [body]: None for GET, Some content for POST — written to a temp file and
   passed via `--data-binary @file` so no stdin plumbing is needed in
   [exec]. `-w '\n%{http_code}'` appends the numeric status on its own
   trailing line, which the response text can never itself end with
   unambiguously except by this exact split (curl writes it AFTER the body,
   as the very last bytes) — split on the LAST newline. Result shape:
   `{"status" INT "body" STRING}`, mirroring `run`'s `{"exit" "out" "err"}`
   convention (VString keys). A curl PROCESS failure (missing binary,
   couldn't connect, timeout) is a pp-level error; an HTTP-level error
   status (404, 500, …) is not — it comes back as an ordinary result, same
   as `run`'s nonzero exit code never being an OCaml exception. *)
let http_request ~(method_ : string) ~(url : string) ~(body : string option) : value =
  if !Runtime.trace_stack <> [] then
    failwith (Printf.sprintf
      "perform http-%s: network effects may not appear inside node bodies (LAW 37/38)"
      (String.lowercase_ascii method_));
  let (_scheme, host, port) = parse_http_url url in
  if not (has_network_cap ~host ~port:(Some port)) then
    raise (Capability_error
      (Printf.sprintf "capability error: no network authority for %s:%d" host port));
  let curl = curl_bin () in
  let base_argv = [curl; "-sS"; "--max-time"; "30"; "-w"; "\n%{http_code}"] in
  let (argv, cleanup) =
    match body with
    | None -> (base_argv @ [url], fun () -> ())
    | Some content ->
        let tmp = Filename.temp_file "pp-http-body" "" in
        let oc = open_out_bin tmp in
        output_string oc content; close_out oc;
        (base_argv @ ["-X"; "POST"; "--data-binary"; "@" ^ tmp; url],
         fun () -> (try Sys.remove tmp with _ -> ()))
  in
  Fun.protect ~finally:cleanup (fun () ->
    let (code, out, err) = exec argv in
    if code <> 0 then
      failwith (Printf.sprintf "perform http-%s: curl failed (exit %d): %s"
                  (String.lowercase_ascii method_) code (String.trim err))
    else
      match String.rindex_opt out '\n' with
      | Some i ->
          let resp_body = String.sub out 0 i in
          let status_s = String.trim (String.sub out (i + 1) (String.length out - i - 1)) in
          let status = match int_of_string_opt status_s with Some s -> s | None -> 0 in
          VMap [(VString "status", VInt status); (VString "body", VString resp_body)]
      | None ->
          VMap [(VString "status", VInt 0); (VString "body", VString out)])