open Pp_kernel

open Core_model
open Source_error

let has_process_cap () =
  List.exists Capability.check_process (Effect.perform Dynamic_scope.Get_capabilities)

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

let read_all_exn (path : string) : string =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let read_all (path : string) : string =
  try read_all_exn path with
  | Sys_error _ | Unix.Unix_error _ | End_of_file -> ""

(* Execute argv, capturing stdout/stderr. Every execution is journaled. *)
let exec (argv : string list) : int * string * string =
  let program =
    match argv with
    | program :: _ -> program
    | [] -> invalid_arg "Process.exec: empty argv"
  in
  (try Journal.append (Journal.Exec argv) with
   | Sys_error _ | Unix.Unix_error _ -> ());
  let out_f = Filename.temp_file "pp-run" ".out" in
  let err_f = Filename.temp_file "pp-run" ".err" in
  let cleanup () =
    (try Sys.remove out_f with Sys_error _ -> ());
    (try Sys.remove err_f with Sys_error _ -> ())
  in
  Fun.protect ~finally:cleanup (fun () ->
    let fd_out = Unix.openfile out_f [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd_out)
      (fun () ->
        let fd_err = Unix.openfile err_f [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
        Fun.protect
          ~finally:(fun () -> Unix.close fd_err)
          (fun () ->
            let fd_in = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
            Fun.protect
              ~finally:(fun () -> Unix.close fd_in)
              (fun () ->
                let pid =
                  Unix.create_process program (Array.of_list argv)
                    fd_in fd_out fd_err
                in
                let (_, status) = Unix.waitpid [] pid in
                let code = match status with
                  | Unix.WEXITED n -> n
                  | Unix.WSIGNALED s | Unix.WSTOPPED s -> 128 + s
                in
                (code, read_all out_f, read_all err_f)))))

let run_effect (args : value list) : value =
  if Effect.perform Dynamic_scope.In_node then
    failwith "run: may not be called inside a node body (scripting-tier only)";
  if not (has_process_cap ()) then
    capability "capability error: no process authority for run";
  let argv = List.map (function
    | VString s -> s
    | v -> failwith ("run expects string command/arguments, got " ^ Presentation.string_of_value v))
    args
  in
  match argv with
  | [] -> failwith "run expects a command"
  | cmd :: _ ->
      (match resolve_cmd cmd with
       | Some _ -> ()
       | None -> failwith ("run: command not found: " ^ cmd));
      let (code, out, err) = exec argv in
      VMap [ (VString "exit", VInt code);
             (VString "out",  VString out);
             (VString "err",  VString err) ]

(* ---- write-file with the node/scripting split ----
   Shared by the builtin write-file implementation. Inside a node: a relative
   path writes node-local sandbox scratch (capability-free, unrecorded); an
   absolute path is an error — reconciled-domain writes go through the
   reconciler, never node bodies. Scripting tier: unchanged, capability-
   checked, writes anywhere granted. *)
let write_file_effect ~(has_cap : string -> bool) (path : string)
    (content : string) : value =
  match Sandbox.resolve ~create:true path with
  | Some scratch ->
      (try
         let ch = open_out scratch in
         output_string ch content;
         close_out ch;
         VNil
       with Sys_error msg -> failwith ("write-file: " ^ msg))
  | None ->
      if Effect.perform Dynamic_scope.In_node then
        failwith ("write-file: node writes are sandbox-scratch only (LAW 18): "
                  ^ path)
      else begin
        (try
           let ch = open_out path in
           output_string ch content;
           close_out ch;
           (* pp's own write supersedes this run's CAS-ingest pin of the
              cell — later node reads must see the new content, not the
              pre-write pin. *)
           Cell_repository.unpin_file path;
           VNil
         with Sys_error msg -> failwith ("write-file: " ^ msg))
      end

(* ---- capability-free sandbox read, shared by slurp/read-file ----
   Returns Some contents when [path] resolves into the innermost node's
   scratch (relative path, sandbox exists); such reads are node-local and
   deliberately unrecorded. *)
let sandbox_read (path : string) : string option =
  match Sandbox.resolve ~create:false path with
  | Some scratch ->
      (try
         let ic = open_in scratch in
         Fun.protect
           ~finally:(fun () -> close_in_noerr ic)
           (fun () -> Some (really_input_string ic (in_channel_length ic)))
       with Sys_error _ | Unix.Unix_error _ | End_of_file -> None)
  | None -> None

(* ---- Sealed cells: read dispatch shared by slurp/read-file ----

   Sandbox scratch (above) takes precedence, unchanged. Outside a sandbox,
   the GRANT decides the shape of the result, never the program text —
   program text stays deployment-agnostic; only what a given deployment's
   `--grant` set covers determines whether a path reads as a plain string or
   a sealed one:
     - covered by a CapFilesystem read grant (with or without ALSO a
       CapSecret grant) → ordinary VString. Both-grants deliberately
       resolves to plain fs behavior: the deployment that also handed out an
       fs grant over the same path is saying "not secret HERE".
     - covered by CapSecret and NOT by CapFilesystem → VSealed, read via
       Cell_repository.read_sealed (bytes pinned in the session,
       in-memory only — store_blob/the CAS is never called for this path).
     `read-file` each keep their own message text via [cap_err]). *)
let read_dispatch ~(tag : string) ~(cap_err : string -> string) (path : string) : value =
  match sandbox_read path with
  | Some content -> VString content
  | None ->
      let fs_ok =
        List.exists (fun cap -> Capability.check_fs_read cap (World_path.canonical path))
          (Effect.perform Dynamic_scope.Get_capabilities)
      in
      if fs_ok then
        (try VString (Cell_repository.read_file path)
         with Sys_error msg -> failwith (tag ^ ": " ^ msg))
      else
        let secret_ok =
          List.exists (fun cap -> Capability.check_secret cap (World_path.canonical path))
            (Effect.perform Dynamic_scope.Get_capabilities)
        in
        if secret_ok then
          (try VSealed (Cell_repository.read_sealed path)
           with Sys_error msg -> failwith (tag ^ ": " ^ msg))
        else
          capability (cap_err path)

(* ---- Network: `(perform http-get url)` / `(perform http-post url body)` ----

   Implemented by forking curl via [exec] above (zero new OCaml
   networking/TLS surface) but AUTHORIZED against CapNetwork host[:port] —
   not CapProcess: granularity, "may read this host" is a much narrower
   grant than "may exec anything". Banned inside node bodies (trace_stack
   guard, the same pattern used by `Fenced.register` and `write-file`) —
   network reads are not convergent and are not the sanctioned nondeterminism
   mechanism; probe observe functions may use them
   observe-fns (which run with trace_stack forced to [] —
   Observation.probe_value), domain observe/apply, and the script tier. *)
let has_network_cap ~(host : string) ~(port : int option) : bool =
  List.exists (fun cap -> Capability.check_network cap ~host ~port)
    (Effect.perform Dynamic_scope.Get_capabilities)

(* Parse an http(s) URL into (scheme, host, port); port defaults to the
   scheme's standard port when the URL omits one, so a `--grant
   net:host:PORT` still matches a URL that never spells the port out.
   Deliberately minimal — no userinfo, no IPv6 literal brackets; documented
   residuals, not needed for curl (curl gets the WHOLE url verbatim; this
   parse exists only to name the (host, port) pair the authority check
   tests). Anything other than http/https is a hard error. *)
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
   status (404, 500, …) is not — it comes back as an ordinary result, same *)
let http_request ~(method_ : string) ~(url : string) ~(body : string option) : value =
  if Effect.perform Dynamic_scope.In_node then
    failwith (Printf.sprintf
      "perform http-%s: network effects may not appear inside node bodies (LAW 37/38)"
      (String.lowercase_ascii method_));
  let (_scheme, host, port) = parse_http_url url in
  if not (has_network_cap ~host ~port:(Some port)) then
    capability
      (Printf.sprintf "capability error: no network authority for %s:%d" host port);
  let curl = curl_bin () in
  let base_argv = [curl; "-sS"; "--max-time"; "30"; "-w"; "\n%{http_code}"] in
  let (argv, cleanup) =
    match body with
    | None -> (base_argv @ [url], fun () -> ())
    | Some content ->
        let tmp = Filename.temp_file "pp-http-body" "" in
        let oc = open_out_bin tmp in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () -> output_string oc content);
        (base_argv @ ["-X"; "POST"; "--data-binary"; "@" ^ tmp; url],
         fun () -> (try Sys.remove tmp with Sys_error _ -> ()))
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
