let equal a b =
  let len_a = String.length a in
  let len_b = String.length b in
  if len_a <> len_b then false
  else
    let rec loop i acc =
      if i = len_a then acc = 0
      else
        let acc' = acc lor (Char.code (String.get a i) lxor Char.code (String.get b i)) in
        loop (i + 1) acc'
    in
    loop 0 0
