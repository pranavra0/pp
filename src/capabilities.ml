(* pp capabilities — authority tokens for the capability system *)

open Types

(* Create capability values *)
let cap_none = VCapability CapNone
let cap_filesystem ~path ~mode = VCapability (CapFilesystem { path; mode })
let cap_network ~protocol = VCapability (CapNetwork { protocol })
let cap_process = VCapability CapProcess

let cap_compose caps =
  let caps = List.map (fun v ->
    match v with
    | VCapability c -> c
    | _ -> failwith "compose expects capability values"
  ) caps in
  VCapability (CapCompose caps)

let cap_restrict cap scope =
  match cap with
  | VCapability c -> VCapability (CapRestrict { cap = c; scope })
  | _ -> failwith "restrict expects a capability value"

(* Path-component-aware scope check: [scope] grants [target] iff target
   equals scope or is inside the directory named by scope. "/tmp" grants
   "/tmp" and "/tmp/x" but NOT "/tmpevil". Trailing slashes on either side
   are ignored (except a bare "/"). *)
let path_grants ~(scope : string) (target : string) : bool =
  let strip s =
    let n = String.length s in
    if n > 1 && s.[n - 1] = '/' then String.sub s 0 (n - 1) else s
  in
  let scope = strip scope in
  let target = strip target in
  scope = target
  || (let prefix = if scope = "/" then "/" else scope ^ "/" in
      String.starts_with ~prefix target)

(* Check if a capability grants a specific permission *)
let rec check_fs_read (cap : capability) (target_path : string) : bool =
  match cap with
  | CapFilesystem { path; mode = Read } ->
      path_grants ~scope:path target_path
  | CapFilesystem { path; mode = ReadWrite } ->
      path_grants ~scope:path target_path
  | CapCompose caps -> List.exists (fun c -> check_fs_read c target_path) caps
  | CapRestrict { cap; scope } ->
      (* Restriction: only allow within the specified scope *)
      path_grants ~scope target_path && check_fs_read cap target_path
  | _ -> false

let rec check_fs_write (cap : capability) (target_path : string) : bool =
  match cap with
  | CapFilesystem { path; mode = Write } ->
      path_grants ~scope:path target_path
  | CapFilesystem { path; mode = ReadWrite } ->
      path_grants ~scope:path target_path
  | CapCompose caps -> List.exists (fun c -> check_fs_write c target_path) caps
  | CapRestrict { cap; scope } ->
      path_grants ~scope target_path && check_fs_write cap target_path
  | _ -> false

let rec check_network (cap : capability) (protocol : string) : bool =
  match cap with
  | CapNetwork { protocol = p } -> p = protocol || p = "any"
  | CapCompose caps -> List.exists (fun c -> check_network c protocol) caps
  | _ -> false

let rec check_process (cap : capability) : bool =
  match cap with
  | CapProcess -> true
  | CapCompose caps -> List.exists check_process caps
  | _ -> false

(* Get the effective filesystem paths from a capability *)
let rec list_fs_paths (cap : capability) : (string * fs_mode) list =
  match cap with
  | CapFilesystem { path; mode } -> [(path, mode)]
  | CapCompose caps -> List.concat_map list_fs_paths caps
  | CapRestrict { cap; scope } ->
      List.map (fun (p, m) -> (Filename.concat scope p, m)) (list_fs_paths cap)
  | _ -> []
