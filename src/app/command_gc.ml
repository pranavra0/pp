open Pp_runtime
open Pp_kernel
let run ctx cli =
  Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
    ~f:(fun () -> Store_gc.run ~grace_seconds:(Cli.gc_grace_seconds cli)) ()

let run_mark ctx cli output =
  let last = Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
    ~f:(fun () -> Command_run.run_files ctx cli (Cli.files cli)) () in
  (try
     let desired = Command_run.select_member_slice cli
       (Command_run.compute_desired ctx cli last) in
     let forced = Force_deep.force_deep desired in
     Cache_policy.mark Cache_policy.default ("object:" ^ Identity.hash_value forced);
     List.iter (fun blob -> Cache_policy.mark Cache_policy.default ("blob:" ^ blob))
       (Artifact_tree.reachable_blobs forced)
   with _ -> ());
  let marks = Hashtbl.fold (fun key () acc -> key :: acc)
      (Cache_policy.gc_marks Cache_policy.default) [] in
  Store_layout.atomic_replace output
    (String.concat "\n" marks ^ if marks = [] then "" else "\n")
