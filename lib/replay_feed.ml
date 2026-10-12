open! Core
module Md_stream = Stream
open! Async

let of_events ?(speed = 1.) ?(time_source = Time_source.wall_clock ()) events : Feed.t =
  if Float.( < ) speed 0. || Float.is_nan speed
  then raise_s [%message "Replay_feed: speed must be >= 0" (speed : float)];
  let trades_r, trades_w = Pipe.create () in
  let bbo_r, bbo_w = Pipe.create () in
  let l2_r, l2_w = Pipe.create () in
  let funding_r, funding_w = Pipe.create () in
  let stopped = Ivar.create () in
  let close_all () =
    Ivar.fill_if_empty stopped ();
    Pipe.close_read events;
    Pipe.close trades_w;
    Pipe.close bbo_w;
    Pipe.close l2_w;
    Pipe.close funding_w
  in
  let start = ref None in
  let wait_for event =
    if Float.equal speed 0.
    then return ()
    else (
      let recv_ts = Event.recv_ts event in
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
  let deliver : Event.t -> unit Deferred.t = function
    | Trade x -> Pipe.write_if_open trades_w x
    | Bbo x -> Pipe.write_if_open bbo_w x
    | L2 x -> Pipe.write_if_open l2_w x
    | Funding x -> Pipe.write_if_open funding_w x
  in
  let finished =
    Monitor.protect
      (fun () ->
        Pipe.iter events ~f:(fun event ->
          let%bind () = wait_for event in
          deliver event))
      ~finally:(fun () ->
        close_all ();
        return ())
  in
  (module struct
    let trades = trades_r
    let bbo = bbo_r
    let l2 = l2_r
    let funding = funding_r

    let close () =
      close_all ();
      finished
    ;;
  end)
;;

let of_files ?speed ?time_source files =
  of_events ?speed ?time_source (Event_log.read_merged files)
;;

let of_range
  ?speed
  ?time_source
  ?(streams = [ Md_stream.Trades; Bbo; L2; Funding ])
  ~dir
  instruments
  ~from
  ~to_
  =
  let store = Store.create dir in
  let%map files =
    Deferred.List.concat_map instruments ~how:`Sequential ~f:(fun instrument ->
      Store.files store Norm instrument streams ~from ~to_)
  in
  if List.is_empty files
  then
    Or_error.error_s
      [%message
        "Replay_feed: no event log files in the date range"
          (dir : string)
          (instruments : Instrument.t list)
          (streams : Md_stream.t list)
          (from : Date.t)
          (to_ : Date.t)]
  else Ok (of_files ?speed ?time_source files)
;;
