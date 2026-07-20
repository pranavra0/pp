open Pp_kernel
open Core_model

let replay_reads = Node.replay_node_reads

let force ~key ~run thunk =
  Node.force ~key ~authorized:(Observation.authorized_id thunk.node_caps) ~run thunk
