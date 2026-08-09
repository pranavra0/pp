open Pp_kernel
type t = { layout : Store_layout.t }
let create layout = { layout }
let put t content =
  Store_layout.ensure_area t.layout Store_layout.Blobs;
  let hash = Hasher.hash_string content in
  let path = Store_layout.path t.layout Store_layout.Blobs hash in
  (match Store_layout.read_store path with
   | Some existing when Hasher.hash_string existing = hash -> ()
   | _ -> Store_layout.atomic_replace path content);
  hash
let get t hash =
  Option.bind (Store_layout.read_store (Store_layout.path t.layout Store_layout.Blobs hash))
    (fun content ->
      if Hasher.hash_string content = hash then Some content else None)
let keys t = Store_layout.list t.layout Store_layout.Blobs
