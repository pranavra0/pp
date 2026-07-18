(* Deep recursive force over a pp VALUE — the plain structural walk.

   Extracted because this exact recursive walk was written three times
   (primitives, domain_prims, fenced) with identical bodies but the same
   evaluator force operation supplied by its caller. The scheduler-aware batch
   dispatch lives in Primitives.force_deep; this is the plain walk it (and
   others) delegate to. *)

open Types

let rec force_deep_plain ~force (v : value) : value =
  match force v with
  | VPair (a, d) -> VPair (force_deep_plain ~force a, force_deep_plain ~force d)
  | VVector vs -> VVector (Array.map (force_deep_plain ~force) vs)
  | VMap kvs -> VMap (List.map (fun (k, v) -> (force_deep_plain ~force k, force_deep_plain ~force v)) kvs)
  | VSet vs -> VSet (List.map (force_deep_plain ~force) vs)
  | other -> other

let find_kv ~force (kvs : (value * value) list) (key : string) : value option =
  List.find_map (fun (k, v) ->
    match string_like k with
    | Some k' when k' = key -> Some (force v)
    | _ -> None)
    kvs
