open! Core
module Md_stream = Stream
open! Async

let of_items ?(speed = 1.) ?(time_source = Time_source.wall_clock ()) items
  : Feed.With_gaps.t
  =
  if Float.( < ) speed 0. || Float.is_nan speed
  then raise_s [%message "Replay_feed: speed must be >= 0" (speed : float)];
  let trades_r, trades_w = Pipe.create () in
  let bbo_r, bbo_w = Pipe.create () in
  let l2_r, l2_w = Pipe.create () in
  let funding_r, funding_w = Pipe.create () in
  let gaps_r, gaps_w = Pipe.create () in
  let stopped = Ivar.create () in
  let close_all () =
    Ivar.fill_if_empty stopped ();
    Pipe.close_read items;
    Pipe.close trades_w;
    Pipe.close bbo_w;
    Pipe.close l2_w;
    Pipe.close funding_w;
    Pipe.close gaps_w
  in
  let start = ref None in
  let wait_for recv_ts =
    if Float.equal speed 0.
    then return ()
    else (
      let first_ts, wall_start =
        match !start with
        | Some s -> s
        | None ->
          let s = recv_ts, Time_source.now time_source in
          start := Some s;
          s
      in
      let offset = Time_ns.Span.( / ) (Time_ns.diff recv_ts first_ts) speed in
      Deferred.any_unit
        [ Time_source.at time_source (Time_ns.add wall_start offset); Ivar.read stopped ])
  in
  let deliver = function
    | `Event (Event.Trade x) -> Pipe.write_if_open trades_w x
    | `Event (Bbo x) -> Pipe.write_if_open bbo_w x
    | `Event (L2 x) -> Pipe.write_if_open l2_w x
    | `Event (Funding x) -> Pipe.write_if_open funding_w x
    | `Gap gap ->
      Pipe.write_without_pushback_if_open gaps_w gap;
      return ()
  in
  let recv_ts = function
    | `Event e -> Event.recv_ts e
    | `Gap (g : Gap.t) -> g.recv_ts
  in
  let finished =
    Monitor.protect
      (fun () ->
        Pipe.iter items ~f:(fun item ->
          let%bind () = wait_for (recv_ts item) in
          deliver item))
      ~finally:(fun () ->
        close_all ();
        return ())
  in
  (module struct
    let trades = trades_r
    let bbo = bbo_r
    let l2 = l2_r
    let funding = funding_r
    let gaps = gaps_r

    let close () =
      close_all ();
      finished
    ;;
  end)
;;

let of_events ?speed ?time_source events =
  let items = Pipe.map events ~f:(fun e -> `Event e) in
  upon (Pipe.closed items) (fun () -> Pipe.close_read events);
  Feed.With_gaps.to_feed (of_items ?speed ?time_source items)
;;

let of_files ?speed ?time_source files =
  of_events ?speed ?time_source (Event_log.read_merged files)
;;

(* The events of one log file, then a gap at its last event if the file is damaged. *)
let file_items path =
  let events, tail = Event_log.read_file path in
  Pipe.create_reader ~close_on_exception:true (fun w ->
    let last = ref None in
    let%bind () =
      Pipe.iter events ~f:(fun e ->
        last := Some e;
        Pipe.write_if_open w (`Event e))
    in
    match%map tail with
    | Clean -> ()
    | Truncated _ | Corrupt _ ->
      Option.iter !last ~f:(fun e ->
        let instrument = Event.instrument e in
        Pipe.write_without_pushback_if_open
          w
          (`Gap
            { Gap.recv_ts = Event.recv_ts e
            ; venue = instrument.venue
            ; instrument = Some instrument
            ; stream = Some (Event.stream e)
            ; reason = Damaged_log
            })))
;;

let of_files_with_gaps ?speed ?time_source files =
  let item_ts = function
    | `Event e -> Event.recv_ts e
    | `Gap (g : Gap.t) -> g.recv_ts
  in
  Merge.sorted (List.map files ~f:file_items) ~compare:(fun a b ->
    Time_ns.compare (item_ts a) (item_ts b))
  |> of_items ?speed ?time_source
;;

(* Per instrument: where its replay starts, and the snapshot to deliver first. *)
let starts ~dir ~streams instruments start_at =
  Deferred.List.map instruments ~how:`Sequential ~f:(fun instrument ->
    let%map entry =
      if List.mem streams Md_stream.L2 ~equal:Md_stream.equal
      then Snapshot_index.find ~dir instrument start_at
      else return None
    in
    match entry with
    | Some e -> instrument, e.at, Some (Event.L2 e.book)
    | None -> instrument, start_at, None)
;;

let from_start events starts =
  let start_of = Instrument.Table.create () in
  List.iter starts ~f:(fun (instrument, at, _) ->
    Hashtbl.set start_of ~key:instrument ~data:at);
  let after_start =
    Pipe.filter events ~f:(fun e ->
      match Hashtbl.find start_of (Event.instrument e) with
      | Some at -> Time_ns.( >= ) (Event.recv_ts e) at
      | None -> true)
  in
  let snapshots =
    List.filter_map starts ~f:(fun (_, _, snapshot) -> snapshot)
    |> List.stable_sort ~compare:Event.compare_by_recv_ts
  in
  Merge.sorted [ Pipe.of_list snapshots; after_start ] ~compare:Event.compare_by_recv_ts
;;

let of_range
  ?speed
  ?time_source
  ?(streams = [ Md_stream.Trades; Bbo; L2; Funding ])
  ?start_at
  ~dir
  instruments
  ~from
  ~to_
  =
  let store = Store.create dir in
  let from =
    match start_at with
    | Some t -> Date.max from (Store.date_of_time t)
    | None -> from
  in
  let%bind files =
    Deferred.List.concat_map instruments ~how:`Sequential ~f:(fun instrument ->
      Store.files store Norm instrument streams ~from ~to_)
  in
  if List.is_empty files
  then
    return
      (Or_error.error_s
         [%message
           "Replay_feed: no event log files in the date range"
             (dir : string)
             (instruments : Instrument.t list)
             (streams : Md_stream.t list)
             (from : Date.t)
             (to_ : Date.t)])
  else (
    match start_at with
    | None -> return (Ok (of_files ?speed ?time_source files))
    | Some start_at ->
      let%map starts = starts ~dir ~streams instruments start_at in
      Ok (of_events ?speed ?time_source (from_start (Event_log.read_merged files) starts)))
;;

let of_raw
  ?speed
  ?time_source
  ?streams
  ?(on_error = fun e -> Log.Global.error_s (Error.sexp_of_t e))
  ~normalizer:(module N : Normalizer.S)
  ~data_dir
  ~symbol
  ~start
  ~stop
  ()
  =
  let instrument = Instrument.create N.venue symbol in
  let states = Md_stream.Table.create () in
  let state stream = Hashtbl.find_or_add states stream ~default:N.create in
  let raw =
    Raw_reader.read ?streams ~on_error ~data_dir ~venue:N.venue ~symbol ~start ~stop ()
  in
  let items =
    Pipe.concat_map_list raw ~f:(function
      | Raw_reader.Item.Frame { recv_ts; stream; frame } ->
        (match N.frame (state stream) ~recv_ts frame with
         | Ok events -> List.map events ~f:(fun e -> `Event e)
         | Error e ->
           on_error
             (Error.tag_s
                e
                ~tag:
                  [%message
                    "" (stream : Md_stream.t) (recv_ts : Time_ns.Alternate_sexp.t)]);
           [])
      | Gap { recv_ts; stream } ->
        N.disconnect (state stream);
        [ `Gap
            { Gap.recv_ts
            ; venue = N.venue
            ; instrument = Some instrument
            ; stream = Some stream
            ; reason = Disconnect
            }
        ])
  in
  upon (Pipe.closed items) (fun () -> Pipe.close_read raw);
  of_items ?speed ?time_source items
;;
