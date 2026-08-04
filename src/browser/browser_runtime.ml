open Pp_kernel
open Pp_runtime
open Pp_frontend
open Core_model

let () = Printexc.record_backtrace true

 type result = {
  status : string;
  stdout : string list;
  value : string option;
  diagnostics : string list;
  events : string list;
}

let json_escape s =
  let b = Buffer.create (String.length s + 16) in
  String.iter (function
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c -> Buffer.add_char b c) s;
  Buffer.contents b

let json_string s = "\"" ^ json_escape s ^ "\""
let json_list values = "[" ^ String.concat "," (List.map json_string values) ^ "]"

let invocation () =
  match Invocation.create
      ~source_roots:[] ~initial_capabilities:[] ~command_argv:[]
      ~program_argv:[] ~program_files:[] ~initial_grant_specs:[]
      ~program_reconcile_root:None ~program_supervise:false
      ~program_member_name:None ~program_desired_object:None
      ~gc_keep_epochs:1 ~fenced_policy:Invocation.Abort with
  | Ok value -> value
  | Error message -> failwith message

let event_text value =
  match value with
  | VMap bindings ->
      (match List.assoc_opt (VKeyword "kind") bindings with
       | Some (VKeyword kind) ->
           let detail =
             match List.assoc_opt (VKeyword "reason") bindings with
             | Some (VKeyword reason) -> " (" ^ reason ^ ")"
             | Some (VString reason) -> " (" ^ reason ^ ")"
             | _ -> ""
           in
           let node =
             match List.assoc_opt (VKeyword "node") bindings with
             | Some (VString node) -> " [" ^ node ^ "]"
             | _ -> ""
           in
           String.lowercase_ascii kind ^ node ^ detail
       | _ -> Presentation.string_of_value value)
  | _ -> Presentation.string_of_value value

let contains ~needle text =
  let limit = String.length text - String.length needle in
  let rec scan index =
    if index > limit then false
    else if String.sub text index (String.length needle) = needle then true
    else scan (index + 1)
  in
  String.length needle = 0 || (limit >= 0 && scan 0)

let unavailable_exception = function
  | Failure message ->
      contains ~needle:"not implemented" (String.lowercase_ascii message)
  | _ -> false

let run ~source =
  let stdout = ref [] in
  let stage = ref "created" in
  let scheduler = Scheduler.create ~handler:Scheduler.serial in
  let session = Session.create ~scheduler Evaluator.operations in
  let invocation = invocation () in
  let execute () =
    let _values, value =
      Dynamic_scope.with_top_level session invocation ~f:(fun () ->
        stage := "evaluator-init";
        Evaluator.init session ~retain_thunks:false;
        let env = ref (Primitives.initial_env ()) in
        let print = VBuiltin ("print", fun args _ ->
          let line =
            args
            |> List.map Force_deep.force_deep
            |> List.map Presentation.string_of_value
            |> String.concat ""
          in
          stdout := !stdout @ [line];
          VNil)
        in
        env := Environment.extend !env "print" print;
        stage := "read";
        let exprs =
          Reader_braces.read_dispatch ~source:"browser.pp" ~path:"browser.pp" source
        in
        stage := "expand";
        let core = Session.core_operations session in
        let expanded =
          Macro.expand_toplevel_list
            { Macro.eval = core.eval;
              force_deep = Force_deep.force_deep;
              initial_env = Primitives.initial_env }
            exprs
        in
        stage := "evaluate";
        let values = Evaluator.eval_expressions_list expanded env in
        let value =
          match List.rev values with
          | [] -> None
          | value :: _ ->
              Some (Presentation.string_of_value (Force_deep.force_deep value))
        in
        values, value) ()
    in
    { status = "ok";
      stdout = !stdout;
      value;
      diagnostics = [];
      events = List.map event_text (Session.events session) }
  in
  Trace_repository.set_memory_mode true;
  Object_repository.set_memory_mode true;
  Fun.protect
    ~finally:(fun () ->
      Trace_repository.set_memory_mode false;
      Object_repository.set_memory_mode false)
    (fun () ->
      try execute () with
      | exn ->
          { status = if unavailable_exception exn then "unavailable" else "error";
            stdout = !stdout; value = None;
            diagnostics = [!stage ^ ": " ^ Printexc.to_string exn]; events = [] })

let to_json result =
  let field name value = json_string name ^ ":" ^ value in
  "{" ^ String.concat "," [
    field "status" (json_string result.status);
    field "stdout" (json_list result.stdout);
    field "value" (match result.value with Some value -> json_string value | None -> "null");
    field "diagnostics" (json_list result.diagnostics);
    field "events" (json_list result.events)
  ] ^ "}"
