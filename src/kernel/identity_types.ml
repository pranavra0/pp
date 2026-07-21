(* Typed names at the persistent-node boundary.

   The store is text-addressed on disk, but those spellings are not
   interchangeable in the evaluator.  Keep the conversions here so a node
   key cannot accidentally be used as an object, observation, or cell name. *)

module Node_key = struct
  type t = string

  let of_string (value : string) : t = value
  let to_string (value : t) : string = value
end

module Cache_key = struct
  type t = string

  let of_digest (value : string) : t = value
  let of_node_key (value : Node_key.t) : t = Node_key.to_string value
  let of_string (value : string) : t = value
  let to_string (value : t) : string = value
end

module Object_hash = struct
  type t = string

  let of_digest (value : string) : t = value
  let to_string (value : t) : string = value
end

module Observed_hash = struct
  type t = string

  let of_digest (value : string) : t = value
  let to_string (value : t) : string = value
end

module Cell_id = struct
  type t = string

  let of_string (value : string) : t = value
  let to_string (value : t) : string = value
end
