val equal : string -> string -> bool
(** Constant-time string comparison: returns [true] iff [a] and [b] are
    equal in both length and content, without short-circuiting on the
    first differing byte. Length is compared first (non-constant), but
    the content comparison always processes every byte.
    Intended for MAC and other secret-bearing comparisons. *)
