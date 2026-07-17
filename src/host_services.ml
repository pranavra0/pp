type t = {
  canonical_realpath : string -> string;
  unix_time : unit -> float;
  home_dir : unit -> string;
  read_secret : string -> string;
  write_secret : string -> string -> unit;
}

let make ~canonical_realpath ~unix_time ~home_dir ~read_secret ~write_secret =
  { canonical_realpath; unix_time; home_dir; read_secret; write_secret }
