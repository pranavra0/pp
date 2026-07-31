open Core_model

(* Pattern matching: try to match a value against a pattern.
   Returns Some [(name, value); ...] on match, None on failure. *)
let rec match_pattern (v : value) (p : pattern) : (string * value) list option =
  match p with
  | PWildcard -> Some []
  | PVariable name -> Some [(name, v)]
  | PLiteral lit -> if Identity.equal_value v lit then Some [] else None
  | PList (pats, rest) ->
      let rec match_list v pats rest =
        match pats, v with
        | [], _ ->
            (match rest with
             | Some r -> match_pattern v r
             | None -> (match v with VNil -> Some [] | _ -> None))
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
      (match v with
       | VPair (VKeyword kw, rest) when kw = tag ->
           let rec match_tagged rest pats =
             match pats, rest with
             | [], VNil -> Some []
             | [], _ -> None
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
       | _ -> None)
  | PMap (entries, rest_kind) ->
      (match v with
       | VMap values ->
           let rec find_key key acc = function
             | [] -> None
             | ((candidate, _) as entry) :: rest ->
                 if Identity.equal_value key candidate then
                   Some (entry, List.rev_append acc rest)
                 else find_key key (entry :: acc) rest
           in
           let rec match_entries remaining bindings = function
             | [] ->
                 (match rest_kind with
                  | Exact when remaining <> [] -> None
                  | Exact -> Some bindings
                  | Ignore -> Some bindings
                  | Bind name -> Some (bindings @ [name, Value.map remaining]))
             | (key, pattern) :: rest ->
                 (match find_key key [] remaining with
                  | None -> None
                  | Some ((_, value), remaining') ->
                      (match match_pattern value pattern with
                       | None -> None
                       | Some new_bindings ->
                           match_entries remaining'
                             (bindings @ new_bindings) rest))
           in
           match_entries values [] entries
       | _ -> None)
