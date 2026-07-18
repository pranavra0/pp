(* pp blob: refs — "blob:<sha256>" reference detection inside an ordinary
   pp VALUE, shared by src/runtime/remote.ml (remote placement's dispatcher-side
   pull) and Cache_policy (GC's live-set mark-by-replay).

   `blob`/`blob-get` (primitives.ml) are deliberately NOT a traced cell — a
   node's small metadata result carries a "blob:<sha256>" string reference
   instead of inlining bytes — so neither a synced trace's `tr_reads` nor a
   node's own key names these bytes anywhere else. Anything that treats a
   node's RESULT VALUE as the complete picture of what it depends on (remote
   placement's dispatcher-side pull, and GC's live-set mark) must also scan
   the value's own STRUCTURE for this shape, or it silently misses live
   bytes a `(blob (slurp ...))`-pattern node's result names.

   Originally two copies of this exact logic lived in remote.ml alone;
   Cache_policy needs the identical scan, so this is
   factored out to the one place both can reach (core-model-only, no other
   dependency) rather than duplicated a second time. *)

open Core_model

let is_hex64 (s : string) : bool =
  String.length s = 64
  && String.for_all (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) s

let blob_hash_of_string (s : string) : string option =
  let prefix = "blob:" in
  let plen = String.length prefix in
  if String.length s > plen && String.sub s 0 plen = prefix then
    let h = String.sub s plen (String.length s - plen) in
    if is_hex64 h then Some h else None
  else None

let rec blob_refs_in (v : value) : string list =
  match v with
  | VString s -> (match blob_hash_of_string s with Some h -> [h] | None -> [])
  | VPair (a, d) -> blob_refs_in a @ blob_refs_in d
  | VVector vs -> Array.to_list vs |> List.concat_map blob_refs_in
  | VMap kvs -> List.concat_map (fun (k, v) -> blob_refs_in k @ blob_refs_in v) kvs
  | VSet vs -> List.concat_map blob_refs_in vs
  | _ -> []
