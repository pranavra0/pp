open Pp_frontend
open Pp_kernel
open Source_error
let read_whole path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let run cli =
  match Cli.emit_braces_file cli, Cli.roundtrip_braces_file cli, Cli.fmt cli,
        Cli.compare_hash cli, Cli.list_comments cli with
  | Some file, _, _, _, _ ->
      if Reader_braces.file_uses_braces file then
        command ("pp --emit-braces: " ^ file ^ " is already a brace file");
      let forms = Reader.read_string ~source:file (read_whole file) in
      (try print_string (Printer_braces.print_program ~source:file forms)
       with Printer_braces.Unprintable msg -> command ("pp --emit-braces: " ^ msg));
      true
  | None, Some file, _, _, _ ->
      if Reader_braces.file_uses_braces file then
        command ("pp --roundtrip-braces: " ^ file ^ " is already a brace file");
      let forms = Reader.read_string ~source:file (read_whole file) in
      let braces = try Printer_braces.print_program ~source:file forms
        with Printer_braces.Unprintable msg -> command ("roundtrip: unprintable: " ^ msg) in
      let forms' = try Reader_braces.read_string ~source:file braces with Failure msg ->
        Printf.eprintf "--- emitted brace text ---\n%s" braces;
        command ("roundtrip: brace re-read failed: " ^ msg) in
      if List.length forms <> List.length forms' then begin
        Printf.eprintf "--- emitted brace text ---\n%s" braces;
        command (Printf.sprintf "roundtrip: form count diverged: %d sexpr vs %d brace"
          (List.length forms) (List.length forms'))
      end;
      List.iteri (fun i (a, b) ->
        let ha = Identity.hash_expr a and hb = Identity.hash_expr b in
        if ha <> hb then begin
          Printf.eprintf "--- emitted brace text ---\n%s" braces;
          command (Printf.sprintf "roundtrip: form %d hash diverged: %s vs %s" i ha hb)
        end) (List.combine forms forms');
      true
  | None, None, Some (target, file, in_place), _, _ ->
      let source = read_whole file in
      let output = match target with
        | Cli.To_braces ->
            let forms = Reader.read_string ~source:file source in
            let comments = Comments.scan_sexpr source in
            let reserved = List.map (fun (c : Comments.t) -> c.line) comments in
            let base = try Printer_braces.print_program ~source:file ~reserved forms
              with Printer_braces.Unprintable msg -> command ("pp fmt --to-braces: " ^ msg) in
            Comments.splice comments ~delim:'#' base
        | Cli.To_sexpr ->
            let forms = Reader_braces.read_string ~source:file source in
            let comments = Comments.scan_brace source in
            let base = try Printer_sexpr.print_program ~source:file forms
              with Printer_sexpr.Unprintable msg -> command ("pp fmt --to-sexpr: " ^ msg) in
            Comments.splice comments ~delim:';' base
      in
      if in_place then begin
        let oc = open_out file in
        Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc output)
      end else print_string output;
      true
  | None, None, None, Some (file1, file2), _ ->
      let forms1 = Reader_braces.read_dispatch ~source:file1 ~path:file1 (read_whole file1) in
      let forms2 = Reader_braces.read_dispatch ~source:file1 ~path:file2 (read_whole file2) in
      if List.length forms1 <> List.length forms2 then
        command (Printf.sprintf "--compare-hash: form count diverged: %d (%s) vs %d (%s)"
          (List.length forms1) file1 (List.length forms2) file2);
      List.iteri (fun i (a, b) ->
        if Identity.hash_expr a <> Identity.hash_expr b then
          command (Printf.sprintf "--compare-hash: form %d hash diverged" i))
        (List.combine forms1 forms2);
      true
  | None, None, None, None, Some (surface, file) ->
      let source = read_whole file in
      let comments = match surface with
        | `Sexpr -> Comments.scan_sexpr source
        | `Brace -> Comments.scan_brace source in
      List.iter (fun (c : Comments.t) ->
        Printf.printf "%d: %s\n" c.line (String.trim c.text)) comments;
      true
  | _ -> false
