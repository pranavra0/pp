open Pp_runtime
open Pp_kernel
open Source_error
type fmt_target = To_braces | To_sexpr

type t = {
  command_argv : string list;
  program_argv : string list;
  files : string list;
  grants : string list;
  eval_string : string option;
  reconcile_root : string option;
  supervise : bool;
  member_name : string option;
  desired_object : (string * string) option;
  publish_object_root : string option;
  watch : bool;
  watch_interval : float;
  stabilize : bool;
  schedule_policy : Scheduler.policy;
  fenced_policy : Invocation.fenced_policy;
  gc_keep_epochs : int;
  gc_grace_seconds : float;
  gc : bool;
  gc_mark_out : string option;
  update_islands : bool;
  fetch_islands : bool;
  pin_file : string option;
  dump_pins_file : string option;
  emit_braces_file : string option;
  roundtrip_braces_file : string option;
  fmt : (fmt_target * string * bool) option;
  compare_hash : (string * string) option;
  list_comments : ([ `Sexpr | `Brace ] * string) option;
  why : bool;
  no_cache : bool;
  check : bool;
  graph : bool;
  lint_file : string option;
  island_pins : string option;
  cluster_init : bool;
  mint_token : (string * int) option;
  transport_push : (string * string * string) option;
  transport_pull : (string * string * string) option;
  serve_hit : (string * string * string * string) option;
  recv_hit : (string * string) option;
  remote_node : (string * string * string * string * string) option;
  check_kernel_props : (int * int) option;
  version : bool;
  help : bool;
  dump_surface_tables : bool;
  dump_builtins : bool;
}

type flag = {
  name : string;
  doc : string;
  internal : bool;
  handler : string list -> string list;
}

type raw = {
  command_argv : string list;
  program_argv : string list ref;
  files : string list ref;
  grants : string list ref;
  eval_string : string option ref;
  reconcile_root : string option ref;
  supervise : bool ref;
  member_name : string option ref;
  desired_object : (string * string) option ref;
  publish_object_root : string option ref;
  watch : bool ref;
  watch_interval : string ref;
  stabilize : bool ref;
  schedule : string ref;
  fenced_policy : string ref;
  gc_keep_epochs : string ref;
  gc_grace_seconds : string ref;
  gc : bool ref;
  gc_mark_out : string option ref;
  update_islands : bool ref;
  fetch_islands : bool ref;
  pin_file : string option ref;
  dump_pins_file : string option ref;
  emit_braces_file : string option ref;
  roundtrip_braces_file : string option ref;
  fmt : (fmt_target * string * bool) option ref;
  compare_hash : (string * string) option ref;
  list_comments : ([ `Sexpr | `Brace ] * string) option ref;
  why : bool ref;
  no_cache : bool ref;
  check : bool ref;
  graph : bool ref;
  lint_file : string option ref;
  island_pins : string option ref;
  cluster_init : bool ref;
  mint_token : (string * int) option ref;
  transport_push : (string * string * string) option ref;
  transport_pull : (string * string * string) option ref;
  serve_hit : (string * string * string * string) option ref;
  recv_hit : (string * string) option ref;
  remote_node : (string * string * string * string * string) option ref;
  check_kernel_props : (int * int) option ref;
  version : bool ref;
  help : bool ref;
  dump_surface_tables : bool ref;
  dump_builtins : bool ref;
}

let new_raw command_argv = {
  command_argv; program_argv = ref []; files = ref []; grants = ref [];
  eval_string = ref None; reconcile_root = ref None; supervise = ref false;
  member_name = ref None; desired_object = ref None;
  publish_object_root = ref None; watch = ref false;
  watch_interval = ref "1.0"; stabilize = ref false; schedule = ref "serial";
  fenced_policy = ref "abort"; gc_keep_epochs = ref "5";
  gc_grace_seconds = ref (string_of_float Store_gc.default_grace_seconds);
  gc = ref false; gc_mark_out = ref None; update_islands = ref false;
  fetch_islands = ref false; pin_file = ref None;
  dump_pins_file = ref None; emit_braces_file = ref None;
  roundtrip_braces_file = ref None; fmt = ref None; compare_hash = ref None;
  list_comments = ref None; why = ref false; no_cache = ref false;
  check = ref false; graph = ref false; lint_file = ref None;
  island_pins = ref None; cluster_init = ref false; mint_token = ref None;
  transport_push = ref None; transport_pull = ref None; serve_hit = ref None;
  recv_hit = ref None; remote_node = ref None;
  check_kernel_props = ref None; version = ref false;
  help = ref false;
  dump_surface_tables = ref false; dump_builtins = ref false;
}

let flag name f = { name; doc = ""; internal = true; handler = fun rest -> f (); rest }
let opt1 name f =
  { name; doc = ""; internal = true;
    handler = function
      | a :: rest -> f a; rest
      | [] -> command (name ^ " requires one argument") }
let doc_of doc flag = { flag with doc; internal = false }
let opt2 name f =
  { name; doc = ""; internal = true;
    handler = function
      | a :: b :: rest -> f a b; rest
      | _ -> command (name ^ " requires two arguments") }
let opt3 name f =
  { name; doc = ""; internal = true;
    handler = function
      | a :: b :: c :: rest -> f a b c; rest
      | _ -> command (name ^ " requires three arguments") }
let opt4 name f =
  { name; doc = ""; internal = true;
    handler = function
      | a :: b :: c :: d :: rest -> f a b c d; rest
      | _ -> command (name ^ " requires four arguments") }
let opt5 name f =
  { name; doc = ""; internal = true;
    handler = function
      | a :: b :: c :: d :: e :: rest -> f a b c d e; rest
      | _ -> command (name ^ " requires five arguments") }

let parse_fmt raw rest =
  let to_braces = ref None and to_sexpr = ref None and in_place = ref false in
  let rec loop = function
    | "--to-braces" :: file :: more -> to_braces := Some file; loop more
    | "--to-sexpr" :: file :: more -> to_sexpr := Some file; loop more
    | ("-i" | "--in-place") :: more -> in_place := true; loop more
    | [] -> ()
    | bad :: _ -> command ("pp fmt: unrecognized argument: " ^ bad)
  in
  loop rest;
  raw.fmt := (match !to_braces, !to_sexpr with
    | Some file, None -> Some (To_braces, file, !in_place)
    | None, Some file -> Some (To_sexpr, file, !in_place)
    | _ -> command "pp fmt: specify exactly one of --to-braces or --to-sexpr");
  []

let parse_kernel_props raw rest =
  let seed = ref 1 and count = ref 3000 in
  let rec loop = function
    | "--seed" :: n :: more ->
        seed := (match int_of_string_opt n with
          | Some value -> value | None -> command ("invalid --kernel-props seed: " ^ n));
        loop more
    | "--count" :: n :: more ->
        count := (match int_of_string_opt n with
          | Some value -> value | None -> command ("invalid --kernel-props count: " ^ n));
        loop more
    | _ -> ()
  in
  loop rest;
  raw.check_kernel_props := Some (!seed, !count);
  []

let flags raw =
  let set_fenced value = raw.fenced_policy := value in
  let set_schedule spec = raw.schedule := spec in
  [
    { name = "--"; doc = ""; internal = true; handler = fun rest -> raw.program_argv := rest; [] };
    doc_of "  pp --update <file.pp>     Re-resolve islands and rewrite inline pins (implies --fetch-islands)\n"
      (flag "--update" (fun () -> raw.update_islands := true; raw.fetch_islands := true));
    doc_of "  pp --fetch-islands        Allow git fetch for uncached island pins (default: off)\n"
      (flag "--fetch-islands" (fun () -> raw.fetch_islands := true));
    doc_of "  pp --schedule serial|parallel:N|race:N|remote:MEMBER  Node-miss dispatch policy (default: serial); remote:<member> places misses on a cluster member (members: ~/.pp/cluster/members or $PP_CLUSTER_MEMBERS)\n"
      (opt1 "--schedule" set_schedule);
    doc_of "  pp island-pins <file.pp>  List island forms with pin and cache status\n"
      (opt1 "island-pins" (fun f -> raw.island_pins := Some f));
    doc_of "  pp --grant <spec>        Grant capability (fs:/path:rw, net:host[:port], secret:/path, process)\n"
      (opt1 "--grant" (fun g -> raw.grants := g :: !(raw.grants)));
    doc_of "  pp cluster-init          Mint ~/.pp/cluster/{secret,id} (the cluster trust anchor)\n"
      (flag "cluster-init" (fun () -> raw.cluster_init := true));
    doc_of "  pp --mint-token <out> <ttl-secs> [--grant ...]  Mint a signed cluster token\n"
      (opt2 "--mint-token" (fun out ttl ->
        raw.mint_token := Some (out, match int_of_string_opt ttl with
          | Some n -> n | None -> command ("invalid --mint-token ttl-seconds: " ^ ttl))));
    doc_of "  pp --transport-push/--transport-pull object|blob|trace <id> <root>  Local-dir sync (internal)\n"
      (opt3 "--transport-push" (fun k id root -> raw.transport_push := Some (k, id, root)));
    { (opt3 "--transport-pull" (fun k id root -> raw.transport_pull := Some (k, id, root))) with internal = true };
    doc_of "  pp --serve-hit <key> <token-file> <shared-root> <reply-file>  Capability-gated hit (internal)\n"
      (opt4 "--serve-hit" (fun k token root reply -> raw.serve_hit := Some (k, token, root, reply)));
    doc_of "  pp --recv-hit <reply-file> <shared-root>  Ingest a serve-hit reply (internal)\n"
      (opt2 "--recv-hit" (fun reply root -> raw.recv_hit := Some (reply, root)));
    doc_of "  pp --remote-node <token> <pins> <root> <keys> <reply>  Cluster-member side of remote placement (internal)\n"
      (opt5 "--remote-node" (fun token pins root keys reply -> raw.remote_node := Some (token, pins, root, keys, reply)));
    doc_of "  pp --reconcile <root>    Materialize the program's map value under <root>\n"
      (opt1 "--reconcile" (fun root -> raw.reconcile_root := Some root));
    doc_of "  pp --supervise <file.pp>  Reconcile program's process-map value (use with --watch)\n"
      (flag "--supervise" (fun () -> raw.supervise := true));
    doc_of "  pp --member-name <n> [--reconcile/--supervise] <file>  Host-qualified domain distribution: converge only desired[<n>]'s slice\n"
      (opt1 "--member-name" (fun n -> raw.member_name := Some n));
    doc_of "  pp --desired-object <hash> <shared-root> [--member-name <n>] [flags]  Pull a published desired-state value by hash and converge it (never runs a program to derive it)\n"
      (opt2 "--desired-object" (fun h root -> raw.desired_object := Some (h, root)));
    doc_of "  pp --publish-object <shared-root> <file>  Publish the program's value (+ its blob: refs) to a shared local-dir store, by hash\n"
      (opt1 "--publish-object" (fun root -> raw.publish_object_root := Some root));
    opt1 "--gc-mark" (fun out -> raw.gc_mark_out := Some out);
    doc_of "  pp gc [--gc-keep-epochs N] [--gc-grace-seconds S]  Explicit store GC: mark-by-replay the last N reconcile/supervise epochs, sweep the rest\n"
      (flag "gc" (fun () -> raw.gc := true));
    opt1 "--gc-keep-epochs" (fun n -> raw.gc_keep_epochs := n);
    opt1 "--gc-grace-seconds" (fun n -> raw.gc_grace_seconds := n);
    doc_of "  pp --pin-file <path> <file.pp>  Preseed file and probe observations from a pin file before running\n"
      (opt1 "--pin-file" (fun p -> raw.pin_file := Some p));
    doc_of "  pp --dump-pins <path> <file.pp>  After running, write every run_pins/probe_values entry as (pin ...)/(pin-probe ...) lines to <path>\n"
      (opt1 "--dump-pins" (fun p -> raw.dump_pins_file := Some p));
    doc_of "  pp --emit-braces <file.ppl>  Print a sexpr (.ppl) file as brace-surface text (.pp/.ppb are brace surface, .ppl is the sexpr/AST surface)\n"
      (opt1 "--emit-braces" (fun f -> raw.emit_braces_file := Some f));
    doc_of "  pp --roundtrip-braces <file.ppl>  Assert sexpr->braces->re-read AST + hash equality (the fuzz gate)\n"
      (opt1 "--roundtrip-braces" (fun f -> raw.roundtrip_braces_file := Some f));
    doc_of "  pp fmt --to-braces <file> [-i]  Transpile sexpr source to brace source, carrying comments (-i/--in-place rewrites the file, same path)\n  pp fmt --to-sexpr <file> [-i]   Transpile brace source to sexpr source, carrying comments\n"
      ({ name = "fmt"; doc = ""; internal = false; handler = parse_fmt raw });
    { (opt2 "--compare-hash" (fun a b -> raw.compare_hash := Some (a, b))) with internal = true };
    { (opt2 "--list-comments" (fun surface file ->
        raw.list_comments := Some ((match surface with "sexpr" -> `Sexpr | "brace" -> `Brace | _ -> command "--list-comments requires sexpr|brace <file>"), file))) with internal = true };
    doc_of "  pp --fenced-policy retry|abort|ask  Unknown-status fenced-action policy (default: abort)\n"
      (opt1 "--fenced-policy" set_fenced);
    doc_of "  pp why <file.pp>         Explain node cache hits/misses (capability-filtered)\n"
      (flag "why" (fun () -> raw.why := true));
    { (flag "--why" (fun () -> raw.why := true)) with internal = true };
    doc_of "  pp --no-cache <file.pp>  Skip cache reads (recompute); results still stored\n"
      (flag "--no-cache" (fun () -> raw.no_cache := true));
    doc_of "  pp --check <file.pp>     Determinism audit: run each node twice, flag volatile\n"
      (flag "--check" (fun () -> raw.check := true));
    doc_of "  pp -e '<expr>'           Evaluate an expression (brace syntax, like the REPL)\n"
      (opt1 "-e" (fun e -> raw.eval_string := Some e));
    doc_of "  pp --version             Print version\n"
      (flag "--version" (fun () -> raw.version := true));
    { (flag "-v" (fun () -> raw.version := true)) with internal = true };
    flag "--dump-surface-tables" (fun () -> raw.dump_surface_tables := true);
    flag "--dump-builtins" (fun () -> raw.dump_builtins := true);
    { name = "--check-kernel-props"; doc = ""; internal = true; handler = parse_kernel_props raw };
    doc_of "  pp --help                Print this help\n"
      (flag "--help" (fun () -> raw.help := true));
    { (flag "-h" (fun () -> ())) with internal = true };
    doc_of "  pp --once <file.pp>        Run once and exit (explicit; default behavior)\n"
      (flag "--once" (fun () -> ()));
    doc_of "  pp --watch <file.pp>       Run, then watch cell changes and re-evaluate\n  pp --watch --stabilize <file>  Watch with push stabilize (dirty-propagation)\n"
      (flag "--watch" (fun () -> raw.watch := true));
    doc_of "  pp --watch-interval <s>   Poll interval for --watch (default 1.0)\n"
      (opt1 "--watch-interval" (fun n -> raw.watch_interval := n));
    flag "--stabilize" (fun () -> raw.stabilize := true);
    doc_of "  pp graph                  Print the cell->node dependency graph from traces\n"
      (flag "graph" (fun () -> raw.graph := true));
    doc_of "  pp lint <file.pp>         Check source file for naming/style convention violations\n"
      (opt1 "lint" (fun f -> raw.lint_file := Some f));
    doc_of "  pp run <file>            Run a pp source file\n"
      (opt1 "run" (fun f -> raw.files := f :: !(raw.files)));
  ]

let validated raw =
  let policy = Cli_validation.schedule !(raw.schedule) in
  let fenced_policy = Cli_validation.fenced_policy !(raw.fenced_policy) in
  let interval = Cli_validation.nonnegative_float
      ~option_name:"--watch-interval" !(raw.watch_interval) in
  let keep = Cli_validation.positive_int
      ~option_name:"--gc-keep-epochs" !(raw.gc_keep_epochs) in
  let grace = Cli_validation.nonnegative_float
      ~option_name:"--gc-grace-seconds" !(raw.gc_grace_seconds) in
  { command_argv = raw.command_argv; program_argv = !(raw.program_argv);
    files = List.rev !(raw.files); grants = List.rev !(raw.grants);
    eval_string = !(raw.eval_string); reconcile_root = !(raw.reconcile_root);
    supervise = !(raw.supervise); member_name = !(raw.member_name);
    desired_object = !(raw.desired_object); publish_object_root = !(raw.publish_object_root);
    watch = !(raw.watch); watch_interval = interval; stabilize = !(raw.stabilize);
    schedule_policy = policy; fenced_policy; gc_keep_epochs = keep;
    gc_grace_seconds = grace; gc = !(raw.gc); gc_mark_out = !(raw.gc_mark_out);
    update_islands = !(raw.update_islands); fetch_islands = !(raw.fetch_islands);
    pin_file = !(raw.pin_file);
    dump_pins_file = !(raw.dump_pins_file); emit_braces_file = !(raw.emit_braces_file);
    roundtrip_braces_file = !(raw.roundtrip_braces_file); fmt = !(raw.fmt);
    compare_hash = !(raw.compare_hash); list_comments = !(raw.list_comments);
    why = !(raw.why); no_cache = !(raw.no_cache); check = !(raw.check);
    graph = !(raw.graph); lint_file = !(raw.lint_file);
    island_pins = !(raw.island_pins); cluster_init = !(raw.cluster_init);
    mint_token = !(raw.mint_token); transport_push = !(raw.transport_push);
    transport_pull = !(raw.transport_pull); serve_hit = !(raw.serve_hit);
    recv_hit = !(raw.recv_hit); remote_node = !(raw.remote_node);
    check_kernel_props = !(raw.check_kernel_props); version = !(raw.version);
    help = !(raw.help);
    dump_surface_tables = !(raw.dump_surface_tables); dump_builtins = !(raw.dump_builtins) }

let parse args = validated (let raw = new_raw args in
  let fs = flags raw in
  let rec loop = function
    | [] -> ()
    | token :: rest ->
        (match List.find_opt (fun f -> f.name = token) fs with
         | Some f -> loop (f.handler rest)
         | None -> raw.files := token :: !(raw.files); loop rest)
  in loop args; raw)

let print_help (t : t) =
  Printf.printf "pp — lazy, pure-by-default, content-addressed Lisp\nUsage:\n  pp                       Start REPL\n  pp <file.pp>             Run a pp source file\n";
  (* The parser owns the help rows; a fresh raw value is used only to recover
     the same immutable table without exposing parser state. *)
  let raw = new_raw t.command_argv in
  List.iter (fun f -> if not f.internal then print_string f.doc) (flags raw)

let command_argv (t : t) = t.command_argv
let program_argv (t : t) = t.program_argv
let files (t : t) = t.files
let grants (t : t) = t.grants
let eval_string (t : t) = t.eval_string
let reconcile_root (t : t) = t.reconcile_root
let supervise (t : t) = t.supervise
let member_name (t : t) = t.member_name
let desired_object (t : t) = t.desired_object
let publish_object_root (t : t) = t.publish_object_root
let watch (t : t) = t.watch
let watch_interval (t : t) = t.watch_interval
let stabilize (t : t) = t.stabilize
let schedule_policy (t : t) = t.schedule_policy
let fenced_policy (t : t) = t.fenced_policy
let gc_keep_epochs (t : t) = t.gc_keep_epochs
let gc_grace_seconds (t : t) = t.gc_grace_seconds
let gc (t : t) = t.gc
let gc_mark_out (t : t) = t.gc_mark_out
let update_islands (t : t) = t.update_islands
let fetch_islands (t : t) = t.fetch_islands
let pin_file (t : t) = t.pin_file
let dump_pins_file (t : t) = t.dump_pins_file
let emit_braces_file (t : t) = t.emit_braces_file
let roundtrip_braces_file (t : t) = t.roundtrip_braces_file
let fmt (t : t) = t.fmt
let compare_hash (t : t) = t.compare_hash
let list_comments (t : t) = t.list_comments
let why (t : t) = t.why
let no_cache (t : t) = t.no_cache
let check (t : t) = t.check
let graph (t : t) = t.graph
let lint_file (t : t) = t.lint_file
let island_pins (t : t) = t.island_pins
let cluster_init (t : t) = t.cluster_init
let mint_token (t : t) = t.mint_token
let transport_push (t : t) = t.transport_push
let transport_pull (t : t) = t.transport_pull
let serve_hit (t : t) = t.serve_hit
let recv_hit (t : t) = t.recv_hit
let remote_node (t : t) = t.remote_node
let check_kernel_props (t : t) = t.check_kernel_props
let version (t : t) = t.version
let help (t : t) = t.help
let dump_surface_tables (t : t) = t.dump_surface_tables
let dump_builtins (t : t) = t.dump_builtins
