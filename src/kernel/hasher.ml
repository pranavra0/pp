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

let k = Array.map Int32.of_string [|
  "0x428a2f98"; "0x71374491"; "0xb5c0fbcf"; "0xe9b5dba5";
  "0x3956c25b"; "0x59f111f1"; "0x923f82a4"; "0xab1c5ed5";
  "0xd807aa98"; "0x12835b01"; "0x243185be"; "0x550c7dc3";
  "0x72be5d74"; "0x80deb1fe"; "0x9bdc06a7"; "0xc19bf174";
  "0xe49b69c1"; "0xefbe4786"; "0x0fc19dc6"; "0x240ca1cc";
  "0x2de92c6f"; "0x4a7484aa"; "0x5cb0a9dc"; "0x76f988da";
  "0x983e5152"; "0xa831c66d"; "0xb00327c8"; "0xbf597fc7";
  "0xc6e00bf3"; "0xd5a79147"; "0x06ca6351"; "0x14292967";
  "0x27b70a85"; "0x2e1b2138"; "0x4d2c6dfc"; "0x53380d13";
  "0x650a7354"; "0x766a0abb"; "0x81c2c92e"; "0x92722c85";
  "0xa2bfe8a1"; "0xa81a664b"; "0xc24b8b70"; "0xc76c51a3";
  "0xd192e819"; "0xd6990624"; "0xf40e3585"; "0x106aa070";
  "0x19a4c116"; "0x1e376c08"; "0x2748774c"; "0x34b0bcb5";
  "0x391c0cb3"; "0x4ed8aa4a"; "0x5b9cca4f"; "0x682e6ff3";
  "0x748f82ee"; "0x78a5636f"; "0x84c87814"; "0x8cc70208";
  "0x90befffa"; "0xa4506ceb"; "0xbef9a3f7"; "0xc67178f2"
|]

let rotr x n =
  Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

let sha256 s =
  let length = String.length s in
  let padded_length = ((length + 9 + 63) / 64) * 64 in
  let padded = Bytes.make padded_length '\000' in
  Bytes.blit_string s 0 padded 0 length;
  Bytes.set padded length '\x80';
  let bit_length = Int64.mul (Int64.of_int length) 8L in
  for i = 0 to 7 do
    Bytes.set padded (padded_length - 1 - i)
      (Char.chr (Int64.to_int (Int64.logand
        (Int64.shift_right_logical bit_length (8 * i)) 0xffL)))
  done;
  let h = [|
    Int32.of_string "0x6a09e667"; Int32.of_string "0xbb67ae85";
    Int32.of_string "0x3c6ef372"; Int32.of_string "0xa54ff53a";
    Int32.of_string "0x510e527f"; Int32.of_string "0x9b05688c";
    Int32.of_string "0x1f83d9ab"; Int32.of_string "0x5be0cd19"
  |] in
  let word offset index =
    let base = offset + (index * 4) in
    let at i = Int32.of_int (Char.code (Bytes.get padded (base + i))) in
    Int32.logor (Int32.shift_left (at 0) 24)
      (Int32.logor (Int32.shift_left (at 1) 16)
        (Int32.logor (Int32.shift_left (at 2) 8) (at 3)))
  in
  let sigma0 x = Int32.logxor (Int32.logxor (rotr x 7) (rotr x 18))
      (Int32.shift_right_logical x 3) in
  let sigma1 x = Int32.logxor (Int32.logxor (rotr x 17) (rotr x 19))
      (Int32.shift_right_logical x 10) in
  let big_sigma0 x = Int32.logxor (Int32.logxor (rotr x 2) (rotr x 13))
      (rotr x 22) in
  let big_sigma1 x = Int32.logxor (Int32.logxor (rotr x 6) (rotr x 11))
      (rotr x 25) in
  let ch x y z = Int32.logxor (Int32.logand x y)
      (Int32.logand (Int32.lognot x) z) in
  let maj x y z = Int32.logxor (Int32.logxor (Int32.logand x y)
      (Int32.logand x z)) (Int32.logand y z) in
  let add4 a b c d = Int32.add (Int32.add a b) (Int32.add c d) in
  for block = 0 to (padded_length / 64) - 1 do
    let offset = block * 64 in
    let w = Array.make 64 0l in
    for i = 0 to 15 do w.(i) <- word offset i done;
    for i = 16 to 63 do
      w.(i) <- Int32.add (Int32.add (sigma1 w.(i - 2)) w.(i - 7))
        (Int32.add (sigma0 w.(i - 15)) w.(i - 16))
    done;
    let a = ref h.(0) and b = ref h.(1) and c = ref h.(2) in
    let d = ref h.(3) and e = ref h.(4) and f = ref h.(5) in
    let g = ref h.(6) and hh = ref h.(7) in
    for i = 0 to 63 do
      let t1 = add4 !hh (big_sigma1 !e) (ch !e !f !g)
          (Int32.add k.(i) w.(i)) in
      let t2 = Int32.add (big_sigma0 !a) (maj !a !b !c) in
      hh := !g; g := !f; f := !e; e := Int32.add !d t1;
      d := !c; c := !b; b := !a; a := Int32.add t1 t2
    done;
    h.(0) <- Int32.add h.(0) !a; h.(1) <- Int32.add h.(1) !b;
    h.(2) <- Int32.add h.(2) !c; h.(3) <- Int32.add h.(3) !d;
    h.(4) <- Int32.add h.(4) !e; h.(5) <- Int32.add h.(5) !f;
    h.(6) <- Int32.add h.(6) !g; h.(7) <- Int32.add h.(7) !hh
  done;
  let raw = Bytes.create 32 in
  Array.iteri (fun i value ->
    for j = 0 to 3 do
      Bytes.set raw (i * 4 + j)
        (Char.chr (Int32.to_int (Int32.logand
          (Int32.shift_right_logical value (24 - 8 * j)) 0xffl)))
    done) h;
  Bytes.unsafe_to_string raw

let hash_string (s : string) : string =
  hex_encode (sha256 s)

(* Injective framing.  Each part is emitted as its byte length in decimal, a
   ':', then the part's bytes — so the pre-hash string can be parsed back to
   the exact part list (read digits to ':', then read that many bytes,
   repeat).  Distinct part LISTS therefore map to distinct pre-hash strings
   even when a part itself holds a ':' (user paths, symbol names, tags) or is
   empty.  A plain `String.concat ":"` would be ambiguous the instant any
   part held a ':' — a collision where two distinct ASTs share
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
