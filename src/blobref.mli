(* pp blob refs — "blob:<sha256>" reference detection inside a pp VALUE.
   Shared by remote.ml (dispatcher-side pull) and store.ml (GC live-set
   mark-by-replay). *)

(* Scan a value's structure for "blob:<sha256>" string references. *)
val blob_refs_in : Core_model.value -> string list
