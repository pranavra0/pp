(* pp REPL — Read-Eval-Print Loop

   ROADMAP §1 REPL quality:
   - multi-line input: a form left open (paren balance, string- and
     comment-aware) continues onto the next line under a "..> " prompt;
   - history: persisted to ~/.pp/history, browsable with Up/Down;
   - line editing: raw-mode editor (arrows, Home/End, Ctrl-A/E/K/U/W,
     backspace/delete) when stdin is a tty; plain line reads otherwise —
     piped sessions print no prompts or banner, so `echo '(+ 1 2)' | pp`
     emits exactly "3";
   - printing: results are deep-forced for display (a thunk shows its value);
   - `:help`, `:why on|off` (the node-cache explainer), `:quit`. *)

open Types
open Reader
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
   Shared by both backends' drivers, so the reported text is identical. *)
let message_has_location (msg : string) : bool =
  let n = String.length msg in
  let contains_at =
    let rec go i = i + 4 <= n && (String.sub msg i 4 = " at " || go (i + 1)) in
    go 0 in
  let all_digits i =
    i < n &&
    (let ok = ref true in
     for k = i to n - 1 do
       if not (msg.[k] >= '0' && msg.[k] <= '9') then ok := false
     done; !ok) in
  match String.rindex_opt msg ':' with
  | Some i -> contains_at && all_digits (i + 1)
  | None -> false

let with_toplevel_location (e : expr) (f : unit -> 'a) : 'a =
  match e with
  | ELocated ((file, line), _) ->
      let relocate msg =
        if message_has_location msg then msg
        else Printf.sprintf "%s at %s:%d" msg file line in
      (try f () with
       | Failure msg -> failwith (relocate msg)
       | Types.Capability_error msg ->
           raise (Types.Capability_error (relocate msg)))
  | _ -> f ()

(* Tree-walker: process a single expression *)
let process_expr (e : expr) : value =
  with_toplevel_location e (fun () ->
    match eval_expressions [e] global_env with
    | VEnvMap _ as v -> v
    | v -> v)

(* Tree-walker: execute a source string *)
let execute_string ?(source : string = "<?>") (input : string) : value list =
  init ();
  let exprs = read_string ~source input in
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
    let exprs = read_string ~source input in
    Vm.init ();
    List.map (fun e ->
      with_toplevel_location e (fun () ->
        let bc = Compiler.compile_program [e] in
        Vm.run_program_expr bc)
    ) exprs
  end else
    execute_string ~source input

let execute_file_bytecode (use_vm : bool) (path : string) : value list =
  let ch = open_in path in
  let source = really_input_string ch (in_channel_length ch) in
  close_in ch;
  execute_string_bytecode ~source:path use_vm source

(* =================================================================== *)
(*  Input machinery                                                     *)
(* =================================================================== *)

(* Paren balance of an input buffer, string- and comment-aware. > 0 means
   the form is still open (keep reading); an unterminated string also holds
   the form open. Negative imbalance is left for the reader to report. *)
let input_balance (s : string) : int =
  let n = String.length s in
  let depth = ref 0 in
  let i = ref 0 in
  let unterminated_string = ref false in
  while !i < n do
    (match s.[!i] with
     | '"' ->
         incr i;
         let closed = ref false in
         while not !closed && !i < n do
           (match s.[!i] with
            | '\\' -> i := !i + 1  (* skip the escaped char too *)
            | '"' -> closed := true
            | _ -> ());
           incr i
         done;
         unterminated_string := not !closed;
         i := !i - 1  (* the outer loop increments *)
     | ';' -> while !i < n && s.[!i] <> '\n' do incr i done
     | '(' | '[' | '{' -> incr depth
     | ')' | ']' | '}' -> decr depth
     | _ -> ());
    incr i
  done;
  if !unterminated_string && !depth <= 0 then 1 else !depth

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
    Printf.printf "pp v0.1.0%s — lazy, pure-by-default, content-addressed Lisp\n"
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
        else if input_balance full > 0 then read_form full
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
             let exprs = read_string ~source:"<repl>" input in
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
