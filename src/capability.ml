(* pp capabilities — authority tokens for the capability system.

   [t] is abstract; the variant constructors live only here. *)

type fs_mode = Read | Write | ReadWrite

type t =
  | CapFilesystem of { path : Paths.canonical; mode : fs_mode }
  | CapNetwork of { host : string; port : int option }
  | CapSecret of { path : Paths.canonical }
  | CapProcess
  | CapCompose of t list
  | CapRestrict of { cap : t; scope : Paths.canonical; mode : fs_mode option }
  | CapNone

let none = CapNone

let compose (caps : t list) : t =
  CapCompose caps

let restrict ?(mode : fs_mode option) (cap : t) (scope : Paths.canonical) : t =
  CapRestrict { cap; scope; mode }

(* Path-component-aware scope check: [scope] grants [target] iff target
   equals scope or is inside the directory named by scope. Both sides are
   canonical by construction. *)
let path_grants ~(scope : Paths.canonical) (target : Paths.canonical) : bool =
  Paths.under ~root:scope target

let mode_name = function
  | Read -> "ro" | Write -> "wo" | ReadWrite -> "rw"

let rec check_fs_read (cap : t) (target : Paths.canonical) : bool =
  match cap with
  | CapFilesystem { path; mode = Read }
  | CapFilesystem { path; mode = ReadWrite } ->
      path_grants ~scope:path target
  | CapCompose caps -> List.exists (fun c -> check_fs_read c target) caps
  | CapRestrict { cap = inner; scope; mode } ->
      path_grants ~scope target
      && check_fs_read inner target
      && (match mode with Some Read -> true | Some Write -> false | Some ReadWrite -> true | None -> true)
  | _ -> false

let rec check_fs_write (cap : t) (target : Paths.canonical) : bool =
  match cap with
  | CapFilesystem { path; mode = Write }
  | CapFilesystem { path; mode = ReadWrite } ->
      path_grants ~scope:path target
  | CapCompose caps -> List.exists (fun c -> check_fs_write c target) caps
  | CapRestrict { cap = inner; scope; mode } ->
      path_grants ~scope target
      && check_fs_write inner target
      && (match mode with Some Read -> false | Some Write -> true | Some ReadWrite -> true | None -> true)
  | _ -> false

let rec check_network (cap : t) ~(host : string) ~(port : int option) : bool =
  match cap with
  | CapNetwork { host = h; port = p } ->
      (h = "*" || h = host)
      && (match p with
          | None -> true
          | Some p -> (match port with Some q -> q = p | None -> false))
  | CapCompose caps -> List.exists (fun c -> check_network c ~host ~port) caps
  | CapRestrict { cap = inner; _ } -> check_network inner ~host ~port
  | _ -> false

let rec check_secret (cap : t) (target : Paths.canonical) : bool =
  match cap with
  | CapSecret { path } -> path_grants ~scope:path target
  | CapCompose caps -> List.exists (fun c -> check_secret c target) caps
  | CapRestrict { cap = inner; scope; mode = _ } ->
      path_grants ~scope target && check_secret inner target
  | _ -> false

let rec check_process (cap : t) : bool =
  match cap with
  | CapProcess -> true
  | CapCompose caps -> List.exists check_process caps
  | CapRestrict { cap = inner; _ } -> check_process inner
  | _ -> false

let mode_intersect (a : fs_mode) (b : fs_mode) : fs_mode option =
  match a, b with
  | ReadWrite, m | m, ReadWrite -> Some m
  | Read, Read -> Some Read
  | Write, Write -> Some Write
  | Read, Write | Write, Read -> None

let rec list_fs_paths (cap : t) : (Paths.canonical * fs_mode) list =
  match cap with
  | CapFilesystem { path; mode } -> [(path, mode)]
  | CapCompose caps -> List.concat_map list_fs_paths caps
  | CapRestrict { cap = inner; scope; mode } ->
      let cscope = scope in
      List.filter_map (fun (p, m) ->
        let effective_path =
          if Paths.under ~root:cscope p then Some p
          else if Paths.under ~root:p cscope then Some cscope
          else None
        in
        match effective_path with
        | None -> None
        | Some ep ->
            (match mode with
             | None -> Some (ep, m)
             | Some rm ->
                 (match mode_intersect m rm with
                  | Some m' -> Some (ep, m')
                  | None -> None)))
        (list_fs_paths inner)
  | _ -> []

let err_with_caps_widen =
  "with-caps: requested capability is not a subset of the current capabilities"

let rec cap_non_fs_subseteq (cap : t) (held : t) : bool =
  match cap with
  | CapNetwork { host; port } -> check_network held ~host ~port
  | CapSecret { path } -> check_secret held path
  | CapCompose caps -> List.for_all (fun c -> cap_non_fs_subseteq c held) caps
  | CapRestrict { cap = inner; _ } -> cap_non_fs_subseteq inner held
  | _ -> true

let rec cap_subseteq (requested : t) (ambient : t list) : bool =
  let held = CapCompose ambient in
  match requested with
  | CapNone -> true
  | CapProcess -> check_process held
  | CapNetwork { host; port } -> check_network held ~host ~port
  | CapSecret { path } -> check_secret held path
  | CapFilesystem { path; mode } ->
      (match mode with
       | Read -> check_fs_read held path
       | Write -> check_fs_write held path
       | ReadWrite -> check_fs_read held path && check_fs_write held path)
  | CapCompose caps -> List.for_all (fun c -> cap_subseteq c ambient) caps
  | CapRestrict { cap; _ } as r ->
      list_fs_paths r |> List.for_all (fun (path, m) ->
        match m with
        | Read -> check_fs_read held path
        | Write -> check_fs_write held path
        | ReadWrite -> check_fs_read held path && check_fs_write held path)
      && (not (check_process r) || check_process held)
      && cap_non_fs_subseteq cap held

let subseteq = cap_subseteq

(* ---- Grant-spec parsing: the one mint site + token verify reuses this ---- *)
let mint ~realpath (spec : string) : t =
  match String.split_on_char ':' spec with
  | ["fs"; path; mode] ->
      let m = match mode with
        | "ro" -> Read | "rw" -> ReadWrite | "wo" -> Write
        | _ -> failwith ("invalid fs mode in --grant: " ^ mode)
      in
      CapFilesystem { path = Paths.canonicalize ~realpath path; mode = m }
  | ["net"; host] -> CapNetwork { host; port = None }
  | ["net"; host; port] ->
      (match int_of_string_opt port with
       | Some p -> CapNetwork { host; port = Some p }
       | None -> failwith ("invalid port in --grant net spec: " ^ spec))
  | ["secret"; path] ->
      CapSecret { path = Paths.canonicalize ~realpath path }
  | ["process"] -> CapProcess
  | _ -> failwith ("invalid --grant spec: " ^ spec)

(* ---- Hashing ---- *)
let rec hash (c : t) : string =
  match c with
  | CapFilesystem { path; mode } ->
      let m = match mode with Read -> "r" | Write -> "w" | ReadWrite -> "rw" in
      Hasher.hash_concat ["cap_fs"; (path :> string); m]
  | CapNetwork { host; port } ->
      Hasher.hash_concat ["cap_net"; host; (match port with Some p -> string_of_int p | None -> "any")]
  | CapSecret { path } ->
      Hasher.hash_concat ["cap_secret"; (path :> string)]
  | CapProcess -> Hasher.hash_string "cap_process"
  | CapCompose caps ->
      Hasher.hash_concat ("cap_compose" :: List.map hash caps)
  | CapRestrict { cap = inner; scope; mode } ->
      let m = match mode with
        | None -> "any" | Some Read -> "r" | Some Write -> "w" | Some ReadWrite -> "rw" in
      Hasher.hash_concat ["cap_restrict"; hash inner; (scope :> string); m]
  | CapNone -> Hasher.hash_string "cap_none"

(* ---- Display ---- *)
let to_string (c : t) : string =
  match c with
  | CapFilesystem { path; mode } ->
      let m = match mode with Read -> ":ro" | Write -> ":wo" | ReadWrite -> ":rw" in
      "#<cap fs " ^ (path :> string) ^ " " ^ m ^ ">"
  | CapNetwork { host; port } ->
      "#<cap net " ^ host ^ (match port with Some p -> ":" ^ string_of_int p | None -> "") ^ ">"
  | CapSecret { path } -> "#<cap secret " ^ (path :> string) ^ ">"
  | CapProcess -> "#<cap process>"
  | CapCompose caps -> "#<cap compose " ^ string_of_int (List.length caps) ^ ">"
  | CapRestrict { scope; mode; _ } ->
      let m = match mode with
        | None -> "" | Some Read -> " :ro" | Some Write -> " :wo" | Some ReadWrite -> " :rw" in
      "#<cap restrict " ^ (scope :> string) ^ m ^ ">"
  | CapNone -> "#<cap none>"

(* ---- Ratchet / property testing ---- *)
type cap_tag =
  | Ct_none | Ct_filesystem | Ct_network | Ct_secret | Ct_process
  | Ct_compose | Ct_restrict

let cap_kind : t -> cap_tag = function
  | CapNone -> Ct_none
  | CapFilesystem _ -> Ct_filesystem
  | CapNetwork _ -> Ct_network
  | CapSecret _ -> Ct_secret
  | CapProcess -> Ct_process
  | CapCompose _ -> Ct_compose
  | CapRestrict _ -> Ct_restrict

let all_cap_tags =
  [ Ct_none; Ct_filesystem; Ct_network; Ct_secret; Ct_process;
    Ct_compose; Ct_restrict ]

let () = assert (List.length all_cap_tags = 7)

let atomic_cap_tags =
  [ Ct_none; Ct_filesystem; Ct_network; Ct_secret; Ct_process ]

let cap_paths = [| "/g"; "/g/a"; "/g/a/b"; "/g/x"; "/h"; "/" |]
let cap_hosts = [| "*"; "example.com"; "other.net" |]
let cap_ports = [| None; Some 80; Some 443 |]
let cap_modes = [| Read; Write; ReadWrite |]

let rec gen_cap (st : Random.State.t) (depth : int) : t =
  let ri st n = Random.State.int st (max 1 n) in
  let rb st = Random.State.bool st in
  let pick st a = a.(Random.State.int st (Array.length a)) in
  if depth <= 0 then
    let tag = pick st (Array.of_list atomic_cap_tags) in
    match tag with
    | Ct_none -> CapNone
    | Ct_filesystem ->
        CapFilesystem { path = Paths.canonicalize ~realpath:(fun x -> x) (pick st cap_paths);
                        mode = pick st cap_modes }
    | Ct_network ->
        CapNetwork { host = pick st cap_hosts; port = pick st cap_ports }

    | Ct_secret ->
        CapSecret { path = Paths.canonicalize ~realpath:(fun x -> x) (pick st cap_paths) }
    | Ct_process -> CapProcess
    | _ -> CapNone
  else
    let d = depth - 1 in
    let tag = pick st (Array.of_list all_cap_tags) in
    match tag with
    | Ct_none -> CapNone
    | Ct_filesystem ->
        CapFilesystem { path = Paths.canonicalize ~realpath:(fun x -> x) (pick st cap_paths);
                        mode = pick st cap_modes }
    | Ct_network ->
        CapNetwork { host = pick st cap_hosts; port = pick st cap_ports }
    | Ct_secret ->
        CapSecret { path = Paths.canonicalize ~realpath:(fun x -> x) (pick st cap_paths) }
    | Ct_process -> CapProcess
    | Ct_compose ->
        let n = 1 + ri st 3 in
        CapCompose (List.init n (fun _ -> gen_cap st d))
    | Ct_restrict ->
        let cap = gen_cap st d in
        let scope = Paths.canonicalize ~realpath:(fun x -> x) (pick st cap_paths) in
        let mode = if rb st then None else Some (pick st cap_modes) in
        CapRestrict { cap; scope; mode }

let cap_probe_vector (c : t) : bool list =
  let id = Paths.canonicalize ~realpath:(fun x -> x) "/" in
  [ check_fs_read c id;    check_fs_write c id;
    check_network c ~host:"*" ~port:None;     check_network c ~host:"example.com" ~port:(Some 80);
    check_secret c id;     check_process c ]

let cap_subseteq_probes (a : t) (b : t) : bool =
  List.for_all2 (fun x y -> (not x) || y)
    (cap_probe_vector a) (cap_probe_vector b)