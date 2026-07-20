type t = private {
  canonical_realpath : string -> string;
  unix_time : unit -> float;
  home_dir : unit -> string;
  read_secret : string -> string;
  write_secret : string -> string -> unit;
}

val make :
  canonical_realpath:(string -> string) ->
  unix_time:(unit -> float) ->
  home_dir:(unit -> string) ->
  read_secret:(string -> string) ->
  write_secret:(string -> string -> unit) ->
  t
