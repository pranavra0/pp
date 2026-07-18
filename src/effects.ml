(* pp effects — OCaml 5 effect type declarations for the dynamic-extent
   mechanisms (capabilities, config, handlers, trace, sandbox). Pure — lists
   no unix — so it can live in pp.kernel.

   The handlers for these effects live in dynamic_scope.ml.
   The split means anything that just needs the effect _types_ links only the kernel, while the
   run-time stack wiring stays in the main library. *)


type _ Effect.t +=
  | Get_invocation : Invocation.t Effect.t
  | Get_capabilities : Capability.t list Effect.t
  | Get_config : Types.value list Effect.t
  | Get_handlers : (string * string) list Effect.t
  | Lookup_handler : string -> ((Types.value list -> Types.value) * string) option Effect.t
  | Record_read : string * string -> unit Effect.t
  | In_node : bool Effect.t
  | Current_sandbox : string option ref option Effect.t
  | Get_domain : string option Effect.t
  | Get_observe_all : bool Effect.t
