(* pp paths — the ONE component-boundary path-containment predicate.

   [canonical] (private in the .mli) forces every authority check to go
   through [canonicalize], which takes an injected resolver. The plain
   [under] stays on [canonical] — you cannot pass a raw string to a
   containment check. *)

type canonical = string

let canonicalize ~realpath p = realpath p

let under ~(root : canonical) (path : canonical) : bool =
  let strip s =
    let n = String.length s in
    if n > 1 && s.[n - 1] = '/' then String.sub s 0 (n - 1) else s
  in
  let root = strip root in
  let path = strip path in
  root = path
  || (let prefix = if root = "/" then "/" else root ^ "/" in
      String.starts_with ~prefix path)