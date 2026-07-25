val materialize : root:string -> Pp_kernel.Artifact_tree.t -> unit
val snapshot : root:string -> paths:string list -> Pp_kernel.Artifact_tree.t
val verify : Pp_kernel.Artifact_tree.t -> unit
