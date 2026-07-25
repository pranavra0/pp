open Pp_runtime
open Pp_kernel
let run ctx cli =
  Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
    ~f:(fun () -> Store_gc.run ~grace_seconds:(Cli.gc_grace_seconds cli)) ()
