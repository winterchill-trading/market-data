open! Core
open! Async
open Market_data

let events : Event.t list =
  [ Trade (Sample.trade ~ms:0 ~price:"100" ~size:"1" ())
  ; Bbo (Sample.bbo ~ms:10_000 ~bid:"99.9" ~ask:"100.1")
  ; Trade (Sample.trade ~ms:20_000 ~price:"100.1" ~size:"2" ())
  ; Funding (Sample.funding ~ms:30_000 ~rate:0.0001)
  ]
;;

let drain_all (module F : Feed.S) =
  let%map trades = Pipe.to_list F.trades
  and bbo = Pipe.to_list F.bbo
  and l2 = Pipe.to_list F.l2
  and funding = Pipe.to_list F.funding in
  print_s
    [%message
      ""
        ~trades:(List.map trades ~f:Trade.price : Price.t list)
        ~bbo:(List.length bbo : int)
        ~l2:(List.length l2 : int)
        ~funding:(List.map funding ~f:Funding.rate : float list)]
;;

let%expect_test "as fast as possible from event log files" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let start = Time_ns.now () in
    let%map () = drain_all (Replay_feed.of_files ~speed:0. (Event_log.Writer.files w)) in
    let elapsed = Time_ns.diff (Time_ns.now ()) start in
    printf "fast: %b\n" Time_ns.Span.(elapsed < of_int_sec 5);
    [%expect
      {|
      ((trades (100 100.1)) (bbo 1) (l2 0) (funding (0.0001)))
      fast: true
      |}])
;;

let%expect_test "paced on a synthetic clock at twice real time" =
  let time_source = Time_source.create ~now:(Sample.ts 0) () in
  let (module F : Feed.S) =
    Replay_feed.of_events
      ~speed:2.
      ~time_source:(Time_source.read_only time_source)
      (Pipe.of_list events)
  in
  let log kind =
    printf
      !"  delivered %s at t=%{Time_ns.Span}\n"
      kind
      (Time_ns.diff (Time_source.now time_source) (Sample.ts 0))
  in
  let consumers =
    Deferred.all_unit
      [ Pipe.iter_without_pushback F.trades ~f:(fun _ -> log "trade")
      ; Pipe.iter_without_pushback F.bbo ~f:(fun _ -> log "bbo")
      ; Pipe.iter_without_pushback F.l2 ~f:(fun _ -> log "l2")
      ; Pipe.iter_without_pushback F.funding ~f:(fun _ -> log "funding")
      ]
  in
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ 4; 1; 5; 4; 1 ] ~f:(fun secs ->
      printf "advance %ds\n" secs;
      let%bind () =
        Time_source.advance_by_alarms_by time_source (Time_ns.Span.of_int_sec secs)
      in
      Scheduler.yield_until_no_jobs_remain ())
  in
  let%map () = consumers in
  [%expect
    {|
      delivered trade at t=0s
    advance 4s
    advance 1s
      delivered bbo at t=5s
    advance 5s
      delivered trade at t=10s
    advance 4s
    advance 1s
      delivered funding at t=15s
    |}]
;;

let%expect_test "close stops a replay waiting for its next event" =
  let (module F : Feed.S) = Replay_feed.of_events ~speed:1. (Pipe.of_list events) in
  let%bind first = Pipe.read F.trades in
  let got_first =
    match first with
    | `Ok _ -> true
    | `Eof -> false
  in
  let%bind () = F.close () in
  let%map rest = Pipe.to_list F.bbo in
  print_s [%message (got_first : bool) ~rest:(List.length rest : int)];
  [%expect {| ((got_first true) (rest 0)) |}]
;;
