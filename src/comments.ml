(* pp comments — the side channel `pp fmt` uses to carry comments
   losslessly across transpilation, without touching either reader or
   either printer's AST-facing behavior at all (comments are not part of
   `Types.expr`; LAW-20 hashes ignore them by construction — that's exactly
   why they need a channel of their own).

   Each surface has its own single-character comment marker to end-of-line
   (sexpr: `;`, brace: `#` — SPEC Appendix B), so scanning is a small
   character-level walk that mirrors just enough of that surface's lexer
   (string-body escapes; for sexpr, also the `<...>` island-literal span) to
   avoid mistaking a `;`/`#` inside a string (or island literal) for a
   comment marker. It does NOT re-implement full tokenization: numbers,
   symbols, brackets etc. never contain the marker character (both lexers
   exclude it from their symbol-character sets), so nothing else needs
   special-casing.

   [line] is the 1-based physical source line the marker character occurs
   on (the same counting both readers' lexers use for `ELocated`), so a
   printer that already lands every located construct on its recorded line
   (printer_braces.ml, printer_sexpr.ml) can splice a comment back in by
   that same line number — see [splice] below. *)

type t = { line : int; text : string }
(* [text] is the comment's CONTENT with the source delimiter fully
   stripped: the marker character, any immediately repeated markers
   (`;;`/`###` banner styles — the whole run is delimiter, not content),
   and one following space if present. Both surfaces' spellings of the
   same comment therefore scan to the same [text], and a splice emits
   exactly one target delimiter (never a stacked `# ;`). *)

let is_alnum c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

(* Shared walk: [marker] is the comment character; [island] additionally
   skips sexpr's `<...>` island-literal span (never present in brace
   source — reader_braces has no such literal). *)
let scan ~(marker : char) ~(island : bool) (input : string) : t list =
  let len = String.length input in
  let pos = ref 0 in
  let line = ref 1 in
  let out = ref [] in
  let peek () = if !pos < len then Some input.[!pos] else None in
  let adv () = incr pos in
  (* mirrors read_string_body in both readers: backslash escapes any one
     following character; a literal newline is allowed and counted. *)
  let rec skip_string () =
    match peek () with
    | None -> ()
    | Some '"' -> adv ()
    | Some '\\' ->
        adv ();
        (match peek () with Some _ -> adv () | None -> ());
        skip_string ()
    | Some '\n' -> incr line; adv (); skip_string ()
    | Some _ -> adv (); skip_string ()
  in
  (* mirrors reader.ml's read_island_rest: raw chars up to '>'. *)
  let rec skip_island () =
    match peek () with
    | None -> ()
    | Some '>' -> adv ()
    | Some '\n' -> incr line; adv (); skip_island ()
    | Some _ -> adv (); skip_island ()
  in
  let read_comment () =
    (* the delimiter is the whole marker run plus one following space *)
    while peek () = Some marker do adv () done;
    (match peek () with Some ' ' -> adv () | _ -> ());
    let start = !pos in
    while (match peek () with Some c -> c <> '\n' | None -> false) do adv () done;
    let text = String.sub input start (!pos - start) in
    out := { line = !line; text } :: !out
  in
  let rec run () =
    match peek () with
    | None -> ()
    | Some '\n' -> incr line; adv (); run ()
    | Some '"' -> adv (); skip_string (); run ()
    | Some c when c = marker -> adv (); read_comment (); run ()
    | Some '<' when island ->
        adv ();
        (match peek () with
         | Some '=' -> adv (); run ()
         | Some c when is_alnum c -> skip_island (); run ()
         | _ -> run ())
    | Some _ -> adv (); run ()
  in
  run ();
  List.rev !out

(* sexpr comments: `;` to end of line (reader.ml); `<...>` island literals
   are skipped so an embedded `;` there is never mistaken for one. *)
let scan_sexpr (input : string) : t list = scan ~marker:';' ~island:true input

(* brace comments: `#` to end of line (reader_braces.ml); no island-literal
   spelling exists on this surface. *)
let scan_brace (input : string) : t list = scan ~marker:'#' ~island:false input

(* Splice [comments] (scanned from the ORIGINAL source, in the ORIGINAL
   marker) into [text] — the OTHER surface's location-preserving printer
   output — re-spelled with [delim]. Both printers guarantee that every
   `ELocated` construct lands on exactly its original line number, so a
   comment recorded at original line L belongs at output line L too:
   trailing after whatever code already occupies that line, or standalone
   if the line is blank (padding filler the printer inserted while
   catching up to a later located construct), extending past the printed
   text's last line for a trailing comment beyond all code.

   Two comments landing on the same output line (possible when several
   un-located statements — which carry no location of their own, so their
   original per-statement line isn't preserved by either printer — get
   printed packed onto one line) are appended in order rather than
   clobbering each other: comment COUNT and TEXT are always preserved,
   even on the rare line where exact original position isn't recoverable
   (nothing in either grammar lets a same-line `;`/`#` marker break
   parsing — the rest of the line is a comment regardless of what
   precedes it). *)
let splice (comments : t list) ~(delim : char) (text : string) : string =
  if comments = [] then text
  else begin
    let dstr = String.make 1 delim in
    let raw_lines = String.split_on_char '\n' text in
    let lines =
      match List.rev raw_lines with
      | "" :: rest -> List.rev rest
      | _ -> raw_lines
    in
    let base_len = List.length lines in
    let max_comment_line = List.fold_left (fun m c -> max m c.line) 0 comments in
    let total = max base_len max_comment_line in
    let arr = Array.make total "" in
    List.iteri (fun i l -> arr.(i) <- l) lines;
    List.iter (fun { line; text = ctext } ->
      let trimmed = String.trim ctext in
      let piece = if trimmed = "" then dstr else dstr ^ " " ^ trimmed in
      let idx = line - 1 in
      if arr.(idx) = "" then arr.(idx) <- piece
      else arr.(idx) <- arr.(idx) ^ "  " ^ piece)
      comments;
    String.concat "\n" (Array.to_list arr) ^ "\n"
  end
