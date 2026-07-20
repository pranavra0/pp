open Pp_runtime
open Pp_frontend
open Pp_kernel
let run_early cli =
  if Cli.help cli then (Cli.print_help cli; true)
  else if Cli.version cli then (Printf.printf "pp v%s\n" Version.string; true)
  else if Cli.dump_surface_tables cli then
    (print_string (Surface_tables.render_spec_tables ()); true)
  else if Cli.dump_builtins cli then (print_string (Primitives.render_catalog ()); true)
  else match Cli.check_kernel_props cli with
    | Some (seed, count) -> if Kernel_props.run ~seed ~count then exit 0 else exit 1
    | None -> match Cli.lint_file cli with
      | Some file -> Lint.lint_file file; true
      | None -> false

let run_runtime ctx cli =
  if Cli.graph cli then (Store_index.print_graph (); true)
  else match Cli.island_pins cli with
    | Some file -> Island.print_pins file; true
    | None -> false
