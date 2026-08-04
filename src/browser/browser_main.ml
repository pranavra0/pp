open Js_of_ocaml

let run source =
  Pp_browser_runtime.Browser_runtime.to_json
    (Pp_browser_runtime.Browser_runtime.run ~source:(Js.to_string source))
let callback = Js.wrap_callback run

let () =
  Js.Unsafe.set Js.Unsafe.global "ppBrowserRun" callback
