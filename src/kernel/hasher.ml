(* pp hasher — the low-level content-addressing primitives.

   SHA-256 hashing and the injective length-framed join live here, at the
   BOTTOM of the dependency graph, so that every module that hashes —
   including [Capability], an early-compiled module that must hash an
   abstract type — goes through one definition.  The higher-level
   [Identity.hash_value]/[Identity.hash_expr] functions stay in [Identity] (they need the
   recursive value/expr types) and are reached as [Identity.hash_value] etc.;
   they are no longer re-exported here, because re-exporting them would make
   [Hasher] depend on [Core_model] while [Identity] depends on [Hasher] for these
   primitives — a cycle. *)

let hex_encode (s : string) : string =
  let chars = "0123456789abcdef" in
  String.init (String.length s * 2) (fun i ->
    let c = Char.code s.[i / 2] in
    let nibble = (if i land 1 = 0 then c lsr 4 else c) land 0xf in
    chars.[nibble])

let hash_string (s : string) : string =
  hex_encode (Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) s)

(* Injective framing.  Each part is emitted as its byte length in decimal, a
   ':', then the part's bytes — so the pre-hash string can be parsed back to
   the exact part list (read digits to ':', then read that many bytes,
   repeat).  Distinct part LISTS therefore map to distinct pre-hash strings
   even when a part itself holds a ':' (user paths, symbol names, tags) or is
   empty.  A plain `String.concat ":"` would be ambiguous the instant any
   part held a ':' — the LAW-20 collision class where two distinct ASTs share
   one content key and pp serves a wrong cached result.  Every hash builder
   funnels through here (and through no other join), so injectivity is a
   single-site property the kernel-properties generated-AST test
   (src/app/kernel_props.ml) guards forever.  Changing this framing is
   hash-affecting across the whole store — see the golden fixture receipt
   (tests/fixtures/store-v1). *)
let hash_concat (parts : string list) : string =
  let buf = Buffer.create 64 in
  List.iter (fun p ->
    Buffer.add_string buf (string_of_int (String.length p));
    Buffer.add_char buf ':';
    Buffer.add_string buf p) parts;
  hash_string (Buffer.contents buf)

let node_key_skeleton ~(expr_hash : string) (fv_hashes : string list) : string =
  hash_concat (["node-key"; expr_hash] @ fv_hashes)
