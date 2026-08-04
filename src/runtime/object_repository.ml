open Pp_kernel
type t = { layout : Store_layout.t }
let create layout = { layout }
let default = create Store_layout.default
let memory_mode = ref false
let memory : (string, Core_model.value) Hashtbl.t = Hashtbl.create 32
let fenced_memory : (string, Core_model.value) Hashtbl.t = Hashtbl.create 16
let set_memory_mode enabled =
  memory_mode := enabled;
  if enabled then begin Hashtbl.clear memory; Hashtbl.clear fenced_memory end
let put_at t area key value =
  if !memory_mode then
    if area = Store_layout.Fenced_specs then Hashtbl.replace fenced_memory key value
    else Hashtbl.replace memory key value
  else begin
    Store_layout.ensure_area t.layout area;
    let path = Store_layout.path t.layout area key in
    if not (Sys.file_exists path) then
      match Codec.encode_value value with
      | Some content -> Store_layout.atomic_replace path content
      | None -> ()
  end
let get_at t area key =
  if !memory_mode then
    if area = Store_layout.Fenced_specs then Hashtbl.find_opt fenced_memory key
    else Hashtbl.find_opt memory key
  else
    Option.bind (Store_layout.read (Store_layout.path t.layout area key)) Codec.decode_value
let put t ~key ~value = put_at t Store_layout.Objects key value
let get t ~key = get_at t Store_layout.Objects key
let put_fenced t ~hash value = put_at t Store_layout.Fenced_specs hash value
let get_fenced t ~hash = get_at t Store_layout.Fenced_specs hash
let keys t =
  if !memory_mode then Hashtbl.fold (fun key _ acc -> key :: acc) memory []
  else Store_layout.list t.layout Store_layout.Objects
