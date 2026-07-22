open Pp_kernel
type graph = {
  forward : (string * string list) list;
  reverse : (string * string list) list;
}
let reverse () =
  let result = Hashtbl.create 64 in
  List.iter (fun key ->
    let key_s = Identity_types.Cache_key.to_string key in
    let cells = Trace_repository.load Trace_repository.default ~key
      |> List.concat_map (fun trace ->
           List.map (fun (cell, _) -> Identity_types.Cell_id.to_string cell)
             trace.Trace_repository.reads)
      |> List.sort_uniq compare
    in
    List.iter (fun cell ->
      Hashtbl.replace result cell
        (key_s :: Option.value ~default:[] (Hashtbl.find_opt result cell)))
      cells)
    (List.sort compare (Trace_repository.keys Trace_repository.default));
  result

let dirty_keys ~dependency_cell changed reverse =
  let rec visit_cells seen_keys = function
    | [] -> seen_keys
    | cell :: cells ->
        let keys = Option.value ~default:[] (Hashtbl.find_opt reverse cell) in
        let fresh = List.filter (fun key -> not (List.mem key seen_keys)) keys in
        visit_cells (fresh @ seen_keys)
          (List.rev_append (List.filter_map dependency_cell fresh) cells)
  in
  List.sort_uniq compare (visit_cells [] changed)

let short = Cache_policy.short_key

let graph ?(verbose=false) () =
  let reverse = reverse () in
  let forward = Hashtbl.create 64 in
  Hashtbl.iter (fun cell keys -> if verbose || cell <> "handler:log" then
    List.iter (fun key -> Hashtbl.replace forward key
      (cell :: Option.value ~default:[] (Hashtbl.find_opt forward key))) keys)
    reverse;
  let entries table = Hashtbl.to_seq table |> List.of_seq |> List.sort compare
    |> List.map (fun (key, values) -> (key, List.sort_uniq compare values)) in
  { forward = entries forward;
    reverse = entries reverse |> List.filter (fun (cell, _) -> verbose || cell <> "handler:log") }

let format_graph graph =
  if graph.forward = [] then "(no traces in store — run a program first)\n"
  else
    let buffer = Buffer.create 1024 in
    Buffer.add_string buffer
      "pp graph — dependency graph from ~/.pp/store/traces\n\nNodes → Cells (forward edges):\n";
    List.iter (fun (key, cells) ->
      Printf.bprintf buffer "  node %s\n    reads: %s\n" (short key)
        (String.concat ", " cells)) graph.forward;
    Buffer.add_string buffer "\nCells → Nodes (reverse edges):\n";
    List.iter (fun (cell, keys) ->
      Printf.bprintf buffer "  %s\n    used by: %s\n" cell
        (String.concat ", " (List.map short keys))) graph.reverse;
    Printf.bprintf buffer "\n%d node(s), %d unique cell(s)\n"
      (List.length graph.forward) (List.length graph.reverse);
    Buffer.contents buffer

let print_graph ?(verbose=false) () = print_string (format_graph (graph ~verbose ()))
