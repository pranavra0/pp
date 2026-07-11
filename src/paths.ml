(* pp paths — the ONE component-boundary path-containment predicate.

   [under ~root path] iff [path] equals [root] or lives inside the directory
   named by [root]: "/out" covers "/out" and "/out/a" but NOT "/output".
   Trailing slashes on either side are ignored (except a bare "/", which
   covers every absolute path).

   This predicate is a security check (capability scopes, loader authority,
   reconciler domain bounds). It exists exactly once so the component-boundary
   argument is made — and audited — in one place. *)

let under ~(root : string) (path : string) : bool =
  let strip s =
    let n = String.length s in
    if n > 1 && s.[n - 1] = '/' then String.sub s 0 (n - 1) else s
  in
  let root = strip root in
  let path = strip path in
  root = path
  || (let prefix = if root = "/" then "/" else root ^ "/" in
      String.starts_with ~prefix path)
