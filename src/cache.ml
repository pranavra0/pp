(* pp cache — content-addressed cache (in-memory for v1, persistent for v1.5) *)

(* For v1, the cache is the evaluator's in-memory thunk_cache.
   This module provides the interface for future persistent caching. *)

(* Cache directory *)
let cache_dir () =
  let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
  Filename.concat home ".pp"

(* Initialize the cache directory *)
let init () =
  let dir = cache_dir () in
  (try ignore (Sys.is_directory dir)  (* check if exists *)
   with Sys_error _ ->
     let _ = Sys.command ("mkdir -p " ^ Filename.quote dir) in ());
  dir

(* Save a value to the persistent cache *)
let save (hash : string) (v : Types.value) : unit =
  (* v1: no-op. v1.5: serialize to disk *)
  ignore (hash, v)

(* Load a value from the persistent cache *)
let load (hash : string) : Types.value option =
  (* v1: no persistent cache *)
  ignore hash;
  None
