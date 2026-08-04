let read_all ic =
  let buffer = Buffer.create 256 in
  (try while true do Buffer.add_string buffer (input_line ic); Buffer.add_char buffer '\n' done
   with End_of_file -> ());
  Buffer.contents buffer

let () =
  print_endline
    (Pp_browser_runtime.Browser_runtime.to_json
       (Pp_browser_runtime.Browser_runtime.run ~source:(read_all stdin)))
