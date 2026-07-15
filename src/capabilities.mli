(* capabilities — the authority kernel's public face.

   The capability algebra: the typed constructors (mirroring the pp-level
   mints), the attenuation operations ([cap_restrict], [cap_compose]), the
   authority checks each effect gates on, and the ⊆ monotonicity test
   ([cap_subseteq], LAW 22b) that makes "narrow only, never widen" enforceable.
   The .mli fixes the boundary so every authority decision routes through these
   functions; the mode-arithmetic helpers ([mode_name], [mode_intersect]) are
   internal to that arithmetic and stay module-private. *)

(* ---- typed constructors (OCaml-side mints) ---------------------------- *)
val cap_none : Types.value
val cap_filesystem : path:string -> mode:Types.fs_mode -> Types.value
val cap_network : host:string -> port:int option -> Types.value
val cap_secret : path:string -> Types.value
val cap_process : Types.value
val cap_compose : Types.value list -> Types.value

(* ---- attenuation ------------------------------------------------------ *)
val cap_restrict :
  ?mode:Types.fs_mode -> Types.value -> string -> Types.value
val err_with_caps_widen : string

(* ---- authority checks (per effect) ------------------------------------ *)
val path_grants : scope:string -> string -> bool
val check_fs_read : Types.capability -> string -> bool
val check_fs_write : Types.capability -> string -> bool
val check_network :
  Types.capability -> host:string -> port:int option -> bool
val check_secret : Types.capability -> string -> bool
val check_process : Types.capability -> bool
val list_fs_paths : Types.capability -> (string * Types.fs_mode) list

(* ---- the ⊆ monotonicity gate (LAW 22b) -------------------------------- *)
val cap_subseteq : Types.capability -> Types.capability list -> bool

(* ---- grant-spec parsing (--grant) ------------------------------------- *)
val parse_grant : string -> Types.capability
