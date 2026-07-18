(* pp comments — the side channel `pp fmt` uses to carry comments
   losslessly across transpilation. Each surface has its own single-character
   comment marker (sexpr: `;`, brace: `#`).

   [t] records a comment's source line number and its content text with the
   source delimiter fully stripped. *)

type t = { line : int; text : string }

(* Scan sexpr source for `;`-to-end-of-line comments, skipping `<...>`
   island-literal spans so an embedded `;` there is never mistaken for one. *)
val scan_sexpr : string -> t list

(* Scan brace source for `#`-to-end-of-line comments (no island-literal
   spelling exists on this surface). *)
val scan_brace : string -> t list

(* Splice [comments] (scanned from one surface) into [text] — the OTHER
   surface's location-preserving printer output — re-spelled with [delim].
   Both printers guarantee that every located construct lands on its
   original line number, so a comment recorded at line L belongs at output
   line L too. *)
val splice : t list -> delim:char -> string -> string
