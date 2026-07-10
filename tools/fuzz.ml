(* pp differential fuzzer — generates random pp programs, runs them under both
   backends (tree-walker `./pp f` and bytecode VM `./pp --bytecode f`), and
   asserts identical observable behavior (stdout; stderr when both succeed).

   OCaml stdlib + unix only.  Build:  ocamlc -I +unix unix.cma -o fuzz tools/fuzz.ml
   Fully deterministic given --seed: program i is generated from
   Random.full_init [| seed; i |], so any program can be regenerated with
   --seed S --start i --count 1 (or inspected with --dump i).

   Grammar notes (verified against src/primitives.ml, stdlib/list.pp, reader.ml):
   - builtins used: + - * / mod < > <= >= = not list cons car cdr nil? print
     string-append string-length vector vector-get hash-map hash-map-get
   - stdlib fns (require (load ".../stdlib/list.pp")): map filter foldl range take length
   - `and`/`or` are reader-level special forms (desugar to if) — safe.
   - (def x 5) creates a NULLARY CLOSURE, not a constant — so the generator
     only ever defs functions with >= 1 parameter.
   - `let` is parallel in the tree-walker (bindings see the OUTER env) but
     effectively sequential in the VM; core-grammar lets never reference
     sibling bindings.  The sequential-reference case is a deliberate
     `full`-grammar divergence probe.
   - car/cdr of nil returns nil (no error); still, car is only applied to
     statically-nonempty lists so arithmetic on the element is well-typed.
   - / and mod only ever get a nonzero positive literal divisor.
   - No random / island / wall-clock forms are ever generated. *)

(* ---------------------------------------------------------------- CLI ---- *)

let seed = ref 0
let count = ref 1000
let max_depth = ref 6
let timeout_ms = ref 5000
let out_dir = ref "fuzz-failures"
let grammar = ref "core"
let start_iter = ref 0
let dump_iter = ref (-1)
let pp_bin = ref "./pp"
let stdlib_path = ref ""   (* default computed from cwd *)
let shrink_budget = ref 300

let usage () =
  prerr_endline "usage: fuzz [--seed N] [--count K] [--max-depth D] [--timeout-ms T]";
  prerr_endline "            [--out DIR] [--grammar core|full] [--start N] [--dump N]";
  prerr_endline "            [--pp PATH] [--stdlib PATH] [--shrink-budget N]";
  exit 2

let parse_cli () =
  let rec go = function
    | [] -> ()
    | "--seed" :: v :: r -> seed := int_of_string v; go r
    | "--count" :: v :: r -> count := int_of_string v; go r
    | "--max-depth" :: v :: r -> max_depth := int_of_string v; go r
    | "--timeout-ms" :: v :: r -> timeout_ms := int_of_string v; go r
    | "--out" :: v :: r -> out_dir := v; go r
    | "--grammar" :: v :: r ->
        if v <> "core" && v <> "full" then usage (); grammar := v; go r
    | "--start" :: v :: r -> start_iter := int_of_string v; go r
    | "--dump" :: v :: r -> dump_iter := int_of_string v; go r
    | "--pp" :: v :: r -> pp_bin := v; go r
    | "--stdlib" :: v :: r -> stdlib_path := v; go r
    | "--shrink-budget" :: v :: r -> shrink_budget := int_of_string v; go r
    | ("--help" | "-h") :: _ -> usage ()
    | x :: _ -> prerr_endline ("unknown argument: " ^ x); usage ()
  in
  go (List.tl (Array.to_list Sys.argv));
  if !stdlib_path = "" then
    stdlib_path := Filename.concat (Sys.getcwd ()) "stdlib/list.pp"

(* ------------------------------------------------------------- S-exprs -- *)

type sx =
  | A of string        (* atom, rendered verbatim *)
  | S of sx list       (* ( ... ) *)
  | V of sx list       (* [ ... ] *)
  | C of sx list       (* { ... } *)

let rec render_sx buf sx =
  match sx with
  | A s -> Buffer.add_string buf s
  | S xs -> Buffer.add_char buf '('; render_list buf xs; Buffer.add_char buf ')'
  | V xs -> Buffer.add_char buf '['; render_list buf xs; Buffer.add_char buf ']'
  | C xs -> Buffer.add_char buf '{'; render_list buf xs; Buffer.add_char buf '}'

and render_list buf = function
  | [] -> ()
  | [x] -> render_sx buf x
  | x :: rest -> render_sx buf x; Buffer.add_char buf ' '; render_list buf rest

let render_program (forms : sx list) : string =
  let buf = Buffer.create 512 in
  List.iter (fun f -> render_sx buf f; Buffer.add_char buf '\n') forms;
  Buffer.contents buf

(* ----------------------------------------------------------- Generator -- *)

type ty = TInt | TFloat | TBool | TStr | TList

type gvar = { vname : string; vty : ty; vne : bool }  (* vne: list known nonempty *)

type genv = {
  vars : gvar list;                  (* lexical, per-statement *)
  mutable fns : (string * int * bool) list;
                                     (* top-level int fns: name, arity, recursive.
                                        Args at call sites of RECURSIVE fns are
                                        wrapped in (mod _ 64): recursion depth
                                        stays bounded, so a one-sided timeout on
                                        a terminating-but-slow program (perf
                                        asymmetry, not semantics) cannot poison
                                        the ratchet. *)
  mutable stdlib : bool;             (* stdlib list.pp loaded *)
}

let name_counter = ref 0
let fresh prefix = incr name_counter; Printf.sprintf "%s%d" prefix !name_counter

let rint lo hi = lo + Random.int (hi - lo + 1)
let flip p = Random.float 1.0 < p

(* weighted pick *)
let pick (choices : (int * (unit -> 'a)) list) : 'a =
  let total = List.fold_left (fun a (w, _) -> a + w) 0 choices in
  let n = Random.int total in
  let rec go acc = function
    | [] -> assert false
    | (w, f) :: rest -> if n < acc + w then f () else go (acc + w) rest
  in
  go 0 choices

let str_pool = [| "a"; "bc"; "xyz"; "hello"; "pp"; "zz"; "q0"; "lisp" |]
let gen_str_lit () = A ("\"" ^ str_pool.(Random.int (Array.length str_pool)) ^ "\"")
(* NOTE: literals are kept NON-NEGATIVE on purpose.  The pp reader has a bug
   (reader.ml:89-91: the '-' branch re-peeks '-' itself, so read_number is
   unreachable) that makes bare negative literals like -5 lex as SYMBOLS and
   fail as "unbound symbol: -5" in BOTH backends.  That is a real reader bug
   (found by this fuzzer's first run) but it is identical noise for a
   differential fuzzer; negative values still arise via subtraction. *)
let gen_int_lit () = A (string_of_int (rint 0 100))
let gen_float_lit () =
  A (string_of_float (float_of_int (rint 0 40) /. 2.0))

let vars_of ty env = List.filter (fun v -> v.vty = ty) env.vars
let has_vars ty env = vars_of ty env <> []
let pick_var ty env =
  let vs = vars_of ty env in
  (List.nth vs (Random.int (List.length vs))).vname

(* --- typed expression generators (mutually recursive) --- *)

let rec gen_int env d : sx =
  if d <= 0 then
    pick [
      4, (fun () -> gen_int_lit ());
      (if has_vars TInt env then 3 else 0), (fun () -> A (pick_var TInt env));
    ]
  else
    pick [
      3, (fun () -> gen_int_lit ());
      (if has_vars TInt env then 3 else 0), (fun () -> A (pick_var TInt env));
      4, (fun () ->
        let op = [| "+"; "-"; "*" |].(Random.int 3) in
        let n_args = if op <> "-" && flip 0.25 then 3 else 2 in
        let args = List.init n_args (fun _ -> gen_int env (d - 1)) in
        S (A op :: args));
      1, (fun () -> S [A "mod"; gen_int env (d - 1); A (string_of_int (rint 1 9))]);
      1, (fun () -> S [A "/"; gen_int env (d - 1); A (string_of_int (rint 1 9))]);
      2, (fun () -> S [A "if"; gen_bool env (d - 1); gen_int env (d - 1); gen_int env (d - 1)]);
      1, (fun () ->
        (* (let [x <int>] <int using x>) — binding evaluated in OUTER env *)
        let x = fresh "x" in
        let bind = gen_int env (d - 1) in
        let env' = { env with vars = { vname = x; vty = TInt; vne = false } :: env.vars } in
        S [A "let"; V [A x; bind]; gen_int env' (d - 1)]);
      (if env.fns <> [] then 2 else 0), (fun () ->
        let (f, arity, is_rec) = List.nth env.fns (Random.int (List.length env.fns)) in
        let arg () =
          let e = gen_int env (d - 1) in
          if is_rec then S [A "mod"; e; A "64"] else e in
        S (A f :: List.init arity (fun _ -> arg ())));
      1, (fun () -> S [A "string-length"; gen_string env (d - 1)]);
      (if env.stdlib then 1 else 0), (fun () -> S [A "length"; gen_list env (d - 1)]);
      (if env.stdlib then 1 else 0), (fun () -> S [A "foldl"; A "+"; A "0"; gen_list env (d - 1)]);
      1, (fun () -> S [A "car"; gen_list_ne env (d - 1)]);
      1, (fun () ->
        S [A "vector-get";
           V [gen_int env (d - 1); gen_int env (d - 1); gen_int env (d - 1)];
           A (string_of_int (rint 0 2))]);
      1, (fun () ->
        let k = fresh "k" in
        S [A "hash-map-get"; C [A (":" ^ k); gen_int env (d - 1)]; A (":" ^ k)]);
      1, (fun () ->
        (* immediate application ((fn (x) body) arg) *)
        let x = fresh "x" in
        let env' = { env with vars = { vname = x; vty = TInt; vne = false } :: env.vars } in
        S [S [A "fn"; S [A x]; gen_int env' (d - 1)]; gen_int env (d - 1)]);
      1, (fun () -> S [A "do"; gen_int env (d - 1); gen_int env (d - 1)]);
    ]

and gen_bool env d : sx =
  if d <= 0 then
    pick [
      2, (fun () -> A (if flip 0.5 then "true" else "false"));
      (if has_vars TBool env then 2 else 0), (fun () -> A (pick_var TBool env));
    ]
  else
    pick [
      2, (fun () -> A (if flip 0.5 then "true" else "false"));
      (if has_vars TBool env then 2 else 0), (fun () -> A (pick_var TBool env));
      4, (fun () ->
        let op = [| "<"; ">"; "<="; ">="; "=" |].(Random.int 5) in
        S [A op; gen_int env (d - 1); gen_int env (d - 1)]);
      1, (fun () -> S [A "="; gen_string env (d - 1); gen_string env (d - 1)]);
      1, (fun () -> S [A "not"; gen_bool env (d - 1)]);
      2, (fun () ->
        let op = if flip 0.5 then "and" else "or" in
        S [A op; gen_bool env (d - 1); gen_bool env (d - 1)]);
      1, (fun () -> S [A "nil?"; gen_list env (d - 1)]);
      1, (fun () -> S [A "if"; gen_bool env (d - 1); gen_bool env (d - 1); gen_bool env (d - 1)]);
    ]

and gen_string env d : sx =
  if d <= 0 then
    pick [
      3, (fun () -> gen_str_lit ());
      (if has_vars TStr env then 2 else 0), (fun () -> A (pick_var TStr env));
    ]
  else
    pick [
      3, (fun () -> gen_str_lit ());
      (if has_vars TStr env then 2 else 0), (fun () -> A (pick_var TStr env));
      3, (fun () -> S [A "string-append"; gen_string env (d - 1); gen_string env (d - 1)]);
      1, (fun () -> S [A "if"; gen_bool env (d - 1); gen_string env (d - 1); gen_string env (d - 1)]);
    ]

and gen_float env d : sx =
  if d <= 0 then
    pick [
      3, (fun () -> gen_float_lit ());
      (if has_vars TFloat env then 2 else 0), (fun () -> A (pick_var TFloat env));
    ]
  else
    pick [
      3, (fun () -> gen_float_lit ());
      (if has_vars TFloat env then 2 else 0), (fun () -> A (pick_var TFloat env));
      3, (fun () ->
        let op = [| "+"; "-"; "*" |].(Random.int 3) in
        S [A op; gen_float env (d - 1); gen_float env (d - 1)]);
      1, (fun () -> S [A "if"; gen_bool env (d - 1); gen_float env (d - 1); gen_float env (d - 1)]);
    ]

(* list of ints, statically NONEMPTY *)
and gen_list_ne env d : sx =
  if d <= 0 then
    let ne_vars = List.filter (fun v -> v.vty = TList && v.vne) env.vars in
    if ne_vars <> [] && flip 0.4 then
      A (List.nth ne_vars (Random.int (List.length ne_vars))).vname
    else
      S (A "list" :: List.init (rint 1 3) (fun _ -> gen_int_lit ()))
  else
    pick [
      3, (fun () -> S (A "list" :: List.init (rint 1 3) (fun _ -> gen_int env (d - 1))));
      3, (fun () -> S [A "cons"; gen_int env (d - 1); gen_list env (d - 1)]);
      (if env.stdlib then 2 else 0), (fun () ->
        let a = rint 0 5 in let b = a + rint 1 6 in
        S [A "range"; A (string_of_int a); A (string_of_int b)]);
      (if env.stdlib then 1 else 0), (fun () ->
        let x = fresh "x" in
        let env' = { env with vars = { vname = x; vty = TInt; vne = false } :: env.vars } in
        S [A "map"; S [A "fn"; S [A x]; gen_int env' (d - 1)]; gen_list_ne env (d - 1)]);
      (let ne_vars = List.filter (fun v -> v.vty = TList && v.vne) env.vars in
       (if ne_vars <> [] then 2 else 0)),
      (fun () ->
        let ne_vars = List.filter (fun v -> v.vty = TList && v.vne) env.vars in
        A (List.nth ne_vars (Random.int (List.length ne_vars))).vname);
    ]

(* list of ints, possibly empty *)
and gen_list env d : sx =
  if d <= 0 then
    pick [
      2, (fun () -> A "nil");
      2, (fun () -> gen_list_ne env 0);
      (if has_vars TList env then 2 else 0), (fun () -> A (pick_var TList env));
    ]
  else
    pick [
      1, (fun () -> A "nil");
      4, (fun () -> gen_list_ne env d);
      (if has_vars TList env then 2 else 0), (fun () -> A (pick_var TList env));
      1, (fun () -> S [A "cdr"; gen_list_ne env (d - 1)]);
      (if env.stdlib then 1 else 0), (fun () ->
        S [A "take"; A (string_of_int (rint 0 4)); gen_list env (d - 1)]);
      (if env.stdlib then 1 else 0), (fun () ->
        let x = fresh "x" in
        let env' = { env with vars = { vname = x; vty = TInt; vne = false } :: env.vars } in
        S [A "filter"; S [A "fn"; S [A x]; gen_bool env' (d - 1)]; gen_list env (d - 1)]);
    ]

let gen_of_ty env d = function
  | TInt -> gen_int env d
  | TFloat -> gen_float env d
  | TBool -> gen_bool env d
  | TStr -> gen_string env d
  | TList -> gen_list env d

let random_ty env =
  pick [
    5, (fun () -> TInt);
    2, (fun () -> TBool);
    2, (fun () -> TStr);
    1, (fun () -> TFloat);
    (if env.stdlib then 2 else 1), (fun () -> TList);
  ]

let gen_printable env d : sx =
  let ty = random_ty env in
  gen_of_ty env d ty

(* --- statements (top-level forms) --- *)

(* generate a let-binding vector plus the extended env; bindings never
   reference each other (parallel-let-safe for the tree-walker) *)
let gen_bindings env d =
  let n = rint 1 2 in
  let rec go i acc_binds acc_vars =
    if i = 0 then (List.rev acc_binds, acc_vars)
    else begin
      let ty = random_ty env in
      let x = fresh "x" in
      let e = gen_of_ty env (d - 1) ty in
      let ne = (ty = TList) && (match e with
        | S (A "list" :: _ :: _) | S (A "cons" :: _) | S (A "range" :: _) -> true
        | _ -> false) in
      go (i - 1) (V [A x; e] :: acc_binds)
        ({ vname = x; vty = ty; vne = ne } :: acc_vars)
    end
  in
  let binds, new_vars = go n [] [] in
  let vec = V (List.concat_map (function V xs -> xs | x -> [x]) binds) in
  (vec, { env with vars = new_vars @ env.vars })

let stmt_print env d = [S [A "print"; gen_printable env d]]

let stmt_let_print env d =
  let vec, env' = gen_bindings env d in
  [S [A "let"; vec; S [A "print"; gen_printable env' (d - 1)]]]

let stmt_letstar_print env d =
  (* let* IS sequential in both backends; chain bindings *)
  let a = fresh "x" and b = fresh "x" in
  let env1 = { env with vars = { vname = a; vty = TInt; vne = false } :: env.vars } in
  let env2 = { env1 with vars = { vname = b; vty = TInt; vne = false } :: env1.vars } in
  [S [A "let*";
      V [A a; gen_int env (d - 1); A b; S [A "+"; A a; gen_int env1 (d - 1)]];
      S [A "print"; gen_int env2 (d - 1)]]]

let stmt_do_print env d =
  let n = rint 2 3 in
  let inner = List.init n (fun _ -> S [A "print"; gen_printable env (d - 1)]) in
  [S (A "do" :: inner)]

let stmt_def env d =
  let f = fresh "f" in
  let arity = rint 1 3 in
  let params = List.init arity (fun _ -> fresh "p") in
  let env' = { env with vars =
    List.map (fun p -> { vname = p; vty = TInt; vne = false }) params @ env.vars } in
  let body = gen_int env' d in
  env.fns <- (f, arity, false) :: env.fns;
  [S [A "def"; S (A f :: List.map (fun p -> A p) params); body]]

let stmt_def_rec env d =
  let f = fresh "f" in
  let n = fresh "p" in
  let env' = { env with vars = { vname = n; vty = TInt; vne = false } :: env.vars } in
  let op = if flip 0.8 then "+" else "*" in
  let step = gen_int env' (min 2 (d - 1)) in
  let base = gen_int_lit () in
  let def =
    S [A "def"; S [A f; A n];
       S [A "if"; S [A "<="; A n; A "0"];
          base;
          S [A op; step; S [A f; S [A "-"; A n; A "1"]]]]] in
  let call = S [A "print"; S [A f; A (string_of_int (rint 0 12))]] in
  env.fns <- (f, 1, true) :: env.fns;
  [def; call]

let stmt_with_config env d =
  let k = fresh "k" in
  let v = gen_int_lit () in
  let body =
    S [A "print";
       S [A "+"; S [A "config"; A (":" ^ k); gen_int_lit ()]; gen_int env (d - 1)]] in
  [S [A "with-config"; C [A (":" ^ k); v]; body]]

(* ------- full-grammar statements (audit-divergence probes) ------- *)

let ty_name = function TInt -> "int" | TStr -> "string" | TBool -> "bool" | _ -> "int"

let stmt_typed_let env d =
  (* (let [x : ty e] (print x)) — D3: VM enforces, tree-walker discards *)
  let declared = [| TInt; TStr; TBool |].(Random.int 3) in
  let actual = if flip 0.6 then declared
               else [| TInt; TStr; TBool |].(Random.int 3) in
  let x = fresh "x" in
  [S [A "let"; V [A x; A ":"; A (ty_name declared); gen_of_ty env (d - 1) actual];
      S [A "print"; A x]]]

let stmt_typed_def env d =
  (* (def (f p) : ty body) then call — D3 *)
  let f = fresh "f" in
  let p = fresh "p" in
  let declared = [| TInt; TStr; TBool |].(Random.int 3) in
  let actual = if flip 0.6 then declared
               else [| TInt; TStr; TBool |].(Random.int 3) in
  let env' = { env with vars = { vname = p; vty = TInt; vne = false } :: env.vars } in
  [S [A "def"; S [A f; A p]; A ":"; A (ty_name declared); gen_of_ty env' (d - 1) actual];
   S [A "print"; S [A f; gen_int_lit ()]]]

let stmt_module env d =
  (* (import (module ...)) — D15: VM compiles only EDef children *)
  let m = fresh "m" in
  let p = fresh "p" in
  let penv = { vars = [{ vname = p; vty = TInt; vne = false }];
               fns = []; stdlib = false } in
  let def = S [A "def"; S [A m; A p]; gen_int penv (d - 1)] in
  let children =
    if flip 0.5 then [S [A "print"; gen_str_lit ()]; def]  (* non-def child: D15 *)
    else [def] in
  env.fns <- (m, 1, false) :: env.fns;
  [S [A "import"; S (A "module" :: children)];
   S [A "print"; S [A m; gen_int_lit ()]]]

let stmt_load_module env _d =
  (* (load-module "<abs stdlib>") then use a stdlib fn — D15/D20 opcode probe *)
  env.stdlib <- true;
  [S [A "load-module"; A ("\"" ^ !stdlib_path ^ "\"")];
   S [A "print"; S [A "length"; S [A "range"; A "0"; A (string_of_int (rint 1 6))]]]]

let stmt_config_computed env d =
  (* computed config key — D15: VM requires compile-time literal *)
  let k = fresh "k" in
  let klen = String.length k in
  let k1 = String.sub k 0 (klen / 2) and k2 = String.sub k (klen / 2) (klen - klen / 2) in
  [S [A "with-config"; C [A (":" ^ k); gen_int_lit ()];
      S [A "print";
         S [A "config";
            S [A "string-append"; A ("\"" ^ k1 ^ "\""); A ("\"" ^ k2 ^ "\"")];
            gen_int env (d - 1)]]]]

let stmt_perform env d =
  (* perform log with no handler: builtin logs to stderr, returns nil *)
  if flip 0.5 then [S [A "perform"; A "log"; gen_string env (d - 1)]]
  else [S [A "print"; S [A "perform"; A "log"; gen_string env (d - 1)]]]

let stmt_with_handler env d =
  (* handler over log returning an int *)
  let m = fresh "p" in
  let henv = { env with vars = { vname = m; vty = TStr; vne = false } :: env.vars } in
  let hbody =
    if flip 0.5 then gen_int henv (d - 1)
    else S [A "do"; S [A "print"; S [A "string-append"; A "\"h:\""; A m]];
            gen_int henv (d - 1)] in
  [S [A "with-handler"; V [A "log"; S [A "fn"; S [A m]; hbody]];
      S [A "print"; S [A "perform"; A "log"; gen_string env (d - 1)]]]]

let stmt_handler_leak env d =
  (* with-handler whose body ends in a tail call — D9: VM never pops the
     handler; a later perform diverges *)
  let f = fresh "f" in
  let p = fresh "p" in
  let env' = { env with vars = { vname = p; vty = TInt; vne = false } :: env.vars } in
  let m = fresh "p" in
  [S [A "def"; S [A f; A p]; gen_int env' (d - 1)];
   S [A "with-handler"; V [A "log"; S [A "fn"; S [A m]; A "77"]];
      S [A f; gen_int_lit ()]];
   S [A "print"; S [A "perform"; A "log"; gen_str_lit ()]]]

let stmt_effect env d =
  [S [A "effect"; A ":capabilities"; V [];
      S [A "do"; S [A "perform"; A "log"; gen_string env (d - 1)];
         S [A "print"; gen_int env (d - 1)]]]]

let stmt_deep_rec env _d =
  (* deep recursion — D4 stack-safety; tail and non-tail variants *)
  let f = fresh "f" in
  let n = fresh "p" in
  if flip 0.5 then begin
    let depth = [| 1000; 8000; 40000 |].(Random.int 3) in
    [S [A "def"; S [A f; A n];
        S [A "if"; S [A "<="; A n; A "0"]; A "0";
           S [A "+"; A "1"; S [A f; S [A "-"; A n; A "1"]]]]];
     S [A "print"; S [A f; A (string_of_int depth)]]]
  end else begin
    let acc = fresh "p" in
    let depth = [| 10000; 100000 |].(Random.int 2) in
    [S [A "def"; S [A f; A n; A acc];
        S [A "if"; S [A "<="; A n; A "0"]; A acc;
           S [A f; S [A "-"; A n; A "1"]; S [A "+"; A acc; A "1"]]]];
     S [A "print"; S [A f; A (string_of_int depth); A "0"]]]
  end

let stmt_big_map env _d =
  (* must not reference stdlib fns unless the load form is actually present *)
  let prelude =
    if env.stdlib then []
    else begin
      env.stdlib <- true;
      [S [A "load"; A ("\"" ^ !stdlib_path ^ "\"")]]
    end in
  let x = fresh "x" in
  let n = rint 300 2000 in
  prelude @
  [S [A "print";
      S [A "length";
         S [A "map"; S [A "fn"; S [A x]; S [A "+"; A x; A "1"]];
            S [A "range"; A "0"; A (string_of_int n)]]]]]

let stmt_eq_list env d =
  (* (= E E) with textually identical E — D7: tree-walker dedups thunks *)
  let e = gen_list_ne env (d - 1) in
  [S [A "print"; S [A "="; e; e]]]

let stmt_seq_let env d =
  (* let binding referencing a sibling — parallel (TW) vs sequential (VM) *)
  let a = fresh "x" and b = fresh "x" in
  [S [A "let"; V [A a; gen_int env (d - 1); A b; S [A "+"; A a; A "1"]];
      S [A "print"; A b]]]

let stmt_quote_special _env _d =
  (* D19: quote_to_value fails on if/let in both backends *)
  if flip 0.5 then [S [A "print"; S [A "quote"; S [A "if"; A "1"; A "2"; A "3"]]]]
  else [S [A "print"; S [A "quote"; S [A "let"; V [A "x"; A "1"]; A "x"]]]]

(* --- program generator --- *)

let load_stdlib_form () =
  S [A "load"; A ("\"" ^ !stdlib_path ^ "\"")]

let gen_program (gram : string) (iter : int) : string =
  Random.full_init [| !seed; iter |];
  name_counter := 0;
  let env = { vars = []; fns = []; stdlib = false } in
  let forms = ref [] in
  let emit fs = forms := !forms @ fs in
  if flip 0.7 then begin env.stdlib <- true; emit [load_stdlib_form ()] end;
  let d = !max_depth in
  let core_stmts = [
    6, (fun () -> stmt_print env d);
    3, (fun () -> stmt_let_print env d);
    2, (fun () -> stmt_letstar_print env d);
    2, (fun () -> stmt_do_print env d);
    3, (fun () -> stmt_def env d);
    2, (fun () -> stmt_def_rec env d);
    2, (fun () -> stmt_with_config env d);
  ] in
  let full_stmts = core_stmts @ [
    2, (fun () -> stmt_typed_let env d);
    2, (fun () -> stmt_typed_def env d);
    2, (fun () -> stmt_module env d);
    1, (fun () -> stmt_load_module env d);
    1, (fun () -> stmt_config_computed env d);
    2, (fun () -> stmt_perform env d);
    2, (fun () -> stmt_with_handler env d);
    1, (fun () -> stmt_handler_leak env d);
    2, (fun () -> stmt_effect env d);
    1, (fun () -> stmt_deep_rec env d);
    1, (fun () -> stmt_big_map env d);
    1, (fun () -> stmt_eq_list env d);
    1, (fun () -> stmt_seq_let env d);
    1, (fun () -> stmt_quote_special env d);
  ] in
  let table = if gram = "full" then full_stmts else core_stmts in
  let n_stmts = rint 2 5 in
  for _ = 1 to n_stmts do emit (pick table) done;
  (* guarantee at least one observable print *)
  if not (List.exists (function
      | S (A "print" :: _) -> true
      | S (A ("let" | "let*" | "with-config" | "with-handler" | "effect") :: _) -> true
      | S (A "do" :: _) -> true
      | _ -> false) !forms)
  then emit (stmt_print env d);
  render_program !forms

(* ---------------------------------------------------- Subprocess runner -- *)

type outcome = {
  status : [ `Exit of int | `Signal of int | `Timeout ];
  out : string;
  err : string;
}

let read_file path =
  try
    let ch = open_in_bin path in
    let n = in_channel_length ch in
    let s = really_input_string ch n in
    close_in ch; s
  with _ -> ""

let devnull = lazy (Unix.openfile "/dev/null" [Unix.O_RDONLY] 0)

let tmp_out = lazy (Filename.temp_file "ppfuzz" ".out")
let tmp_err = lazy (Filename.temp_file "ppfuzz" ".err")

let run_backend (args : string list) (file : string) : outcome =
  let out_f = Lazy.force tmp_out and err_f = Lazy.force tmp_err in
  let fd_out = Unix.openfile out_f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let fd_err = Unix.openfile err_f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let argv = Array.of_list (!pp_bin :: args @ [file]) in
  let pid =
    try Unix.create_process !pp_bin argv (Lazy.force devnull) fd_out fd_err
    with Unix.Unix_error (e, _, _) ->
      Unix.close fd_out; Unix.close fd_err;
      prerr_endline ("fatal: cannot execute " ^ !pp_bin ^ ": " ^ Unix.error_message e);
      exit 2
  in
  Unix.close fd_out; Unix.close fd_err;
  let deadline = Unix.gettimeofday () +. float_of_int !timeout_ms /. 1000.0 in
  let rec wait () =
    let (p, st) = Unix.waitpid [Unix.WNOHANG] pid in
    if p = 0 then begin
      if Unix.gettimeofday () > deadline then begin
        (try Unix.kill pid Sys.sigkill with _ -> ());
        ignore (Unix.waitpid [] pid);
        `Timeout
      end else begin
        Unix.sleepf 0.002;
        wait ()
      end
    end else
      match st with
      | Unix.WEXITED n -> `Exit n
      | Unix.WSIGNALED s | Unix.WSTOPPED s -> `Signal s
  in
  let status = wait () in
  { status; out = read_file out_f; err = read_file err_f }

(* ------------------------------------------------------------ Verdicts -- *)

type verdict =
  | Pass
  | Mismatch of string   (* signature *)
  | BothError of string  (* signature *)
  | Crash of string      (* signature *)

(* normalize for signature grouping: quoted strings -> "S", digit runs -> #,
   newlines -> spaces, cap length.  Aggressive on purpose: signatures should
   count BUG CLASSES, not distinct payloads. *)
let norm ?(max_len = 48) s =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  let last_hash = ref false in
  while !i < n do
    let c = s.[!i] in
    if c = '"' || (c = '\\' && !i + 1 < n && s.[!i + 1] = '"') then begin
      (* skip a quoted span, possibly backslash-escaped; emit a placeholder *)
      let esc = c = '\\' in
      i := !i + (if esc then 2 else 1);
      let closed = ref false in
      while not !closed && !i < n do
        if esc && s.[!i] = '\\' && !i + 1 < n && s.[!i + 1] = '"' then begin
          i := !i + 2; closed := true
        end else if (not esc) && s.[!i] = '"' then begin
          incr i; closed := true
        end else incr i
      done;
      Buffer.add_string b "\"S\"";
      last_hash := false
    end else begin
      if c >= '0' && c <= '9' then begin
        if not !last_hash then Buffer.add_char b '#';
        last_hash := true
      end else begin
        last_hash := false;
        if c = '\n' then Buffer.add_char b ' ' else Buffer.add_char b c
      end;
      incr i
    end
  done;
  let s = Buffer.contents b in
  if String.length s > max_len then String.sub s 0 max_len else s

(* extract a stable error tag from stderr *)
let error_tag (err : string) : string =
  let lines = String.split_on_char '\n' err in
  let fatal =
    List.fold_left (fun acc l ->
      let prefix = "Fatal error: exception " in
      if String.length l > String.length prefix
         && String.sub l 0 (String.length prefix) = prefix
      then Some (String.sub l (String.length prefix)
                   (String.length l - String.length prefix))
      else acc) None lines
  in
  match fatal with
  | None -> "no-fatal-line"
  | Some rest ->
      (* Failure("msg") — pull out msg, strip nested builtin wrappers *)
      let msg =
        if String.length rest > 9 && String.sub rest 0 9 = "Failure(\"" then begin
          let inner = String.sub rest 9 (String.length rest - 9) in
          let inner =
            match String.rindex_opt inner '"' with
            | Some i -> String.sub inner 0 i
            | None -> inner in
          (* repeatedly strip "builtin 'X' failed: " *)
          let rec strip s =
            let pfx = "builtin '" in
            if String.length s > String.length pfx
               && String.sub s 0 (String.length pfx) = pfx then
              match String.index_opt s ':' with
              | Some i when i + 2 <= String.length s ->
                  strip (String.sub s (i + 2) (String.length s - i - 2))
              | _ -> s
            else s
          in
          let m = strip inner in
          (* drop value payloads: "type mismatch: expected int, got false"
             and friends group by the ", got"-free prefix *)
          let m =
            let pat = ", got " in
            let rec find i =
              if i + String.length pat > String.length m then None
              else if String.sub m i (String.length pat) = pat then Some i
              else find (i + 1) in
            match find 0 with
            | Some i -> String.sub m 0 i ^ ", got _"
            | None -> m in
          "Failure:" ^ m
        end else
          (* non-Failure exception: keep constructor name only *)
          (match String.index_opt rest '(' with
           | Some i -> String.sub rest 0 i
           | None -> rest)
      in
      norm msg

let first_diff_lines a b =
  let la = String.split_on_char '\n' a and lb = String.split_on_char '\n' b in
  let rec go la lb =
    match la, lb with
    | [], [] -> ("", "")
    | x :: ra, y :: rb -> if x = y then go ra rb else (x, y)
    | x :: _, [] -> (x, "<eof>")
    | [], y :: _ -> ("<eof>", y)
  in
  go la lb

let judge (tw : outcome) (bc : outcome) : verdict =
  let crash_of side o =
    match o.status with
    | `Timeout -> Some (Printf.sprintf "crash:%s:timeout" side)
    | `Signal s -> Some (Printf.sprintf "crash:%s:signal-%d" side s)
    | `Exit n when n > 128 -> Some (Printf.sprintf "crash:%s:exit-%d" side n)
    | _ -> None
  in
  match crash_of "tw" tw, crash_of "bc" bc with
  | Some s, _ | _, Some s -> Crash s
  | None, None ->
      let tw_ok = tw.status = `Exit 0 and bc_ok = bc.status = `Exit 0 in
      if tw_ok && bc_ok then begin
        if tw.out <> bc.out then
          let (a, b) = first_diff_lines tw.out bc.out in
          Mismatch ("outdiff:" ^ norm ~max_len:28 a ^ "|" ^ norm ~max_len:28 b)
        else if tw.err <> bc.err then
          let (a, b) = first_diff_lines tw.err bc.err in
          Mismatch ("logdiff:" ^ norm ~max_len:28 a ^ "|" ^ norm ~max_len:28 b)
        else Pass
      end
      else if tw_ok && not bc_ok then
        Mismatch ("exitdiff:bc-err:" ^ error_tag bc.err)
      else if bc_ok && not tw_ok then
        Mismatch ("exitdiff:tw-err:" ^ error_tag tw.err)
      else
        (* both non-zero: soft class; group by error tags *)
        let ta = error_tag tw.err and tb = error_tag bc.err in
        if ta = tb then BothError ("both-error:same:" ^ ta)
        else BothError ("both-error:" ^ ta ^ "|" ^ tb)

let sig_of_verdict = function
  | Pass -> None
  | Mismatch s | BothError s | Crash s -> Some s

(* -------------------------------------------------------------- Shrink -- *)

(* Since gen_program renders directly, the shrinker works on a re-parsed sx
   tree of the rendered program.  Tiny parser for our OWN rendered output;
   atoms are whitespace-delimited and generated string literals never contain
   quotes, backslashes, or brackets. *)

let parse_program (src : string) : sx list =
  let n = String.length src in
  let pos = ref 0 in
  let peek () = if !pos < n then Some src.[!pos] else None in
  let rec skip_ws () =
    match peek () with
    | Some (' ' | '\n' | '\t') -> incr pos; skip_ws ()
    | _ -> ()
  in
  let rec parse_one () : sx =
    skip_ws ();
    match peek () with
    | Some '(' -> incr pos; S (parse_seq ')')
    | Some '[' -> incr pos; V (parse_seq ']')
    | Some '{' -> incr pos; C (parse_seq '}')
    | Some '"' ->
        let start = !pos in
        incr pos;
        while !pos < n && src.[!pos] <> '"' do incr pos done;
        incr pos;
        A (String.sub src start (!pos - start))
    | Some _ ->
        let start = !pos in
        let stop c = c = ' ' || c = '\n' || c = '\t' || c = '(' || c = ')'
                     || c = '[' || c = ']' || c = '{' || c = '}' in
        while !pos < n && not (stop src.[!pos]) do incr pos done;
        A (String.sub src start (!pos - start))
    | None -> failwith "parse_program: eof"
  and parse_seq close =
    skip_ws ();
    match peek () with
    | Some c when c = close -> incr pos; []
    | Some _ -> let x = parse_one () in x :: parse_seq close
    | None -> failwith "parse_program: unterminated"
  in
  let rec top () =
    skip_ws ();
    if !pos >= n then [] else let x = parse_one () in x :: top ()
  in
  top ()

(* enumerate node count; replace node #target (preorder, roots first) *)
let rec count_nodes sx =
  match sx with
  | A _ -> 1
  | S xs | V xs | C xs -> 1 + List.fold_left (fun a x -> a + count_nodes x) 0 xs

let replace_node (sx : sx) (target : int) (repl : sx) : sx =
  let idx = ref (-1) in
  let rec go sx =
    incr idx;
    if !idx = target then repl
    else match sx with
      | A _ -> sx
      | S xs -> S (List.map go xs)
      | V xs -> V (List.map go xs)
      | C xs -> C (List.map go xs)
  in
  go sx

let node_at (sx : sx) (target : int) : sx =
  let idx = ref (-1) in
  let found = ref None in
  let rec go sx =
    incr idx;
    if !idx = target then found := Some sx;
    (match sx with
     | A _ -> ()
     | S xs | V xs | C xs -> List.iter go xs)
  in
  go sx;
  match !found with Some x -> x | None -> A "?"

let prog_size forms = String.length (render_program forms)

(* candidate reductions for a program, in decreasing aggressiveness *)
let shrink_candidates (forms : sx list) : sx list list =
  let cands = ref [] in
  let add c = cands := c :: !cands in
  let nf = List.length forms in
  (* 1. drop a top-level form *)
  if nf > 1 then
    for i = 0 to nf - 1 do
      add (List.filteri (fun j _ -> j <> i) forms)
    done;
  (* 2. hoist a child over its parent; 3. replace subtree with a literal *)
  List.iteri (fun fi form ->
    let n = count_nodes form in
    for node_i = 1 to n - 1 do        (* skip the root of the form itself *)
      (match node_at form node_i with
       | S (_ :: args) when args <> [] ->
           List.iter (fun arg ->
             add (List.mapi (fun j f ->
               if j = fi then replace_node f node_i arg else f) forms)
           ) args
       | _ -> ());
      (match node_at form node_i with
       | A a ->
           (* shrink integer atoms *)
           (match int_of_string_opt a with
            | Some v when v <> 0 && v <> 1 ->
                let v' = if abs v > 4 then v / 2 else (if v > 0 then v - 1 else v + 1) in
                add (List.mapi (fun j f ->
                  if j = fi then replace_node f node_i (A (string_of_int v')) else f) forms)
            | _ -> ())
       | _ ->
           List.iter (fun r ->
             add (List.mapi (fun j f ->
               if j = fi then replace_node f node_i r else f) forms))
             [A "0"; A "1"; A "true"; A "nil"; A "\"a\""])
    done
  ) forms;
  List.rev !cands

let prog_file = lazy (Filename.temp_file "ppfuzz" ".pp")

let run_both (src : string) : outcome * outcome =
  let f = Lazy.force prog_file in
  let ch = open_out f in
  output_string ch src; close_out ch;
  let tw = run_backend [] f in
  let bc = run_backend ["--bytecode"] f in
  (tw, bc)

let shrink (src : string) (signature : string) : string =
  let execs = ref 0 in
  let same_sig forms =
    if !execs >= !shrink_budget then false
    else begin
      incr execs;
      let (tw, bc) = run_both (render_program forms) in
      sig_of_verdict (judge tw bc) = Some signature
    end
  in
  let rec fixpoint forms =
    if !execs >= !shrink_budget then forms
    else begin
      let size0 = prog_size forms in
      let better =
        List.find_opt (fun c -> prog_size c < size0 && same_sig c)
          (shrink_candidates forms)
      in
      match better with
      | Some c -> fixpoint c
      | None -> forms
    end
  in
  try render_program (fixpoint (parse_program src))
  with _ -> src   (* shrinker must never lose the repro *)

(* ---------------------------------------------------------------- Main -- *)

let sanitize_sig s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
       || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
    then Buffer.add_char b c
    else Buffer.add_char b '_') s;
  let s = Buffer.contents b in
  let s = if String.length s > 70 then String.sub s 0 70 else s in
  s ^ "-" ^ Printf.sprintf "%08x" (Hashtbl.hash s land 0xffffffff)

let mkdir_p dir =
  let rec go d =
    if d <> "" && d <> "." && d <> "/" && not (Sys.file_exists d) then begin
      go (Filename.dirname d);
      (try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  go dir

let outcome_to_string (o : outcome) : string =
  let st = match o.status with
    | `Exit n -> Printf.sprintf "exit %d" n
    | `Signal s -> Printf.sprintf "signal %d" s
    | `Timeout -> "timeout" in
  Printf.sprintf "status: %s\n--- stdout ---\n%s--- stderr ---\n%s" st o.out o.err

let write_file path content =
  let ch = open_out path in output_string ch content; close_out ch

type sig_info = {
  mutable n_hits : int;
  mutable examples : int;    (* how many example programs saved *)
  kind : [ `Mismatch | `BothError | `Crash ];
  first_iter : int;
  mutable min_repro : string;
}

let () =
  parse_cli ();
  if !dump_iter >= 0 then begin
    print_string (gen_program !grammar !dump_iter);
    exit 0
  end;
  let sigs : (string, sig_info) Hashtbl.t = Hashtbl.create 64 in
  let n_pass = ref 0 and n_mismatch = ref 0 and n_both = ref 0 and n_crash = ref 0 in
  Printf.printf "pp-fuzz: grammar=%s seed=%d start=%d count=%d depth=%d timeout=%dms pp=%s\n%!"
    !grammar !seed !start_iter !count !max_depth !timeout_ms !pp_bin;
  for i = !start_iter to !start_iter + !count - 1 do
    let src = gen_program !grammar i in
    let (tw, bc) = run_both src in
    let v = judge tw bc in
    (match v with
     | Pass -> incr n_pass
     | Mismatch _ -> incr n_mismatch
     | BothError _ -> incr n_both
     | Crash _ -> incr n_crash);
    (match sig_of_verdict v with
     | None -> ()
     | Some s ->
         let kind = (match v with
           | Mismatch _ -> `Mismatch | BothError _ -> `BothError
           | Crash _ -> `Crash | Pass -> assert false) in
         let info =
           match Hashtbl.find_opt sigs s with
           | Some info -> info.n_hits <- info.n_hits + 1; info
           | None ->
               let info = { n_hits = 1; examples = 0; kind; first_iter = i;
                            min_repro = "" } in
               Hashtbl.add sigs s info;
               Printf.printf "[iter %d] NEW %s signature: %s\n%!" i
                 (match kind with `Mismatch -> "MISMATCH"
                                | `BothError -> "BOTH-ERROR"
                                | `Crash -> "CRASH") s;
               info
         in
         let dir = Filename.concat !out_dir (sanitize_sig s) in
         mkdir_p dir;
         if info.examples < 3 then begin
           info.examples <- info.examples + 1;
           write_file (Filename.concat dir (Printf.sprintf "%d.pp" i)) src;
           write_file (Filename.concat dir (Printf.sprintf "%d.tw.out" i))
             (outcome_to_string tw);
           write_file (Filename.concat dir (Printf.sprintf "%d.bc.out" i))
             (outcome_to_string bc)
         end;
         (* shrink only the first exemplar of a signature; both-error is a
            soft class — shrink mismatches and crashes only *)
         if info.n_hits = 1 && kind <> `BothError then begin
           let small = shrink src s in
           info.min_repro <- small;
           write_file (Filename.concat dir "min.pp") small;
           let (tw', bc') = run_both small in
           write_file (Filename.concat dir "min.tw.out") (outcome_to_string tw');
           write_file (Filename.concat dir "min.bc.out") (outcome_to_string bc')
         end);
    let done_n = i - !start_iter + 1 in
    if done_n mod 200 = 0 then
      Printf.printf "  ... %d/%d  pass=%d mismatch=%d both-error=%d crash=%d distinct-sigs=%d\n%!"
        done_n !count !n_pass !n_mismatch !n_both !n_crash (Hashtbl.length sigs)
  done;
  Printf.printf "\n==== pp-fuzz summary (grammar=%s, seed=%d, count=%d) ====\n"
    !grammar !seed !count;
  Printf.printf "PASS       %d\nMISMATCH   %d\nBOTH-ERROR %d\nCRASH      %d\n"
    !n_pass !n_mismatch !n_both !n_crash;
  Printf.printf "distinct signatures: %d\n" (Hashtbl.length sigs);
  let sorted =
    Hashtbl.fold (fun s info acc -> (s, info) :: acc) sigs []
    |> List.sort (fun (_, a) (_, b) -> compare b.n_hits a.n_hits) in
  List.iter (fun (s, info) ->
    Printf.printf "\n[%s] x%d (first at iter %d)\n  %s\n  dir: %s\n"
      (match info.kind with `Mismatch -> "MISMATCH"
                          | `BothError -> "BOTH-ERROR" | `Crash -> "CRASH")
      info.n_hits info.first_iter s
      (Filename.concat !out_dir (sanitize_sig s));
    if info.min_repro <> "" && String.length info.min_repro < 400 then begin
      Printf.printf "  min repro:\n";
      List.iter (fun l -> if l <> "" then Printf.printf "    %s\n" l)
        (String.split_on_char '\n' info.min_repro)
    end
  ) sorted;
  (* CI verdict: BOTH-ERROR is whitelisted (soft class) for now *)
  if !n_mismatch > 0 || !n_crash > 0 then begin
    Printf.printf "\nRESULT: FAIL (%d mismatches, %d crashes)\n" !n_mismatch !n_crash;
    exit 1
  end else begin
    Printf.printf "\nRESULT: OK (no mismatches or crashes; %d matched-error programs)\n"
      !n_both;
    exit 0
  end
