type request = {
  tool : string;
  arguments : string list;
  inputs : (string * string) list;
  environment : (string * string) list;
  platform : (string * string) list;
  outputs : string list;
}

type result = {
  exit_status : int;
  stdout : string;
  stderr : string;
  outputs : (string * string) list;
  evidence : (string * string) list;
  resources : (string * string) list;
}

type t = request -> result

let run executor request = executor request
