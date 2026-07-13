(* pp REPL — Read-Eval-Print Loop

   ROADMAP §1 REPL quality / M7 S4 (docs/M7-SYNTAX.md "Flip the default"):
   - reads the brace surface, like every `.pp` file (Reader_braces);
   - multi-line input: a form left open (brace/paren/bracket/string nesting,
     comment- and infix-continuation-aware — see Reader_braces
     .needs_more_input) continues onto the next line under a "..> " prompt;
   - history: persisted to ~/.pp/history, browsable with Up/Down;
   - line editing: raw-mode editor (arrows, Home/End, Ctrl-A/E/K/U/W,
     backspace/delete) when stdin is a tty; plain line reads otherwise —
     piped sessions print no prompts or banner, so `echo '1 + 2' | pp`
     emits exactly "3";
   - printing: results are deep-forced for display (a thunk shows its value);
   - `:help`, `:why on|off` (the node-cache explainer), `:quit`. *)

open Types
open Evaluator

(* Global environment for REPL *)
let global_env : env ref = ref empty_env

(* ---- Initialization ---- *)

let init () =
  Evaluator.init ();
  global_env := Primitives.initial_env ()

(* LAW 29 / D12: a runtime error escaping a top-level form reports that
   form's source location — unless its message already carries one (a
   " at …:<line>" suffix), so located errors are never double-located.
   Runtime.with_form_location is the ONE implementation, shared by both
   backends' top-level drivers here AND by `load` (evaluator.ml
   eval_expressions, vm.ml LOAD_FILE) — so an error inside a `load`ed file
   is decorated with THAT file's line, not the loading form's (D12). *)
let with_toplevel_location = Runtime.with_form_location

(* Tree-walker: process a single expression *)
let process_expr (e : expr) : value =
  with_toplevel_location e (fun () ->
    match eval_expressions [e] global_env with
    | VEnvMap _ as v -> v
    | v -> v)

(* Tree-walker: execute a source string. M3 defmacro: the WHOLE file's forms
   are expanded together, in order, before any of them is evaluated — a
   `defmacro` earlier in the string must be visible to a use later in the
   SAME string, even though process_expr below evaluates one form at a
   time. *)
let execute_string ?(source : string = "<?>") (input : string) : value list =
  init ();
  (* M7 S1: `.ppb` sources read with the brace reader (Reader_braces
     dispatches on the extension; every other source is byte-for-byte the
     sexpr reader as before). *)
  let exprs =
    Macro.expand_toplevel_list
      (Reader_braces.read_dispatch ~source ~path:source input) in
  List.map process_expr exprs

(* Tree-walker: execute a source file *)
let execute_file (path : string) : value list =
  let ch = open_in path in
  let source = really_input_string ch (in_channel_length ch) in
  close_in ch;
  execute_string ~source:path source

(* Bytecode VM: compile and run *)
let execute_string_bytecode ?(source : string = "<?>") (use_vm : bool) (input : string) : value list =
  if use_vm then begin
    let exprs = Reader_braces.read_dispatch ~source ~path:source input in
    (* Vm.init () first: it calls Evaluator.init (), which resets the macro
       table and wires up Primitives' force/eval/apply refs that macro
       expansion's Evaluator.eval call needs — expansion must run AFTER
       that, never before. *)
    Vm.init ();
    let expanded = Macro.expand_toplevel_list exprs in
    List.map (fun e ->
      with_toplevel_location e (fun () ->
        let bc = Compiler.compile_program [e] in
        Vm.run_program_expr bc)
    ) expanded
  end else
    execute_string ~source input

let execute_file_bytecode (use_vm : bool) (path : string) : value list =
  let ch = open_in path in
  let source = really_input_string ch (in_channel_length ch) in
  close_in ch;
  execute_string_bytecode ~source:path use_vm source

(* ---- Q13: run several sources under ONE init (main.ml's domain-glue
   wiring) ----

   `execute_string`/`execute_string_bytecode` each call `init()`
   unconditionally — correct for a single top-level run, but `init()`
   resets Runtime.domain_registry (Evaluator.init, alongside thunk_store/
   handler_stack/macro table), so two SEPARATE calls would make the second
   wipe out a `register-domain` a first call just performed. main.ml's
   --reconcile/--supervise auto-wiring needs exactly that: a small glue
   snippet that loads stdlib/domain-fs.pp and calls register-domain, THEN
   the user's program — sharing one registry, one macro table, one
   thunk_store. This is init() once, then each source processed in order
   (mirroring what execute_string/execute_string_bytecode do internally,
   without the redundant re-inits) — byte-identical to today's single-file
   behavior when given a one-element list. *)
let execute_sources_bytecode (use_vm : bool) (sources : (string * string) list) : value list =
  if use_vm then begin
    Vm.init ();
    List.concat_map (fun (source, input) ->
      let exprs = Reader_braces.read_dispatch ~source ~path:source input in
      let expanded = Macro.expand_toplevel_list exprs in
      List.map (fun e ->
        with_toplevel_location e (fun () ->
          let bc = Compiler.compile_program [e] in
          Vm.run_program_expr bc))
        expanded)
      sources
  end else begin
    init ();
    List.concat_map (fun (source, input) ->
      let exprs =
        Macro.expand_toplevel_list
          (Reader_braces.read_dispatch ~source ~path:source input) in
      List.map process_expr exprs)
      sources
  end

(* =================================================================== *)
(*  Input machinery                                                     *)
(* =================================================================== *)

(* M7 S4: multi-line continuation is brace/paren/bracket/string-nesting
   aware via the ACTUAL brace reader (Reader_braces.needs_more_input),
   not a hand-rolled bracket counter — see that function's header comment
   for why. *)
let input_balance (s : string) : bool = Reader_braces.needs_more_input s

(* ---- History (persisted to ~/.pp/history) ---- *)

let history : string list ref = ref []   (* newest first *)

let history_file () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  Filename.concat (Filename.concat home ".pp") "history"

let load_history () =
  history := [];
  try
    let ic = open_in (history_file ()) in
    (try
       while true do
         let l = input_line ic in
         if String.trim l <> "" then history := l :: !history
       done
     with End_of_file -> ());
    close_in ic
  with _ -> ()

let append_history (entry : string) : unit =
  let flat = String.map (fun c -> if c = '\n' then ' ' else c) entry in
  let dup = match !history with h :: _ -> h = flat | [] -> false in
  if String.trim flat <> "" && not dup then begin
    history := flat :: !history;
    try
      let dir = Filename.dirname (history_file ()) in
      (try Unix.mkdir dir 0o755 with _ -> ());
      let oc = open_out_gen [Open_append; Open_creat] 0o600 (history_file ()) in
      output_string oc (flat ^ "\n");
      close_out oc
    with _ -> ()
  end

(* ---- Raw-mode line editor (tty only) ---- *)

let write_str (s : string) : unit =
  ignore (Unix.write_substring Unix.stdout s 0 (String.length s))

(* Read one edited line. Returns None on EOF (Ctrl-D at an empty line). *)
let read_line_raw ~(prompt : string) : string option =
  let termio = Unix.tcgetattr Unix.stdin in
  let raw = { termio with Unix.c_icanon = false; c_echo = false;
                          c_isig = false; c_vmin = 1; c_vtime = 0 } in
  Unix.tcsetattr Unix.stdin Unix.TCSANOW raw;
  Fun.protect
    ~finally:(fun () -> Unix.tcsetattr Unix.stdin Unix.TCSANOW termio)
    (fun () ->
       let line = Buffer.create 64 in
       let set_line s = Buffer.clear line; Buffer.add_string line s in
       let pos = ref 0 in           (* cursor within the line *)
       let hist_idx = ref (-1) in   (* -1 = editing a fresh line *)
       let stash = ref "" in        (* fresh line saved while browsing *)
       let redraw () =
         let s = Buffer.contents line in
         write_str ("\r" ^ prompt ^ s ^ "\027[K");
         let back = String.length s - !pos in
         if back > 0 then write_str (Printf.sprintf "\027[%dD" back)
       in
       let insert c =
         let s = Buffer.contents line in
         set_line (String.sub s 0 !pos ^ String.make 1 c
                   ^ String.sub s !pos (String.length s - !pos));
         incr pos
       in
       let delete_at i =
         let s = Buffer.contents line in
         if i >= 0 && i < String.length s then
           set_line (String.sub s 0 i ^ String.sub s (i + 1) (String.length s - i - 1))
       in
       let recall idx =
         (if !hist_idx = -1 then stash := Buffer.contents line);
         hist_idx := idx;
         let s = if idx = -1 then !stash else List.nth !history idx in
         set_line s;
         pos := String.length s
       in
       let read1 () =
         let b = Bytes.create 1 in
         if Unix.read Unix.stdin b 0 1 = 0 then None else Some (Bytes.get b 0)
       in
       redraw ();
       let rec loop () =
         match read1 () with
         | None -> write_str "\r\n"; if Buffer.length line = 0 then None else Some (Buffer.contents line)
         | Some c ->
             (match c with
              | '\n' | '\r' ->
                  write_str "\r\n";
                  Some (Buffer.contents line)
              | '\004' (* Ctrl-D *) ->
                  if Buffer.length line = 0 then (write_str "\r\n"; None)
                  else (delete_at !pos; redraw (); loop ())
              | '\003' (* Ctrl-C *) ->
                  write_str "^C\r\n";
                  set_line ""; pos := 0; hist_idx := -1;
                  redraw (); loop ()
              | '\127' | '\b' ->
                  if !pos > 0 then (delete_at (!pos - 1); decr pos);
                  redraw (); loop ()
              | '\001' (* Ctrl-A *) -> pos := 0; redraw (); loop ()
              | '\005' (* Ctrl-E *) -> pos := Buffer.length line; redraw (); loop ()
              | '\011' (* Ctrl-K *) ->
                  set_line (String.sub (Buffer.contents line) 0 !pos);
                  redraw (); loop ()
              | '\021' (* Ctrl-U *) ->
                  set_line ""; pos := 0; redraw (); loop ()
              | '\023' (* Ctrl-W: delete word before cursor *) ->
                  let s = Buffer.contents line in
                  let j = ref !pos in
                  while !j > 0 && s.[!j - 1] = ' ' do decr j done;
                  while !j > 0 && s.[!j - 1] <> ' ' do decr j done;
                  set_line (String.sub s 0 !j ^ String.sub s !pos (String.length s - !pos));
                  pos := !j; redraw (); loop ()
              | '\027' (* ESC sequences *) ->
                  (match read1 () with
                   | Some ('[' | 'O') ->
                       (match read1 () with
                        | Some 'A' ->  (* Up *)
                            if !hist_idx + 1 < List.length !history then recall (!hist_idx + 1);
                            redraw (); loop ()
                        | Some 'B' ->  (* Down *)
                            if !hist_idx >= 0 then recall (!hist_idx - 1);
                            redraw (); loop ()
                        | Some 'C' ->  (* Right *)
                            if !pos < Buffer.length line then incr pos;
                            redraw (); loop ()
                        | Some 'D' ->  (* Left *)
                            if !pos > 0 then decr pos;
                            redraw (); loop ()
                        | Some 'H' -> pos := 0; redraw (); loop ()
                        | Some 'F' -> pos := Buffer.length line; redraw (); loop ()
                        | Some '3' ->
                            (match read1 () with
                             | Some '~' -> delete_at !pos; redraw (); loop ()
                             | _ -> loop ())
                        | _ -> loop ())
                   | _ -> loop ())
              | c when c >= ' ' -> insert c; redraw (); loop ()
              | _ -> loop ())
       in
       loop ())

(* One logical input line: raw editor on a tty, plain read otherwise (no
   prompt — piped sessions must not mix prompts into their output). *)
let read_input ~(tty : bool) ~(prompt : string) : string option =
  if tty then read_line_raw ~prompt
  else (try Some (read_line ()) with End_of_file -> None)

(* =================================================================== *)
(*  The REPL loop (both backends)                                       *)
(* =================================================================== *)

let help_text =
  "Commands:\n\
  \  :help          show this help\n\
  \  :why on|off    explain node-cache hits/misses\n\
  \  :graph         show cell->node dependency graph\n\
  \  :quit          leave (also exit, quit, Ctrl-D)\n\
   A form left open continues on the next line; results print deep-forced.\n"

let repl_loop ~(use_vm : bool) =
  init ();
  if use_vm then Vm.init ();
  let tty = (try Unix.isatty Unix.stdin with _ -> false) in
  if tty then begin
    Printf.printf "pp v%s%s — lazy, pure-by-default, content-addressed Lisp\n"
      Version.string
      (if use_vm then " [bytecode VM]" else "");
    Printf.printf "Type :help for commands, :quit or Ctrl-D to leave.\n\n%!";
    load_history ()
  end;
  let eval_one (e : expr) : value =
    if use_vm then
      with_toplevel_location e (fun () ->
        let bc = Compiler.compile_program [e] in
        Vm.run_program_expr bc)
    else process_expr e
  in
  (* Accumulate lines until the form closes. *)
  let rec read_form (acc : string) : string option =
    let prompt = if acc = "" then "pp> " else "..> " in
    match read_input ~tty ~prompt with
    | None -> if acc = "" then None else Some acc
    | Some l ->
        let full = if acc = "" then l else acc ^ "\n" ^ l in
        if String.trim full = "" then read_form ""
        else if input_balance full then read_form full
        else Some full
  in
  let rec loop () =
    match read_form "" with
    | None -> if tty then Printf.printf "bye.\n%!"
    | Some input ->
        let t = String.trim input in
        if t = "" then loop ()
        else if t = "exit" || t = "quit" || t = ":quit" || t = ":q" then begin
          if tty then Printf.printf "bye.\n%!"
        end
        else if t = ":help" then (print_string help_text; loop ())
        else if t = ":why on" then (Store.why_mode := true;
                                    Printf.printf "why: on\n%!"; loop ())
        else if t = ":why off" then (Store.why_mode := false;
                                     Printf.printf "why: off\n%!"; loop ())
        else if t = ":graph" then (Store.print_graph (); loop ())
        else begin
          if tty then append_history input;
          (try
             (* M3 defmacro: the macro table persists across REPL turns
                (reset only by init ()/Vm.init () at repl_loop's start), so
                a macro defined on one line is usable on a later one — same
                sequential-top-level rule as a file. M7 S4: the interactive
                REPL reads braces directly (not via read_dispatch's
                extension sniffing — there is no file here at all). *)
             let exprs =
               Macro.expand_toplevel_list
                 (Reader_braces.read_string ~source:"<repl>" input) in
             List.iter (fun e ->
               let v = eval_one e in
               Printf.printf "%s\n%!" (string_of_value (Primitives.force_deep v))
             ) exprs
           with
           | Types.Pp_exit n -> exit n
           | Failure msg -> Printf.printf "Error: %s\n%!" msg
           | Sys_error msg -> Printf.printf "Error: %s\n%!" msg
           | Types.Capability_error msg -> Printf.printf "Error: %s\n%!" msg
           | e -> Printf.printf "Error: %s\n%!" (Printexc.to_string e));
          loop ()
        end
  in
  loop ()

let repl () = repl_loop ~use_vm:false
let repl_bytecode () = repl_loop ~use_vm:true
