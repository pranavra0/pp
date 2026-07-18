let authorized path =
  let path = World_path.canonical path in
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let roots =
    World_path.canonical (Filename.concat home ".pp")
    :: Invocation.source_roots (Effect.perform Dynamic_scope.Get_invocation)
  in
  List.exists (fun root -> Paths.under ~root path) roots

let read path =
  let canonical = World_path.canonical path in
  if not (authorized path) then
    failwith
      ("load: " ^ path
       ^ " is outside the interpreter's source roots (loader authority is bounded to the CLI-named programs' directories, the cwd, and ~/.pp)");
  let channel = open_in (canonical :> string) in
  let content = really_input_string channel (in_channel_length channel) in
  close_in channel;
  Dynamic_scope.record_read
    Cell.(to_string (RuntimeFile (canonical :> string)))
    (Types.hash_string content);
  content
