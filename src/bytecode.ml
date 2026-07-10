(* pp bytecode — serialization, disassembly, and VM utilities *)

open Types

(* ---- Serialization (.ppc) ---- *)

(* Tag bytes for constant types in the .ppc format *)
let const_tag_nil = 0
let const_tag_bool = 1
let const_tag_int = 2
let const_tag_float = 3
let const_tag_string = 4
let const_tag_keyword = 5
let const_tag_symbol = 6
let const_tag_pair_start = 7
let const_tag_vector_start = 8
let const_tag_map_start = 9
let const_tag_cap = 10

(* Opcode IDs for serialization (stable mapping) *)
let opcode_id = function
  | PUSH _ -> 0
  | LOAD_LOCAL _ -> 1
  | STORE_LOCAL _ -> 2
  | LOAD_GLOBAL _ -> 3
  | STORE_GLOBAL _ -> 4
  | POP -> 5 | DUP -> 6
  | JUMP _ -> 7 | JUMP_IF_FALSE _ -> 8
  | FORCE -> 9
  | MAKE_THUNK _ -> 10
  | MAKE_CLOSURE _ -> 11
  | CALL _ -> 12 | TAIL_CALL _ -> 13
  | RETURN -> 15 | HALT -> 16
  | BUILTIN _ -> 17
  | CONS -> 18
  | ENTER_EFFECT -> 19 | EXIT_EFFECT -> 20
  | PERFORM _ -> 21
  | PUSH_HANDLER _ -> 22 | POP_HANDLER -> 23
  | MAKE_MODULE _ -> 24
  | IMPORT -> 25
  | LOAD_FILE _ -> 26 | LOAD_MODULE_FILE _ -> 27
  | NOP -> 28
  | PUSH_CONFIG -> 29
  | POP_CONFIG -> 30
  | READ_CONFIG -> 31

(**
  Serialize a bytecode unit to a binary string.

  Format (little-endian):
  - Magic: "PPBC01" (6 bytes)
  - u32 const-count
  - each constant: u8 tag, then type-specific payload
  - u32 code-count (opcode count)
  - each opcode: u8 opcode-id, then its operands as u32s
  - u32 nparams_of entry-count
  - each entry: (u32 offset, u32 nparams)
*)
let save (bc : bytecode) : string =
  let buf = Buffer.create 4096 in

  let put_u8 n = Buffer.add_char buf (Char.chr (n land 0xff)) in
  let put_u32 n =
    put_u8 (n land 0xff);
    put_u8 ((n lsr 8) land 0xff);
    put_u8 ((n lsr 16) land 0xff);
    put_u8 ((n lsr 24) land 0xff)
  in

  (* Write a constant value recursively *)
  let rec put_const (v : value) =
    match v with
    | VNil -> put_u8 const_tag_nil
    | VBool b -> put_u8 const_tag_bool; put_u8 (if b then 1 else 0)
    | VInt n ->
        let s = string_of_int n in
        put_u8 const_tag_int;
        put_u32 (String.length s);
        String.iter (fun c -> put_u8 (Char.code c)) s
    | VFloat f ->
        let s = string_of_float f in
        put_u8 const_tag_float;
        put_u32 (String.length s);
        String.iter (fun c -> put_u8 (Char.code c)) s
    | VString s ->
        put_u8 const_tag_string;
        put_u32 (String.length s);
        String.iter (fun c -> put_u8 (Char.code c)) s
    | VKeyword s ->
        put_u8 const_tag_keyword;
        put_u32 (String.length s);
        String.iter (fun c -> put_u8 (Char.code c)) s
    | VSymbol s ->
        put_u8 const_tag_symbol;
        put_u32 (String.length s);
        String.iter (fun c -> put_u8 (Char.code c)) s
    | VPair (car, cdr) ->
        put_u8 const_tag_pair_start;
        put_const car;
        put_const cdr
    | VVector vs ->
        put_u8 const_tag_vector_start;
        put_u32 (Array.length vs);
        Array.iter put_const vs
    | VMap kvs ->
        put_u8 const_tag_map_start;
        put_u32 (List.length kvs);
        List.iter (fun (k, v) -> put_const k; put_const v) kvs
    | VSet vs ->
        put_u8 const_tag_map_start;
        put_u32 (List.length vs);
        List.iter put_const vs
    | VCapability _ ->
        put_u8 const_tag_cap;
        put_u8 0
    | VClosure _ | VBuiltin _ | VThunk _ | VEnvMap _ | VBytecode _ ->
        (* Non-serializable constants; write as nil *)
        put_u8 const_tag_nil
  in

  (* Magic *)
  String.iter (fun c -> put_u8 (Char.code c)) "PPBC02";

  (* Constants *)
  put_u32 (Array.length bc.consts);
  Array.iter put_const bc.consts;

  (* Code *)
  let put_opcode op =
    match op with
    | PUSH i -> put_u8 0; put_u32 i
    | LOAD_LOCAL (d, s) -> put_u8 1; put_u32 d; put_u32 s
    | STORE_LOCAL s -> put_u8 2; put_u32 s
    | LOAD_GLOBAL i -> put_u8 3; put_u32 i
    | STORE_GLOBAL i -> put_u8 4; put_u32 i
    | POP -> put_u8 5 | DUP -> put_u8 6
    | JUMP i -> put_u8 7; put_u32 i
    | JUMP_IF_FALSE i -> put_u8 8; put_u32 i
    | FORCE -> put_u8 9
    | MAKE_THUNK (off, ta, tl) ->
        put_u8 10; put_u32 off;
        (match ta with
         | None -> put_u8 0
         | Some e -> put_u8 1; put_const (quote_to_value e));
        (match tl with
         | None -> put_u8 0
         | Some (file, line) -> put_u8 1; put_u32 (String.length file);
                                String.iter (fun c -> put_u8 (Char.code c)) file;
                                put_u32 line)
    | MAKE_CLOSURE (off, np) -> put_u8 11; put_u32 off; put_u32 np
    | CALL n -> put_u8 12; put_u32 n
    | TAIL_CALL n -> put_u8 14; put_u32 n
    | RETURN -> put_u8 15 | HALT -> put_u8 16
    | BUILTIN i -> put_u8 17; put_u32 i
    | CONS -> put_u8 18
    | ENTER_EFFECT -> put_u8 19 | EXIT_EFFECT -> put_u8 20
    | PERFORM (n, a) -> put_u8 21; put_u32 n; put_u32 a
    | PUSH_HANDLER n -> put_u8 22; put_u32 n
    | POP_HANDLER -> put_u8 23
    | MAKE_MODULE n -> put_u8 24; put_u32 n
    | IMPORT -> put_u8 25
    | LOAD_FILE i -> put_u8 26; put_u32 i
    | LOAD_MODULE_FILE i -> put_u8 27; put_u32 i
    | NOP -> put_u8 28
    | PUSH_CONFIG -> put_u8 29
    | POP_CONFIG -> put_u8 30
    | READ_CONFIG -> put_u8 31
  in
  put_u32 (Array.length bc.code);
  Array.iter put_opcode bc.code;

  (* nparams_of *)
  let np_entries = Hashtbl.fold (fun off np acc -> (off, np) :: acc) bc.nparams_of [] in
  put_u32 (List.length np_entries);
  List.iter (fun (off, np) -> put_u32 off; put_u32 np) np_entries;

  (* param_names_of *)
  let pn_entries = Hashtbl.fold (fun off names acc -> (off, names) :: acc) bc.param_names_of [] in
  put_u32 (List.length pn_entries);
  List.iter (fun (off, names) ->
    put_u32 off;
    put_u32 (List.length names);
    List.iter (fun nm ->
      put_u32 (String.length nm);
      String.iter (fun c -> put_u8 (Char.code c)) nm
    ) names
  ) pn_entries;
  Buffer.contents buf

(**
  Deserialize a binary string back to a bytecode unit.
  Raises [Failure] on corrupt or unknown input.
*)
let load (data : string) : bytecode =
  let pos = ref 0 in

  let get_u8 () =
    if !pos >= String.length data then failwith "bytecode: unexpected end of data";
    let b = Char.code data.[!pos] in
    incr pos;
    b
  in

  let get_u32 () =
    let b0 = get_u8 () in
    let b1 = get_u8 () in
    let b2 = get_u8 () in
    let b3 = get_u8 () in
    b0 lor (b1 lsl 8) lor (b2 lsl 16) lor (b3 lsl 24)
  in

  (* Check magic *)
  let magic = Bytes.create 6 in
  for i = 0 to 5 do Bytes.set magic i (Char.chr (get_u8 ())) done;
  if Bytes.to_string magic <> "PPBC02" then
    failwith "bytecode: bad magic — expected PPBC02, version mismatch?";

  (* Constants *)
  let rec get_const () =
    let tag = get_u8 () in
    match tag with
    | 0 -> VNil
    | 1 -> let b = get_u8 () in VBool (b <> 0)
    | 2 ->
        let len = get_u32 () in
        let s = Bytes.create len in
        for i = 0 to len - 1 do Bytes.set s i (Char.chr (get_u8 ())) done;
        VInt (int_of_string (Bytes.to_string s))
    | 3 ->
        let len = get_u32 () in
        let s = Bytes.create len in
        for i = 0 to len - 1 do Bytes.set s i (Char.chr (get_u8 ())) done;
        VFloat (float_of_string (Bytes.to_string s))
    | 4 ->
        let len = get_u32 () in
        let s = Bytes.create len in
        for i = 0 to len - 1 do Bytes.set s i (Char.chr (get_u8 ())) done;
        VString (Bytes.to_string s)
    | 5 ->
        let len = get_u32 () in
        let s = Bytes.create len in
        for i = 0 to len - 1 do Bytes.set s i (Char.chr (get_u8 ())) done;
        VKeyword (Bytes.to_string s)
    | 6 ->
        let len = get_u32 () in
        let s = Bytes.create len in
        for i = 0 to len - 1 do Bytes.set s i (Char.chr (get_u8 ())) done;
        VSymbol (Bytes.to_string s)
    | 7 ->
        let car = get_const () in
        let cdr = get_const () in
        VPair (car, cdr)
    | 8 ->
        let n = get_u32 () in
        let vs = Array.make n VNil in
        for i = 0 to n - 1 do vs.(i) <- get_const () done;
        VVector vs
    | 9 ->
        let n = get_u32 () in
        let kvs = ref [] in
        for _ = 1 to n do
          let k = get_const () in
          let v = get_const () in
          kvs := (k, v) :: !kvs
        done;
        VMap (List.rev !kvs)
    | 10 ->
        ignore (get_u8 ());  (* skip cap payload, not serializable *)
        VNil
    | _ -> failwith (Printf.sprintf "bytecode: unknown const tag %d" tag)
  in

  let const_count = get_u32 () in
  let consts = Array.make const_count VNil in
  for i = 0 to const_count - 1 do consts.(i) <- get_const () done;

  (* Code *)
  let get_opcode () =
    let id = get_u8 () in
    match id with
    | 0 -> let i = get_u32 () in PUSH i
    | 1 -> let d = get_u32 () in let s = get_u32 () in LOAD_LOCAL (d, s)
    | 2 -> let s = get_u32 () in STORE_LOCAL s
    | 3 -> let i = get_u32 () in LOAD_GLOBAL i
    | 4 -> let i = get_u32 () in STORE_GLOBAL i
    | 5 -> POP | 6 -> DUP
    | 7 -> let i = get_u32 () in JUMP i
    | 8 -> let i = get_u32 () in JUMP_IF_FALSE i
    | 9 -> FORCE
    | 10 ->
        let off = get_u32 () in
        let _ta =
          match get_u8 () with
          | 0 -> None
          | 1 -> ignore (get_const ()); None  (* stored as quoted value; cannot reconstruct expr *)
          | _ -> failwith "bytecode: bad MAKE_THUNK type-annotation flag"
        in
        let tl =
          match get_u8 () with
          | 0 -> None
          | 1 ->
              let file_len = get_u32 () in
              let file = Bytes.create file_len in
              for j = 0 to file_len - 1 do Bytes.set file j (Char.chr (get_u8 ())) done;
              let line = get_u32 () in
              Some (Bytes.to_string file, line)
          | _ -> failwith "bytecode: bad MAKE_THUNK location flag"
        in
        MAKE_THUNK (off, None, tl)
    | 11 -> let off = get_u32 () in let np = get_u32 () in MAKE_CLOSURE (off, np)
    | 13 -> let n = get_u32 () in CALL n
    | 14 -> let n = get_u32 () in TAIL_CALL n
    | 15 -> RETURN | 16 -> HALT
    | 17 -> let i = get_u32 () in BUILTIN i
    | 18 -> CONS
    | 19 -> ENTER_EFFECT | 20 -> EXIT_EFFECT
    | 21 -> let n = get_u32 () in let a = get_u32 () in PERFORM (n, a)
    | 22 -> let n = get_u32 () in PUSH_HANDLER n
    | 23 -> POP_HANDLER
    | 24 -> let n = get_u32 () in MAKE_MODULE n
    | 25 -> IMPORT
    | 26 -> let i = get_u32 () in LOAD_FILE i
    | 27 -> let i = get_u32 () in LOAD_MODULE_FILE i
    | 28 -> NOP
    | 29 -> PUSH_CONFIG
    | 30 -> POP_CONFIG
    | 31 -> READ_CONFIG
    | _ -> failwith (Printf.sprintf "bytecode: unknown opcode id %d" id)
  in

  let code_count = get_u32 () in
  let code = Array.make code_count NOP in
  for i = 0 to code_count - 1 do code.(i) <- get_opcode () done;

  (* nparams_of *)
  let nparams_of = Hashtbl.create 16 in
  let np_count = get_u32 () in
  for _ = 1 to np_count do
    let off = get_u32 () in
    let np = get_u32 () in
    Hashtbl.add nparams_of off np
  done;
  (* param_names_of *)
  let param_names_of = Hashtbl.create 16 in
  let pn_count = get_u32 () in
  for _ = 1 to pn_count do
    let off = get_u32 () in
    let name_count = get_u32 () in
    let names = ref [] in
    for _ = 1 to name_count do
      let len = get_u32 () in
      let s = Bytes.create len in
      for j = 0 to len - 1 do Bytes.set s j (Char.chr (get_u8 ())) done;
      names := Bytes.to_string s :: !names
    done;
    Hashtbl.add param_names_of off (List.rev !names)
  done;

  let closure_names_of = Hashtbl.create 16 in
  { consts; code; nparams_of; param_names_of; closure_names_of }

(* ---- Debug: string of opcode and disassembly ---- *)

let string_of_opcode = function
  | PUSH i -> Printf.sprintf "PUSH %d" i
  | LOAD_LOCAL (d, s) -> Printf.sprintf "LOAD_LOCAL %d %d" d s
  | STORE_LOCAL s -> Printf.sprintf "STORE_LOCAL %d" s
  | LOAD_GLOBAL i -> Printf.sprintf "LOAD_GLOBAL %d" i
  | STORE_GLOBAL i -> Printf.sprintf "STORE_GLOBAL %d" i
  | POP -> "POP" | DUP -> "DUP"
  | JUMP i -> Printf.sprintf "JUMP %d" i
  | JUMP_IF_FALSE i -> Printf.sprintf "JUMP_IF_FALSE %d" i
  | FORCE -> "FORCE"
  | MAKE_THUNK (off, _, _) -> Printf.sprintf "MAKE_THUNK %d" off
  | MAKE_CLOSURE (off, np) -> Printf.sprintf "MAKE_CLOSURE %d %d" off np
  | CALL n -> Printf.sprintf "CALL %d" n
  | TAIL_CALL n -> Printf.sprintf "TAIL_CALL %d" n
  | RETURN -> "RETURN" | HALT -> "HALT"
  | BUILTIN i -> Printf.sprintf "BUILTIN %d" i
  | CONS -> "CONS"
  | ENTER_EFFECT -> "ENTER_EFFECT" | EXIT_EFFECT -> "EXIT_EFFECT"
  | PERFORM (n, a) -> Printf.sprintf "PERFORM %d %d" n a
  | PUSH_HANDLER n -> Printf.sprintf "PUSH_HANDLER %d" n
  | POP_HANDLER -> "POP_HANDLER"
  | MAKE_MODULE n -> Printf.sprintf "MAKE_MODULE %d" n
  | IMPORT -> "IMPORT"
  | LOAD_FILE i -> Printf.sprintf "LOAD_FILE %d" i
  | LOAD_MODULE_FILE i -> Printf.sprintf "LOAD_MODULE_FILE %d" i
  | NOP -> "NOP"
  | PUSH_CONFIG -> "PUSH_CONFIG"
  | POP_CONFIG -> "POP_CONFIG"
  | READ_CONFIG -> "READ_CONFIG"

let disassemble (bc : bytecode) : string =
  let lines = Array.mapi (fun i op ->
    Printf.sprintf "%04d: %s" i (string_of_opcode op)
  ) bc.code in
  String.concat "\n" (Array.to_list lines)
