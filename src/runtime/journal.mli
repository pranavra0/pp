type entry =
  | Exec of string list
  | DomainIntent of { hash : string; fields : (string * string) list }
  | DomainDone of { hash : string }
  | ProcStartIntent of { name : string; spec_hash : string }
  | ProcStartDone of { name : string; spec_hash : string; pid : int }
  | ProcStopIntent of { name : string }
  | ProcStopDone of { name : string }
  | FencedIntent of { key : string; epoch : string; kind : string; spec_hash : string }
  | FencedDone of { key : string; result_hash : string }
  | IslandFetch of { uri : string; pin : string }
  | Epoch of { hash : string }

type fenced_entry = {
  fe_key : string;
  fe_epoch : string;
  fe_kind : string;
  fe_spec_hash : string;
}

val append : entry -> unit
val pending_fenced_actions : unit -> fenced_entry list
val has_fenced_done : string -> bool
