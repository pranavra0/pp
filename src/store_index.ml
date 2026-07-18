let reverse () =
  let result = Hashtbl.create 64 in
  List.iter (fun key ->
    let cells = Trace_repository.load Trace_repository.default ~key
      |> List.concat_map (fun trace -> List.map fst trace.Trace_repository.reads)
      |> List.sort_uniq compare in
    List.iter (fun cell -> Hashtbl.replace result cell
      (key :: Option.value ~default:[] (Hashtbl.find_opt result cell))) cells)
    (List.sort compare (Trace_repository.keys Trace_repository.default));
  result
let dirty_keys changed reverse =
  changed |> List.concat_map (fun cell -> Option.value ~default:[] (Hashtbl.find_opt reverse cell))
  |> List.sort_uniq compare
let short = Cache_policy.short_key
let print_graph ?(verbose=false) () =
  let reverse = reverse () in
  let forward = Hashtbl.create 64 in
  Hashtbl.iter (fun cell keys -> if verbose || cell <> "handler:log" then
    List.iter (fun key -> Hashtbl.replace forward key
      (cell :: Option.value ~default:[] (Hashtbl.find_opt forward key))) keys) reverse;
  if Hashtbl.length forward = 0 then Printf.printf "(no traces in store — run a program first)\n"
  else begin
    Printf.printf "pp graph — dependency graph from ~/.pp/store/traces\n\nNodes → Cells (forward edges):\n";
    Hashtbl.to_seq forward |> List.of_seq |> List.sort compare |> List.iter (fun (key,cells) ->
      Printf.printf "  node %s\n    reads: %s\n" (short key) (String.concat ", " (List.sort compare cells)));
    Printf.printf "\nCells → Nodes (reverse edges):\n";
    Hashtbl.to_seq reverse |> List.of_seq |> List.sort compare |> List.iter (fun (cell,keys) ->
      if verbose || cell <> "handler:log" then Printf.printf "  %s\n    used by: %s\n" cell
        (String.concat ", " (List.sort compare (List.map short keys))));
    Printf.printf "\n%d node(s), %d unique cell(s)\n" (Hashtbl.length forward) (Hashtbl.length reverse)
  end
