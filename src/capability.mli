(* capability — the authority kernel's public face.

   [t] is abstract: no module outside this one can construct a capability
   value except through [mint] (the CLI --grant path), [compose] (union),
   [restrict] (narrowing) and [none].  The single construction site enforces
   SPEC LAW 22: user code narrows and unions, never constructs from scratch.

   Every fs-level authority check takes [Paths.canonical], never a raw
   string, so a symlink-spelling bypass is inexpressible once both sides
   have been canonicalised. *)

type fs_mode = Read | Write | ReadWrite

type t
val none : t
val compose : t list -> t
val restrict : ?mode:fs_mode -> t -> Paths.canonical -> t

(* ---- construction (mint: one CLI site, plus parse_grant for tokens) ---- *)
val mint : realpath:(string -> string) -> string -> t

(* ---- authority checks (per effect) ---- *)
val check_fs_read : t -> Paths.canonical -> bool
val check_fs_write : t -> Paths.canonical -> bool
val check_network : t -> host:string -> port:int option -> bool
val check_secret : t -> Paths.canonical -> bool
val check_process : t -> bool
val list_fs_paths : t -> (Paths.canonical * fs_mode) list

(* ---- the subseteq monotonicity gate (LAW 22b) ---- *)
val subseteq : t -> t list -> bool

(* ---- hashing and display ---- *)
val hash : t -> string
val to_string : t -> string

(* ---- error text shared by both backends ---- *)
val err_with_caps_widen : string

(* ---- mode helpers ---- *)
val mode_name : fs_mode -> string
val mode_intersect : fs_mode -> fs_mode -> fs_mode option

(* ---- ratchet / property-testing (exhaustive over variant) ---- *)
type cap_tag =
  | Ct_none | Ct_filesystem | Ct_network | Ct_secret | Ct_process
  | Ct_compose | Ct_restrict

val all_cap_tags : cap_tag list
val atomic_cap_tags : cap_tag list
val cap_kind : t -> cap_tag
val gen_cap : Random.State.t -> int -> t
val cap_probe_vector : t -> bool list
val cap_subseteq_probes : t -> t -> bool