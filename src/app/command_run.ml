open Pp_runtime
open Pp_kernel
open Source_error
open Core_model
let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))


let uses_domains cli =
  Cli.reconcile_root cli <> None || Cli.supervise cli

let string_value s = ELiteral (VString s)
let call name args = EApply (ESymbol name, args)
let load path = ELoad path

let stdlib_glue_sources cli =
  if not (uses_domains cli) then []
  else match World_path.stdlib_root () with
    | None ->
        command "pp: could not locate the stdlib/ directory next to the running executable (needed for --reconcile/--supervise's domain-fs.pp/domain-proc.pp)"
    | Some root ->
        let common = List.map (fun file ->
          ("<stdlib:" ^ file ^ ">",
           [load (Filename.concat root file)]))
          ["list.pp"; "map.pp"; "string.pp"]
        in
        let fs = match Cli.reconcile_root cli with
          | None -> []
          | Some root_path ->
              let canonical = (World_path.canonical root_path :> string) in
              [("<domain-glue:fs>",
                [load (Filename.concat root "domain-fs.pp");
                 call "register-fs-domain!"
                   [string_value canonical;
                    call "cap-restrict"
                      [call "current-capabilities" [];
                       string_value canonical;
                       ELiteral (VKeyword "wo")]]])]
        in
        let proc = if Cli.supervise cli then
          [("<domain-glue:proc>",
            [load (Filename.concat root "domain-proc.pp");
             call "register-proc-domain!" [call "current-capabilities" []]])]
        else [] in
        common @ fs @ proc

let run_files ?(retain_thunks = false) ctx cli files =
  if uses_domains cli then
    let sources = List.map (fun f -> (f, read_file f)) files in
    let prefix = stdlib_glue_sources cli in
    match List.rev
      (Repl.execute_sources_with_prelude ~retain_thunks prefix sources) with
    | value :: _ -> Some value
    | [] -> None
  else
    List.fold_left (fun _ file ->
      match List.rev (Repl.execute_file ~retain_thunks file) with
      | value :: _ -> Some value
      | [] -> None) None files

let build_all_desired cli value =
  (match Cli.reconcile_root cli with
   | None -> ()
   | Some _ ->
       match Artifact_tree.of_value (Force_deep.force_deep value) with
       | Ok _ -> ()
       | Error message -> command ("reconcile: invalid canonical tree: " ^ message));
  let entries =
    (match Cli.reconcile_root cli with Some _ -> [(Core_model.VString "fs", value)] | None -> [])
    @ (if Cli.supervise cli then [(Core_model.VString "proc", value)] else [])
  in
  if entries = [] then value else Value.map entries

let compute_desired _ctx cli last =
  match Cli.desired_object cli with
  | Some (hash, _) ->
      (match Object_repository.get Object_repository.default ~key:hash with
       | Some value -> value
       | None -> command (Printf.sprintf
         "pp: --desired-object %s: not found in the local store even after pulling — check the shared root and that it was published there via --publish-object" hash))
  | None ->
      (match last with
       | Some value -> build_all_desired cli value
       | None -> command "reconcile: the program produced no value")

let select_member_slice cli desired =
  match Cli.member_name cli with
  | None -> desired
  | Some name ->
      (match Force_deep.force_deep desired with
       | Core_model.VMap entries ->
           (match List.find_opt (fun (key, _) ->
              match key with
              | Core_model.VString value | Core_model.VKeyword value -> value = name
              | _ -> false) entries with
            | Some (_, value) -> value
            | None -> command (Printf.sprintf
              "pp: --member-name %s: no such host key in the desired-state map (host-qualified distribution expects {host -> {domain -> desired}})" name))
       | value -> command (Printf.sprintf
           "pp: --member-name %s: desired-state must be a map of host -> {domain -> desired} to index, got %s"
           name (Presentation.string_of_value value)))
