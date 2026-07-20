open Core_model

(* Pattern matching: try to match a value against a pattern.
   Returns Some [(name, value); ...] on match, None on failure. *)
let rec match_pattern (v : value) (p : pattern) : (string * value) list option =
  match p with
  | PWildcard -> Some []
  | PVariable name -> Some [(name, v)]
  | PLiteral lit -> if v = lit then Some [] else None
  | PList (pats, rest) ->
      let rec match_list v pats rest =
        match pats, v with
        | [], _ ->
            (match rest with
             | Some r -> match_pattern v r
             | None -> if v = VNil then Some [] else None)
        | p :: ps, VPair (h, t) ->
            (match match_pattern h p with
             | Some b1 ->
                 (match match_list t ps rest with
                  | Some b2 -> Some (b1 @ b2)
                  | None -> None)
             | None -> None)
        | _ :: _, _ -> None
      in
      match_list v pats rest
  | PTagged (tag, pats) ->
      match v with
      | VPair (VKeyword kw, rest) when kw = tag ->
          let rec match_tagged rest pats =
            match pats, rest with
            | [], VNil -> Some []
            | [], _ -> Some []
            | p :: ps, VPair (h, t) ->
                (match match_pattern h p with
                 | Some b1 ->
                     (match match_tagged t ps with
                      | Some b2 -> Some (b1 @ b2)
                      | None -> None)
                 | None -> None)
            | _ :: _, _ -> None
          in
          match_tagged rest pats
      | _ -> None
