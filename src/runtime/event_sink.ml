type destination = Noop | Jsonl of out_channel
type t = {
  destination : destination;
  run_id : string;
  host_id : string;
  level : Event.level;
  mutable next_id : int;
  mutable closed : bool;
}

let noop = {
  destination = Noop; run_id = ""; host_id = ""; level = Event.Summary;
  next_id = 1; closed = false;
}

let jsonl ~path ~run_id ~host_id ~level = {
  destination = Jsonl (open_out_bin path);
  run_id;
  host_id;
  level;
  next_id = 1;
  closed = false;
}

let enabled t = match t.destination with Noop -> false | Jsonl _ -> true

let rank = function
  | Event.Summary -> 0
  | Event.Semantic -> 1
  | Event.Evaluation -> 2
  | Event.Transport -> 3

let accepts t level = match t.destination with
  | Noop -> false
  | Jsonl _ -> rank level <= rank t.level

let emit t ?parent_event_id payload =
  match t.destination with
  | Noop -> None
  | Jsonl _ when not (accepts t (Event.level payload)) -> None
  | Jsonl channel ->
      if t.closed then invalid_arg "event sink is closed";
      let event_id = t.next_id in
      t.next_id <- event_id + 1;
      let event = {
        Event.schema_version = 1;
        run_id = t.run_id;
        event_id;
        parent_event_id;
        host_id = t.host_id;
        logical_time = event_id;
        category = Event.category payload;
        kind = Event.kind payload;
        phase = Event.phase payload;
        visibility = Event.visibility payload;
        payload;
      } in
      output_string channel (Event.to_json event);
      output_char channel '\n';
      flush channel;
      Some event_id

let close t =
  if not t.closed then begin
    t.closed <- true;
    match t.destination with Noop -> () | Jsonl channel -> close_out channel
  end
