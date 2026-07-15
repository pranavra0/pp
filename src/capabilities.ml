(* pp capabilities — authority tokens for the capability system *)

open Types

(* Create capability values *)
let cap_none = VCapability CapNone
let cap_filesystem ~path ~mode = VCapability (CapFilesystem { path; mode })
let cap_network ~host ~port = VCapability (CapNetwork { host; port })
let cap_secret ~path = VCapability (CapSecret { path })
let cap_process = VCapability CapProcess

let cap_compose caps =
  let caps = List.map (fun v ->
    match v with
    | VCapability c -> c
    | _ -> failwith "compose expects capability values"
  ) caps in
  VCapability (CapCompose caps)

(* Path-component-aware scope check: [scope] grants [target] iff target
   equals scope or is inside the directory named by scope. "/tmp" grants
   "/tmp" and "/tmp/x" but NOT "/tmpevil" (Paths.under — the one shared
   containment predicate). Both sides are canonicalized (SPEC LAW 23 /
   DESIGN §2.1) so a grant spelled one way (a symlink, /var vs /private/var,
   a trailing slash) authorizes a cell observed another way — this is the
   ONE place every authority check funnels through, so no call site has to
   canonicalize its own path before checking. *)
let path_grants ~(scope : string) (target : string) : bool =
  Paths.under ~root:(Runtime.canonical_path scope) (Runtime.canonical_path target)

(* Human-readable mode name, matching --grant's spelling (main.ml) and
   cap-restrict's keyword argument — so a "cannot widen" error names the
   mode the same way the user would write it. *)
let mode_name = function
  | Read -> "ro" | Write -> "wo" | ReadWrite -> "rw"

(* Check if a capability grants a specific permission *)
let rec check_fs_read (cap : capability) (target_path : string) : bool =
  match cap with
  | CapFilesystem { path; mode = Read } ->
      path_grants ~scope:path target_path
  | CapFilesystem { path; mode = ReadWrite } ->
      path_grants ~scope:path target_path
  | CapCompose caps -> List.exists (fun c -> check_fs_read c target_path) caps
  | CapRestrict { cap; scope; mode } ->
      (* Restriction: scope must cover the target, the underlying cap must
         itself grant read there, and an explicit mode (if any) must not
         exclude read — the mode-intersection half of CapRestrict: a
         restriction narrows, so requesting a mode wider than the underlying
         capability's own mode must fail, never widen it. *)
      path_grants ~scope target_path
      && check_fs_read cap target_path
      && (match mode with Some Write -> false | Some Read | Some ReadWrite | None -> true)
  | _ -> false

let rec check_fs_write (cap : capability) (target_path : string) : bool =
  match cap with
  | CapFilesystem { path; mode = Write } ->
      path_grants ~scope:path target_path
  | CapFilesystem { path; mode = ReadWrite } ->
      path_grants ~scope:path target_path
  | CapCompose caps -> List.exists (fun c -> check_fs_write c target_path) caps
  | CapRestrict { cap; scope; mode } ->
      path_grants ~scope target_path
      && check_fs_write cap target_path
      && (match mode with Some Read -> false | Some Write | Some ReadWrite | None -> true)
  | _ -> false

(* Does [cap] grant access to [host]:[port]? "*" as a granted host
   wildcards any host; a grant
   with no port (None) is unrestricted by port, a grant with Some p pins it
   exactly — the query's port must be known (Some) and equal. Used both ways:
   with [cap] = the ambient (as a CapCompose) and (host, port) = an http
   effect's target (Process/Evaluator), and with [cap] = the ambient and
   (host, port) = a REQUESTED CapNetwork's own fields (Capabilities.cap_subseteq,
   mirroring how CapFilesystem's cap_subseteq arm tests a single (path, mode)
   point against the held set). *)
let rec check_network (cap : capability) ~(host : string) ~(port : int option) : bool =
  match cap with
  | CapNetwork { host = h; port = p } ->
      (h = "*" || h = host)
      && (match p with
          | None -> true
          | Some p -> (match port with Some q -> q = p | None -> false))
  | CapCompose caps -> List.exists (fun c -> check_network c ~host ~port) caps
  | CapRestrict { cap; _ } -> check_network cap ~host ~port
  | _ -> false

(* Does [cap] grant reading the secret at [target_path]?
   Path-component scoping, same as fs (Paths.under via path_grants) — but a
   SEPARATE capability kind (CapSecret), never fs_mode, because the read
   surface must return a distinct VALUE KIND (VSealed) for the node-boundary
   ban to pattern-match: folding this into fs_mode would make a sealed read
   indistinguishable in kind from a plain one, so the ban couldn't tell them
   apart structurally. *)
let rec check_secret (cap : capability) (target_path : string) : bool =
  match cap with
  | CapSecret { path } -> path_grants ~scope:path target_path
  | CapCompose caps -> List.exists (fun c -> check_secret c target_path) caps
  | CapRestrict { cap; _ } -> check_secret cap target_path
  | _ -> false

let rec check_process (cap : capability) : bool =
  match cap with
  | CapProcess -> true
  | CapCompose caps -> List.exists check_process caps
  | CapRestrict { cap; _ } -> check_process cap
  | _ -> false

(* Intersection of two fs_modes: the narrower access both agree on, or None
   if they share no common mode (a read-only view and a write-only view of
   the same path grant nothing in common). *)
let mode_intersect (a : fs_mode) (b : fs_mode) : fs_mode option =
  match a, b with
  | ReadWrite, ReadWrite -> Some ReadWrite
  | ReadWrite, x | x, ReadWrite -> Some x
  | Read, Read -> Some Read
  | Write, Write -> Some Write
  | Read, Write | Write, Read -> None

(* Get the effective filesystem paths a capability grants.

   CapRestrict's scope INTERSECTS the underlying grants — it does not
   Filename.concat onto them (the latent bug this fixes: concatenating scope
   and an underlying path synthesizes a bogus nested path unrelated to
   either input, e.g. scope="/tmp", path="/etc/passwd" produced
   "/tmp/etc/passwd", a path that grants nothing about either directory).

   For each underlying (path, mode), scope and path name two directories
   that either nest one inside the other or don't — three cases:
     - path is under scope  ⇒ path is the more specific (deeper) location;
       the restriction doesn't narrow the LOCATION any further, only
       (possibly) the mode.
     - scope is under path  ⇒ scope is the deeper location: the restriction
       narrows access down to scope itself.
     - neither contains the other ⇒ disjoint; this underlying entry
       contributes NO grant under the restriction (excluded, not error).
   Both sides are canonicalized first (LAW 23 / DESIGN §2.1) so containment
   is judged on the same footing as every other authority decision here — a
   scope spelled differently from the underlying grant (a symlink, a
   trailing slash) still nests correctly. The restriction's own mode (if
   given) is then intersected with the underlying entry's mode; a
   restriction to a mode that shares nothing with the underlying grant
   (e.g. :wo layered on a read-only underlying path) also drops the entry. *)
let rec list_fs_paths (cap : capability) : (string * fs_mode) list =
  match cap with
  | CapFilesystem { path; mode } -> [(path, mode)]
  | CapCompose caps -> List.concat_map list_fs_paths caps
  | CapRestrict { cap; scope; mode } ->
      let cscope = Runtime.canonical_path scope in
      List.filter_map (fun (p, m) ->
        let cp = Runtime.canonical_path p in
        let effective_path =
          if Paths.under ~root:cscope cp then Some cp        (* p is deeper *)
          else if Paths.under ~root:cp cscope then Some cscope (* scope is deeper *)
          else None                                            (* disjoint *)
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
        (list_fs_paths cap)
  | _ -> []

(* cap-restrict cap scope [mode]: narrows [cap] to [scope], optionally to a
   specific fs_mode. Requesting a mode WIDER than what [cap] already grants
   AT [scope] is rejected outright (Capability_error) — restriction only
   ever narrows, never silently widens (SPEC LAW 22 addendum). The check is
   evaluated at [scope] itself (as both a read- and a write-probe against the
   underlying capability), which is exactly what check_fs_read/check_fs_write
   already do for a path nested inside a granted directory. *)
let cap_restrict ?(mode : fs_mode option) (cap : value) (scope : string) : value =
  match cap with
  | VCapability c ->
      (match mode with
       | Some m ->
           let read_ok = check_fs_read c scope in
           let write_ok = check_fs_write c scope in
           let ok = match m with
             | Read -> read_ok
             | Write -> write_ok
             | ReadWrite -> read_ok && write_ok
           in
           if not ok then
             raise (Capability_error
               (Printf.sprintf
                  "cap-restrict: cannot widen mode to :%s for %s (not held by the underlying capability)"
                  (mode_name m) scope))
       | None -> ());
      VCapability (CapRestrict { cap = c; scope; mode })
  | _ -> failwith "restrict expects a capability value"

(* with-caps' shared error text (Capabilities, not Evaluator/Vm, so both
   backends raise the byte-identical message). *)
let err_with_caps_widen =
  "with-caps: requested capability is not a subset of the current capabilities"

(* cap_subseteq requested ambient: does [requested]'s authority live entirely
   within the union of [ambient]? This is with-caps' narrowing gate (SPEC LAW
   22 addendum), checked against the CURRENT ambient — implemented per-kind
   via the existing check functions, wrapping [ambient] as one CapCompose so
   check_fs_read/write's own CapCompose arm performs the union-search.
   CapRestrict's authority is exactly whatever list_fs_paths (above) says it
   effectively grants — this is where the list_fs_paths fix becomes
   load-bearing: an incorrect containment answer there would let a narrowed
   value either smuggle out authority it doesn't actually have, or wrongly
   refuse a legitimate narrowing. *)
(* cap_non_fs_subseteq cap held: check that the non-filesystem authority
   of [cap] (network, secret) is a subset of what [held] grants.
   Filesystem and process are handled separately by cap_subseteq's
   CapRestrict arm (list_fs_paths + check_process). *)
let rec cap_non_fs_subseteq (cap : capability) (held : capability) : bool =
  match cap with
  | CapNetwork { host; port } -> check_network held ~host ~port
  | CapSecret { path } -> check_secret held path
  | CapCompose caps -> List.for_all (fun c -> cap_non_fs_subseteq c held) caps
  | CapRestrict { cap = inner; _ } -> cap_non_fs_subseteq inner held
  | _ -> true
let rec cap_subseteq (requested : capability) (ambient : capability list) : bool =

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

(* ---- --grant spec parsing ----

   "fs:/path:rw" | "net:host[:port]" | "secret:/path" | "process" -> a
   capability. Moved here from what used to be a local closure in main.ml,
   so the signed-token verifier (Token.verify) can parse a token's embedded caps
   with the EXACT SAME function `pp --grant` uses at the CLI — "zero new
   authority code": a wire-verified capability list is built by the
   identical parser as a locally-minted one, so cap_subseteq/
   cell_authorized_for cannot tell the difference between the two.
   main.ml's --grant flag is now a thin caller of this. *)
let parse_grant (spec : string) : capability =
  match String.split_on_char ':' spec with
  | ["fs"; path; mode] ->
      let m = match mode with
        | "ro" -> Read | "rw" -> ReadWrite | "wo" -> Write
        | _ -> failwith ("invalid fs mode in --grant: " ^ mode)
      in
      (* SPEC LAW 23 / DESIGN §2.1: canonicalize at the mint, so every
         downstream comparison (authority checks, `tree:` cells built from
         granted paths) already sees the same spelling a cell would. *)
      CapFilesystem { path = Runtime.canonical_path path; mode = m }
  | ["net"; host] -> CapNetwork { host; port = None }
  | ["net"; host; port] ->
      (match int_of_string_opt port with
       | Some p -> CapNetwork { host; port = Some p }
       | None -> failwith ("invalid port in --grant net spec: " ^ spec))
  | ["secret"; path] ->
      (* Canonicalize at mint, exactly like fs grants (see above). *)
      CapSecret { path = Runtime.canonical_path path }
  | ["process"] -> CapProcess
  | _ -> failwith ("invalid --grant spec: " ^ spec)
