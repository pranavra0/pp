type t = { layout : Store_layout.t }
let create layout = { layout }
let default = create Store_layout.default
let put_at t area key value =
  Store_layout.ensure_area t.layout area;
  let path = Store_layout.path t.layout area key in
  if not (Sys.file_exists path) then
    match Codec.encode_value value with
    | Some content -> Store_layout.atomic_replace path content
    | None -> ()
let get_at t area key =
  Option.bind (Store_layout.read (Store_layout.path t.layout area key)) Codec.decode_value
let put t ~key ~value = put_at t Store_layout.Objects key value
let get t ~key = get_at t Store_layout.Objects key
let put_fenced t ~hash value = put_at t Store_layout.Fenced_specs hash value
let get_fenced t ~hash = get_at t Store_layout.Fenced_specs hash
let keys t = Store_layout.list t.layout Store_layout.Objects
