(* Deep recursive force over a pp VALUE — the plain structural walk.

   Extracted because this exact recursive walk was written three times
   (primitives, domain_prims, fenced) with identical bodies but the same
   back-end hook each uses (Backend.r.force).  The scheduler-aware batch
   dispatch lives in Primitives.force_deep; this is the plain walk it (and
   others) delegate to. *)

open Types

let rec force_deep_plain (v : value) : value =
  match Backend.r.force v with
  | VPair (a, d) -> VPair (force_deep_plain a, force_deep_plain d)
  | VVector vs -> VVector (Array.map force_deep_plain vs)
  | VMap kvs -> VMap (List.map (fun (k, v) -> (force_deep_plain k, force_deep_plain v)) kvs)
  | VSet vs -> VSet (List.map force_deep_plain vs)
  | other -> other

let find_kv (kvs : (value * value) list) (key : string) : value option =
  List.find_map (fun (k, v) ->
    match string_like k with
    | Some k' when k' = key -> Some (Backend.r.force v)
    | _ -> None)
    kvs
