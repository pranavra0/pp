(* pp paths — the ONE containment predicate, now with canonical path type.

   [canonical = private string]: zero-cost reads and hashing, but only
   [canonicalize] (which takes an injected resolver) constructs a canonical.
   Every authority check funnels through [under], which takes [canonical], so a
   raw string cannot accidentally bypass an authority decision. *)

type canonical = private string

val canonicalize : realpath:(string -> string) -> string -> canonical
val under : root:canonical -> canonical -> bool