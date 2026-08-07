type t = {
  layout : Store_layout.t;
  objects : Object_repository.t;
  traces : Trace_repository.t;
  blobs : Blob_repository.t;
  cache : Cache_policy.t;
}

let create ?(layout = Store_layout.default) ?(cache = Cache_policy.create ()) () =
  { layout;
    objects = Object_repository.create layout;
    traces = Trace_repository.create layout;
    blobs = Blob_repository.create layout;
    cache }

let default = lazy (create ())
let current_context : t option ref = ref None

let current () =
  match !current_context with
  | Some context -> context
  | None -> Lazy.force default

let with_current context f x =
  let previous = !current_context in
  current_context := Some context;
  Fun.protect (fun () -> f x) ~finally:(fun () -> current_context := previous)

let layout () = (current ()).layout
let objects () = (current ()).objects
let traces () = (current ()).traces
let blobs () = (current ()).blobs
let cache () = (current ()).cache
let layout_of context = context.layout
let objects_of context = context.objects
let traces_of context = context.traces
let blobs_of context = context.blobs
let cache_of context = context.cache
