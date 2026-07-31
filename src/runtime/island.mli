val fetch_enabled : bool ref
val update_mode : bool ref
val repin : string -> string
val resolve : uri:string -> pin:string option -> string
val entry_file : string -> string
val update_file : string -> int * int
val print_pins : string -> unit
