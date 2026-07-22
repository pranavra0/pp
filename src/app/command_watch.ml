open Pp_runtime
open Pp_kernel
let snapshot_cell_hashes ids =
  List.filter_map (fun id ->
    match Observation.observe_id (Identity_types.Cell_id.of_string id) with
    | Some hash -> Some (id, Identity_types.Observed_hash.to_string hash)
    | None -> None) ids

let run ctx cli files =
  let session = App_context.session ctx in
  let last_desired = ref None in
  let observe () =
    Session.begin_pass session;
    let last = Command_run.run_files ctx cli files in
    last_desired := last;
    Command_reconcile.run_pass ctx cli last;
    snapshot_cell_hashes
      (List.sort_uniq compare (List.map fst (Session.observations session)))
  in
  let observe_changed ~previous changed_cells =
    let reverse = Store_index.reverse () in
    Stabilize.add_runtime_edges reverse;
    let dirty = Store_index.dirty_keys ~dependency_cell:Stabilize.dependency_cell
      changed_cells reverse in
    Stabilize.reset_dirty (List.map Identity_types.Node_key.of_string dirty);
    Session.begin_pass session;
    let last = Command_run.run_files ~retain_thunks:true ctx cli files in
    last_desired := last;
    Command_reconcile.run_pass ctx cli last;
    let current = snapshot_cell_hashes
      (List.sort_uniq compare (List.map fst (Session.observations session))) in
    let current_ids = List.map fst current in
    let clean = List.filter (fun (id, _) -> not (List.mem id current_ids)) previous in
    current @ clean
  in
  if Cli.stabilize cli then Session.begin_watch session;
  let rec loop snapshot =
    (try Unix.sleepf (Cli.watch_interval cli) with _ -> Unix.sleep 1);
    Session.begin_pass session;
    ignore (Event_sink.emit (Session.event_sink session) (Event.Runtime_boundary {
      boundary = Event.Watch_poll; subject = "cells"; count = List.length snapshot;
    }));
    let changed = List.filter_map (fun (cell, recorded) ->
      match Observation.observe_id (Identity_types.Cell_id.of_string cell) with
      | Some current when Identity_types.Observed_hash.to_string current <> recorded -> Some cell
      | _ -> None) snapshot in
    if changed <> [] then
      (ignore (Event_sink.emit (Session.event_sink session) (Event.Runtime_boundary {
         boundary = Event.Watch_changed; subject = "cells"; count = List.length changed;
       }));
      if Cli.stabilize cli then begin
        Printf.eprintf "[watch] %d cell(s) changed — stabilizing\n%!" (List.length changed);
        loop (observe_changed ~previous:snapshot changed)
      end else begin
        Printf.eprintf "[watch] cell(s) changed — re-evaluating\n%!";
        loop (observe ())
      end)
    else begin
      (match !last_desired with
       | Some value -> Command_reconcile.run_pass ctx cli (Some value)
       | None -> ());
      loop snapshot
    end
  in
  loop (observe ())
