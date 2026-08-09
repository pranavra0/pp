open Pp_kernel
type t = { layout : Store_layout.t }
let create layout = { layout }
let encoded_value value = Codec.encode_value value
let valid_object key value = Identity.hash_value value = key

let write_encoded t area key content =
  Store_layout.ensure_area t.layout area;
  let path = Store_layout.path t.layout area key in
  match Store_layout.read_store path with
  | Some existing when existing = content -> ()
  | _ -> Store_layout.atomic_replace path content

let put_verified t area key value =
  match encoded_value value with
  | None -> ()
  | Some content when valid_object key value ->
      write_encoded t area key content
  | Some _ -> invalid_arg "object repository key does not match value"

let get_verified t area key =
  match Store_layout.read_store (Store_layout.path t.layout area key) with
  | Some content ->
      (match Codec.decode_value content with
       | Some value
         when valid_object key value && encoded_value value = Some content ->
           Some value
       | _ -> None)
  | None -> None

let put t ~key ~value = put_verified t Store_layout.Objects key value
let get t ~key = get_verified t Store_layout.Objects key
let put_fenced t ~hash value =
  put_verified t Store_layout.Fenced_specs hash value
let get_fenced t ~hash =
  get_verified t Store_layout.Fenced_specs hash
let keys t = Store_layout.list t.layout Store_layout.Objects
