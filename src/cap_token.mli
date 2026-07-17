(* pp cluster tokens — signed capability grants for cross-machine authority.

   A token is (caps in the --grant CLI grammar, cluster id, issued, expires,
   HMAC-SHA256 MAC) as CANONICAL TEXT — never a pp value. Minted and
   verified entirely at the CLI/transport layer: there is no reader syntax
   for it and no way to construct or inspect one from inside a pp program. *)

(* ---- Cluster identity: ~/.pp/cluster/{secret,id} ---- *)

val cluster_dir : Host_services.t -> string
val secret_path : Host_services.t -> string
val id_path : Host_services.t -> string

(* Writes [content] to a fresh file at [path] with mode 0600. *)
val write_secret_file : Host_services.t -> string -> string -> unit

val load_secret : Host_services.t -> string
val load_cluster_id : Host_services.t -> string

(* ---- Mint and verify ---- *)

(* Mint a fresh cluster token with [ttl_seconds] lifetime. *)
val mint :
  Host_services.t ->
  secret:string -> cluster_id:string -> specs:string list ->
  ttl_seconds:int -> string

(* Verify a token against the local member's own secret and cluster id,
   returning a capability list ready to feed into cell_authorized_for. *)
val token_to_caps : Host_services.t -> string -> (Capability.t list, string) result
