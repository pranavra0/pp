type kind = Object | Trace | Blob
type entry = { id : string; modified : float option }
let area = function
  | Object -> Store_layout.Objects | Trace -> Store_layout.Traces | Blob -> Store_layout.Blobs
let entries kind =
  let area = area kind in
  Store_layout.list Store_layout.default area |> List.map (fun id ->
    let modified = match Unix.stat (Store_layout.path Store_layout.default area id) with
      | stat -> Some stat.Unix.st_mtime | exception _ -> None in
    { id; modified })
let remove kind id =
  try Sys.remove (Store_layout.path Store_layout.default (area kind) id) with _ -> ()
