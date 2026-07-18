(* pp cluster tokens — signed capability grants for cross-machine authority
   (docs/THREAT-MODEL-cluster.md is the gate this implements against).

   A token is (caps in the --grant CLI grammar, cluster id, issued, expires,
   HMAC-SHA256 MAC) as CANONICAL TEXT — never a pp value. It is minted and
   verified entirely at the CLI/transport layer: there is no reader syntax
   for it and no way to construct or inspect one from inside a pp program,
   so it can never be printed, laundered through a result, or cross the
   node boundary (LAW 22's "capabilities are minted only by the root, never
   by user code", generalized to the wire).

   Verification order is MAC -> cluster id -> expiry -> parse caps, so a
   forged, wrong-cluster, or expired token is rejected before its
   (attacker-controlled) capability specs are ever handed to a parser.
   Caps are parsed with Capabilities.parse_grant — the SAME function
   `pp --grant` uses at the CLI — so `cell_authorized_for (token_to_caps
   ...)` is the existing LAW 23b gate, fed a wire-verified capability list
   standing where `node_caps` stands locally. Zero new authority code. *)

open Codec


(* ---- Cluster identity: ~/.pp/cluster/{secret,id} ----

   The secret is the ONE cluster trust anchor: minted once by
   `pp cluster-init` on a root machine, distributed to other members OUT
   OF BAND (scp / config management / the operator's problem — the same
   posture as an ssh host key; see docs/THREAT-MODEL-cluster.md "Trust
   anchors"). Losing it means re-minting AND redistributing; a member
   without a copy cannot mint OR verify tokens. *)

(* Kernel purity: host effects arrive as a complete immutable service value;
   pp.kernel names no Unix directly. *)
let cluster_dir host : string =
  Filename.concat (host.Host_services.home_dir ()) ".pp/cluster"

let secret_path host : string = Filename.concat (cluster_dir host) "secret"
let id_path host : string = Filename.concat (cluster_dir host) "id"

let read_trimmed host path = host.Host_services.read_secret path

(* Writes [content] to a FRESH file at [path] with mode 0600, refusing to
   overwrite an existing file (O_CREAT + O_EXCL, one syscall — no
   check-then-create race): the one place a secret is created, so there is
   no window where it exists world-readable, and re-running `cluster-init`
   can never silently clobber (and invalidate every token minted against)
   an existing secret. *)
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

(* `pp cluster-init`: mint a fresh secret + cluster id. Cryptokit's secure
   RNG (Random.secure_rng) is the entropy source — the same library
   already used for content hashing (Hasher/Identity), no new crypto
   dependency. The secret is hex-encoded before writing so the file is
   plain, greppable text like every other pp on-disk artifact rather than
   raw bytes; the hex text itself is the HMAC key material below (HMAC
   accepts a key of any length, so there's no need to decode it back to
   the raw 32 bytes). *)

(* ---- Token wire format ----

     (cluster-token (SPEC ...) "CLUSTER-ID" ISSUED EXPIRES "MAC")

   SPEC ... are the --grant spec strings verbatim ("fs:/x:rw", "process",
   ...), each quoted (Codec.quote_string — the same escaping store.ml's
   trace-line codec reuses; a granted path can contain spaces). ISSUED/
   EXPIRES are decimal Unix seconds. MAC is hex HMAC-SHA256 of the payload
   WITHOUT the MAC field (below), under the cluster secret. A hand-rolled
   parser mirrors store.ml's trace-line codec: this is a bespoke line
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
   Option-bind style as store.ml's line_to_trace. *)


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
   feed straight into `cell_authorized_for` — the wire-verified equivalent
   of `node_caps` locally. *)
let token_to_caps host token_text =
  let secret = load_secret host in
  let cluster_id = load_cluster_id host in
  verify host ~secret ~cluster_id token_text
