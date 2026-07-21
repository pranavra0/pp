(* Abstract text spellings for the four identities that meet at a node. *)

module Node_key : sig
  type t

  val of_string : string -> t
  val to_string : t -> string
end

module Cache_key : sig
  type t

  val of_digest : string -> t
  val of_node_key : Node_key.t -> t
  val of_string : string -> t
  val to_string : t -> string
end

module Object_hash : sig
  type t

  val of_digest : string -> t
  val to_string : t -> string
end

module Observed_hash : sig
  type t

  val of_digest : string -> t
  val to_string : t -> string
end

module Cell_id : sig
  type t

  val of_string : string -> t
  val to_string : t -> string
end
