(* Signed cluster tokens carry capability grants between pp processes.
   They use canonical text, not pp values. User code cannot create or inspect
   them. Verification checks the MAC, cluster id, expiry, and grant syntax. *)

open Codec


(* Cluster identity: ~/.pp/cluster/{secret,id}. The secret is the trust
   anchor. Operators copy it to other members outside pp. *)

(* Host effects arrive through an immutable service value. *)
let cluster_dir host : string =
  Filename.concat (host.Host_services.home_dir ()) ".pp/cluster"

let secret_path host : string = Filename.concat (cluster_dir host) "secret"
let id_path host : string = Filename.concat (cluster_dir host) "id"

let read_trimmed host path = host.Host_services.read_secret path

(* Write [content] to a new file at [path] with mode 0600. Refuse to replace
   an existing file. *)
let write_secret_file host path content = host.Host_services.write_secret path content

let load_secret host : string =
  try read_trimmed host (secret_path host)
  with _ ->
    failwith (Printf.sprintf
      "pp: no cluster secret at %s — run `pp cluster-init` on the root \
       machine, then copy that file to this one out of band (the \
       docs/THREAT-MODEL-cluster.md trust anchor; same posture as an ssh \
       host key)" (secret_path host))

let load_cluster_id host : string =
  try read_trimmed host (id_path host)
  with _ ->
    failwith (Printf.sprintf
      "pp: no cluster id at %s — run `pp cluster-init` (it writes id and \
       secret together)" (id_path host))

(* [cluster-init] creates a secret and a cluster id. The secret uses the
   secure random source and is stored as hex text. *)

(* ---- Token wire format ----

     (cluster-token (SPEC ...) "CLUSTER-ID" ISSUED EXPIRES "MAC")

   SPEC ... are the --grant spec strings verbatim ("fs:/x:rw", "process",
   ...), each quoted (Codec.quote_string — the same escaping Trace_repository's
   trace-line codec reuses; a granted path can contain spaces). ISSUED/
   EXPIRES are decimal Unix seconds. MAC is hex HMAC-SHA256 of the payload
   WITHOUT the MAC field (below), under the cluster secret. A hand-rolled
   parser mirrors Trace_repository's line codec: this is a bespoke line
   format, not a Core_model.value, so it goes through Codec's string-quoting
   helper only, not its value grammar. *)

let payload_text (specs : string list) (cluster_id : string) (issued : int) (expires : int) : string =
  Printf.sprintf "(cluster-token (%s) %s %d %d)"
    (String.concat " " (List.map Codec.quote_string specs))
    (Codec.quote_string cluster_id) issued expires

let mac_of (secret : string) (payload : string) : string =
  Hasher.hex_encode (Cryptokit.hash_string (Cryptokit.MAC.hmac_sha256 secret) payload)

let mint host ~(secret : string) ~(cluster_id : string) ~(specs : string list)
    ~(ttl_seconds : int) : string =
  let issued = int_of_float (host.Host_services.unix_time ()) in
  let expires = issued + ttl_seconds in
  let payload = payload_text specs cluster_id issued expires in
  let mac = mac_of secret payload in
  (* Splice the MAC into the payload's outer parens: [payload] ends in
     ")"; drop it, append the quoted MAC and re-close. *)
  let body = String.sub payload 0 (String.length payload - 1) in
  Printf.sprintf "%s %s)" body (Codec.quote_string mac)

(* ---- Parser ----
   Hand-rolled, matching [mint]'s output exactly; [None] on anything else
   (a corrupted or foreign-format token) — never half-trusted. Same
   Option-bind style as Trace_repository's line_to_trace. *)


(* Reads digits (with an optional leading '-') up to the next ' ' or ')'. *)
let read_int (s : string) (i : int) : (int * int) option =
  let len = String.length s in
  let is_stop c = c = ' ' || c = ')' in
  let j = ref i in
  while !j < len && not (is_stop s.[!j]) do incr j done;
  match int_of_string_opt (String.sub s i (!j - i)) with
  | Some n -> Some (n, !j)
  | None -> None

type parsed_token = {
  pt_specs : string list;
  pt_cluster_id : string;
  pt_issued : int;
  pt_expires : int;
  pt_mac : string;
}

let parse_token (s : string) : parsed_token option =
  let len = String.length s in
  let parse_specs i =
    if i < len && s.[i] = ')' then Some ([], i + 1)
    else
      let rec loop i acc =
        Codec.parse_quoted_string s i >>= fun (spec, i) ->
        if i < len && s.[i] = ')' then Some (List.rev (spec :: acc), i + 1)
        else expect_char s i ' ' >>= fun i -> loop i (spec :: acc)
      in
      loop i []
  in
  expect_lit s 0 "(cluster-token (" >>= fun i ->
  parse_specs i >>= fun (specs, i) ->
  expect_char s i ' ' >>= fun i ->
  Codec.parse_quoted_string s i >>= fun (cluster_id, i) ->
  expect_char s i ' ' >>= fun i ->
  read_int s i >>= fun (issued, i) ->
  expect_char s i ' ' >>= fun i ->
  read_int s i >>= fun (expires, i) ->
  expect_char s i ' ' >>= fun i ->
  Codec.parse_quoted_string s i >>= fun (mac, i) ->
  expect_char s i ')' >>= fun i ->
  if i <> len then None
  else Some { pt_specs = specs; pt_cluster_id = cluster_id;
              pt_issued = issued; pt_expires = expires; pt_mac = mac }

(* ---- Verify ----
   MAC -> cluster id -> expiry -> parse caps, in that order (see the module
   header): a forged or foreign-cluster token never reaches the capability
   parser at all. *)
let verify host ~(secret : string) ~(cluster_id : string) (token_text : string)
    : (Capability.t list, string) result =
  match parse_token token_text with
  | None -> Error "malformed cluster token (unparseable or foreign format)"
  | Some pt ->
      let payload = payload_text pt.pt_specs pt.pt_cluster_id pt.pt_issued pt.pt_expires in
      let expected_mac = mac_of secret payload in
      if not (Constant_time.equal expected_mac pt.pt_mac) then
        Error "cluster token rejected: MAC mismatch (tampered, or minted \
               under a different cluster secret)"
      else if pt.pt_cluster_id <> cluster_id then
        Error "cluster token rejected: minted for a different cluster id"
      else if int_of_float (host.Host_services.unix_time ()) > pt.pt_expires then
        Error (Printf.sprintf "cluster token rejected: expired at %d" pt.pt_expires)
      else
        (try Ok (List.map (fun spec -> Capability.mint ~realpath:host.canonical_realpath spec) pt.pt_specs)
         with Failure msg -> Error ("cluster token names an invalid capability: " ^ msg))

(* Convenience for the wire path: verify against the LOCAL member's own
   secret/cluster id (~/.pp/cluster), returning a capability list ready to
   feed straight into the cache-authority check — the wire-verified equivalent
   of a node's captured capabilities locally. *)
let token_to_caps host token_text =
  let secret = load_secret host in
  let cluster_id = load_cluster_id host in
  verify host ~secret ~cluster_id token_text
