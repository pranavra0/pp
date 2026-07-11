(* pp journal — the append-only intent/done audit log (Q4 / LAW 31).

   One typed entry variant owns every line shape; [to_line]/[of_line] live
   together so a writer cannot invent a dialect the scanner does not read.
   Line formats are FROZEN — tests and tooling grep this log.

   Convergent domains (fs, proc) journal intent/done as an audit trail only:
   recovery is re-running reconcile, not replay (desired state is cheap to
   recompute, observed state is re-derived from cells). Fenced effects use
   the same journal as a WAL: an `intent fenced` with no later matching
   `done fenced` is an unknown-status action that must be resolved by
   --fenced-policy before normal reconciliation proceeds. *)

type entry =
  | Exec of string list
      (* every external process execution — "null rebuild executes zero
         processes" is proved by these lines (Phase-1 exit criterion 1) *)
  | FsIntent of { hash : string; root : string; create : int; update : int; delete : int }
  | FsDone of { hash : string }
  | ProcStartIntent of { name : string; spec_hash : string }
  | ProcStartDone of { name : string; spec_hash : string; pid : int }
  | ProcStopIntent of { name : string }
  | ProcStopDone of { name : string }
  | FencedIntent of { key : string; epoch : string; kind : string; spec_hash : string }
  | FencedDone of { key : string; result_hash : string }

let to_line = function
  | Exec argv -> "exec " ^ String.concat " " argv
  | FsIntent { hash; root; create; update; delete } ->
      Printf.sprintf "intent %s root=%s create=%d update=%d delete=%d"
        hash root create update delete
  | FsDone { hash } -> Printf.sprintf "done %s" hash
  | ProcStartIntent { name; spec_hash } ->
      Printf.sprintf "intent proc start %s %s" name spec_hash
  | ProcStartDone { name; spec_hash; pid } ->
      Printf.sprintf "done proc start %s %s pid=%d" name spec_hash pid
  | ProcStopIntent { name } -> Printf.sprintf "intent proc stop %s" name
  | ProcStopDone { name } -> Printf.sprintf "done proc stop %s" name
  | FencedIntent { key; epoch; kind; spec_hash } ->
      Printf.sprintf "intent fenced %s %s %s %s" key epoch kind spec_hash
  | FencedDone { key; result_hash } ->
      Printf.sprintf "done fenced %s %s" key result_hash

(* Best-effort inverse. Only the fenced dialect is ever read back for
   recovery decisions; other shapes parse when unambiguous and fall to None
   otherwise (e.g. a service name containing spaces — writers embed it
   verbatim, and nothing downstream re-reads proc lines). *)
let of_line (line : string) : entry option =
  match String.split_on_char ' ' (String.trim line) with
  | "exec" :: argv -> Some (Exec argv)
  | "intent" :: "fenced" :: key :: epoch :: kind :: spec_hash :: _ ->
      Some (FencedIntent { key; epoch; kind; spec_hash })
  | "done" :: "fenced" :: key :: result_hash :: _ ->
      Some (FencedDone { key; result_hash })
  | "done" :: "fenced" :: key :: _ ->
      Some (FencedDone { key; result_hash = "" })
  | "intent" :: "proc" :: "start" :: [name; spec_hash] ->
      Some (ProcStartIntent { name; spec_hash })
  | "done" :: "proc" :: "start" :: [name; spec_hash; pidkv] ->
      (match String.split_on_char '=' pidkv with
       | ["pid"; p] ->
           (match int_of_string_opt p with
            | Some pid -> Some (ProcStartDone { name; spec_hash; pid })
            | None -> None)
       | _ -> None)
  | "intent" :: "proc" :: "stop" :: [name] -> Some (ProcStopIntent { name })
  | "done" :: "proc" :: "stop" :: [name] -> Some (ProcStopDone { name })
  | ["done"; hash] -> Some (FsDone { hash })
  | "intent" :: hash :: rest when rest <> [] ->
      (let kv s = match String.index_opt s '=' with
         | Some i -> Some (String.sub s 0 i,
                           String.sub s (i + 1) (String.length s - i - 1))
         | None -> None
       in
       match List.filter_map kv rest with
       | [("root", root); ("create", c); ("update", u); ("delete", d)] ->
           (match int_of_string_opt c, int_of_string_opt u, int_of_string_opt d with
            | Some create, Some update, Some delete ->
                Some (FsIntent { hash; root; create; update; delete })
            | _ -> None)
       | _ -> None)
  | _ -> None

(* ---- The log file ---- *)

let journal_dir = Filename.concat Store.store_root "journal"
let log_path () = Filename.concat journal_dir "log"

let append (e : entry) : unit =
  Store.ensure_dir journal_dir;
  let oc = open_out_gen [Open_append; Open_creat] 0o644 (log_path ()) in
  output_string oc (to_line e ^ "\n");
  close_out oc

(* Fold every parseable entry in journal order. *)
let fold (f : 'a -> entry -> 'a) (init : 'a) : 'a =
  let path = log_path () in
  if not (Sys.file_exists path) then init
  else begin
    let ic = open_in path in
    let acc = ref init in
    (try
       while true do
         match of_line (input_line ic) with
         | Some e -> acc := f !acc e
         | None -> ()
       done
     with End_of_file -> ());
    close_in ic;
    !acc
  end

(* ---- Fenced-effect scanners (Q3 / LAW 31) ---- *)

type fenced_entry = {
  fe_key : string;
  fe_epoch : string;
  fe_kind : string;
  fe_spec_hash : string;
}

(* Fenced intents without a matching done, in journal order (oldest first).
   Only the most recent unmatched intent for a given key is meaningful, but
   all are returned so recovery can process them in order. *)
let find_unknown_fenced () : fenced_entry list =
  let pending : (string, string * string * string) Hashtbl.t = Hashtbl.create 16 in
  fold (fun () e ->
    match e with
    | FencedIntent { key; epoch; kind; spec_hash } ->
        Hashtbl.replace pending key (epoch, kind, spec_hash)
    | FencedDone { key; _ } -> Hashtbl.remove pending key
    | _ -> ()) ();
  Hashtbl.fold (fun key (epoch, kind, spec_hash) acc ->
    { fe_key = key; fe_epoch = epoch; fe_kind = kind; fe_spec_hash = spec_hash } :: acc)
    pending []

(* Whether a fenced key already has a done entry — used at action time to
   avoid re-executing an action completed in a prior pass. *)
let fenced_is_done (key : string) : bool =
  let (pending, seen) =
    fold (fun (pending, seen) e ->
      match e with
      | FencedIntent { key = k; _ } when k = key -> (true, true)
      | FencedDone { key = k; _ } when k = key -> (false, true)
      | _ -> (pending, seen)) (false, false)
  in
  seen && not pending
