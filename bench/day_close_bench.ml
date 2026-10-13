open! Core
open! Async
open Market_data

let instrument = Instrument.create Binance "BTCUSDT"
let day = Date.of_string "2026-01-01"
let epoch = Time_ns.of_string_with_utc_offset "2026-01-01 00:00:00Z"

(* [n] events spread evenly over the day. *)
let at ~n i = Time_ns.add epoch (Time_ns.Span.of_int_ns (i * (86_400_000_000_000 / n)))
let price i = Price.of_string (sprintf "60000.%d" (i % 100))
let size i = Size.of_string (sprintf "0.%03d" (1 + (i % 999)))

let trade ~n i : Event.t =
  let ts = at ~n i in
  Trade
    { instrument
    ; exch_ts = ts
    ; recv_ts = Time_ns.add ts Time_ns.Span.millisecond
    ; price = price i
    ; size = size i
    ; side = (if i % 2 = 0 then Buy else Sell)
    ; trade_id = Int.to_string (1_000_000 + i)
    }
;;

let bbo ~n i : Event.t =
  let ts = at ~n i in
  Bbo
    { instrument
    ; exch_ts = ts
    ; recv_ts = Time_ns.add ts Time_ns.Span.millisecond
    ; bid_price = price i
    ; bid_size = size i
    ; ask_price = price (i + 1)
    ; ask_size = size (i + 7)
    }
;;

let l2 ~n ~levels i : Event.t =
  let ts = at ~n i in
  let side k =
    List.init levels ~f:(fun l ->
      { L2_update.Level.price = price (i + l + k); size = size (i + l) })
  in
  L2
    { instrument
    ; exch_ts = ts
    ; recv_ts = Time_ns.add ts Time_ns.Span.millisecond
    ; kind = (if i = 0 then Snapshot else Delta)
    ; bids = side 0
    ; asks = side 50
    }
;;

let funding ~n i : Event.t =
  let ts = at ~n i in
  Funding
    { instrument
    ; exch_ts = ts
    ; recv_ts = Time_ns.add ts Time_ns.Span.millisecond
    ; rate = 0.0001 *. Float.of_int (i % 7)
    ; next_funding_time = Time_ns.add ts Time_ns.Span.hour
    ; mark_price = price i
    ; index_price = price (i + 3)
    }
;;

let write ~dir ~trades ~bbos ~l2s ~levels ~fundings =
  let w = Event_log.Writer.create ~dir () in
  let stream n f =
    for i = 0 to n - 1 do
      Event_log.Writer.append w (f ~n i)
    done
  in
  stream trades trade;
  stream bbos bbo;
  stream l2s (l2 ~levels);
  stream fundings funding;
  Event_log.Writer.close w
;;

let run_once ~dir ~compression =
  let words0 = Gc.minor_words () in
  let t0 = Time_ns.now () in
  let%map results =
    Day_close.run ~compression ~force:true ~instruments:[ instrument ] ~dir day
  in
  let secs = Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) t0) in
  let words = Gc.minor_words () - words0 in
  let total = ref 0 in
  List.iter results ~f:(fun (r : Day_close.Result.t) ->
    match r.outcome, r.stats with
    | Written { rows; _ }, Some stats ->
      total := !total + rows;
      let s = Time_ns.Span.to_sec stats.elapsed in
      printf
        "  %-8s %9d rows %7.3fs %6.2f M rows/s %7.1f MB\n"
        (Parquet_kind.to_string r.kind)
        rows
        s
        (Float.of_int rows /. s /. 1e6)
        (Float.of_int stats.output_bytes /. 1e6)
    | _ -> ());
  printf
    "  total    %9d rows %7.3fs %6.2f M rows/s, %.1f minor words per row\n"
    !total
    secs
    (Float.of_int !total /. secs /. 1e6)
    (Float.of_int words /. Float.of_int !total)
;;

(* The decode side alone: every event file of the day read through [Event_log.read_file]. *)
let read_only ~dir =
  let words0 = Gc.minor_words () in
  let t0 = Time_ns.now () in
  let%map events =
    Deferred.List.fold Stream.all ~init:0 ~f:(fun acc stream ->
      let path = Event_log.path ~dir instrument stream day in
      match%bind Sys.file_exists_exn path with
      | false -> return acc
      | true ->
        let events, _tail = Event_log.read_file path in
        Pipe.fold_without_pushback events ~init:acc ~f:(fun n _ -> n + 1))
  in
  let secs = Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) t0) in
  printf
    "  read only: %d events %.3fs %.2f M events/s, %.1f minor words per event\n"
    events
    secs
    (Float.of_int events /. secs /. 1e6)
    (Float.of_int (Gc.minor_words () - words0) /. Float.of_int events)
;;

let command =
  Command.async
    ~summary:"Rows per second through Day_close.run on a synthetic day"
    (let%map_open.Command trades =
       flag "-trades" (optional_with_default 1_000_000 int) ~doc:"N trades"
     and bbos = flag "-bbo" (optional_with_default 1_000_000 int) ~doc:"N bbo updates"
     and l2s = flag "-l2" (optional_with_default 100_000 int) ~doc:"N l2 updates"
     and levels =
       flag "-levels" (optional_with_default 5 int) ~doc:"N levels per side per l2 update"
     and fundings =
       flag "-funding" (optional_with_default 1_440 int) ~doc:"N funding updates"
     and runs = flag "-runs" (optional_with_default 3 int) ~doc:"N runs"
     and zstd = flag "-zstd" no_arg ~doc:" compress pages (default: none)" in
     fun () ->
       let%bind dir = Unix.mkdtemp (Filename.temp_dir_name ^/ "day-close-bench") in
       let%bind () = write ~dir ~trades ~bbos ~l2s ~levels ~fundings in
       let compression = if zstd then `Zstd else `None in
       let%bind () =
         Deferred.List.iter (List.init runs ~f:Fn.id) ~how:`Sequential ~f:(fun i ->
           printf "run %d\n" (i + 1);
           let%bind () = run_once ~dir ~compression in
           read_only ~dir)
       in
       Unix.system_exn (sprintf "rm -rf %s" (Filename.quote dir)))
;;

let () = Command_unix.run command
