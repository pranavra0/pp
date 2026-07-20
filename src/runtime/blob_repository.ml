open Pp_kernel
type t = { layout : Store_layout.t }
let create layout = { layout }
let default = create Store_layout.default
let put t content =
  Store_layout.ensure_area t.layout Store_layout.Blobs;
  let hash = Hasher.hash_string content in
  let path = Store_layout.path t.layout Store_layout.Blobs hash in
  if not (Sys.file_exists path) then Store_layout.atomic_replace path content;
  hash
let get t hash = Store_layout.read (Store_layout.path t.layout Store_layout.Blobs hash)
let keys t = Store_layout.list t.layout Store_layout.Blobs
