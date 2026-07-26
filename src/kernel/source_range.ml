type position = {
  offset : int;
  line : int;
  column : int;
}

type t = {
  source : string;
  start_pos : position;
  end_pos : position;
}

let position ~offset ~line ~column = { offset; line; column }

let make ~source ~start_pos ~end_pos =
  if start_pos.offset > end_pos.offset then
    invalid_arg "Source_range.make: end precedes start";
  { source; start_pos; end_pos }

let point ~source ~offset ~line ~column =
  let pos = position ~offset ~line ~column in
  make ~source ~start_pos:pos ~end_pos:pos

let start range = range.start_pos
let end_ range = range.end_pos
let source range = range.source

let compare_position a b =
  let by_offset = compare a.offset b.offset in
  if by_offset <> 0 then by_offset
  else
    let by_line = compare a.line b.line in
    if by_line <> 0 then by_line else compare a.column b.column

let equal a b =
  a.source = b.source
  && compare_position a.start_pos b.start_pos = 0
  && compare_position a.end_pos b.end_pos = 0

let is_empty range = compare_position range.start_pos range.end_pos = 0

let format_start range =
  let p = range.start_pos in
  Printf.sprintf "%s:%d:%d" range.source p.line p.column

let format range =
  let p = range.start_pos and q = range.end_pos in
  if p.line = q.line && p.column = q.column then
    format_start range
  else
    Printf.sprintf "%s:%d:%d-%d:%d"
      range.source p.line p.column q.line q.column
