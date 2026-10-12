open! Core
open! Async
open Market_data

let level price size : L2_update.Level.t =
  { price = Price.of_string price; size = Size.of_string size }
;;

let l2 ~ms ?(kind = L2_update.Kind.Delta) ~bids ~asks () : Event.t =
  L2
    { instrument = Sample.btc
    ; exch_ts = Sample.ts ms
    ; recv_ts = Sample.ts ms
    ; kind
    ; bids = List.map bids ~f:(fun (p, s) -> level p s)
    ; asks = List.map asks ~f:(fun (p, s) -> level p s)
    }
;;

let minute = 60_000

(* A snapshot, then a delta every 20 seconds for four minutes, and a trade each minute. *)
let events =
  l2 ~ms:5 ~kind:Snapshot ~bids:[ "99", "1" ] ~asks:[ "101", "1" ] ()
  :: List.concat_map (List.range 1 13) ~f:(fun i ->
    let ms = i * 20_000 in
    let px = Int.to_string (100 + i) in
    let delta = l2 ~ms ~bids:[ Int.to_string (99 - i), "1" ] ~asks:[ px, "2" ] () in
    if i % 3 = 0
    then [ delta; Event.Trade (Sample.trade ~ms:(ms + 1) ~price:px ~size:"1" ()) ]
    else [ delta ])
;;

let book_of events =
  List.fold events ~init:L2_book.empty ~f:(fun book (e : Event.t) ->
    match e with
    | L2 u -> L2_book.apply book u
    | _ -> book)
;;

let same_levels a b =
  [%equal: L2_update.Level.t list] (L2_book.bids a) (L2_book.bids b)
  && [%equal: L2_update.Level.t list] (L2_book.asks a) (L2_book.asks b)
;;

let%expect_test "builder snapshots at minute boundaries" =
  let b = Snapshot_index.Builder.create ~interval:(Time_ns.Span.of_int_sec 60) in
  List.iter events ~f:(fun (e : Event.t) ->
    match e with
    | L2 u ->
      Option.iter (Snapshot_index.Builder.observe b u) ~f:(fun entry ->
        printf
          !"%{Time_ns.to_string_utc} bids %d asks %d\n"
          entry.at
          (List.length entry.book.bids)
          (List.length entry.book.asks))
    | _ -> ());
  [%expect
    {|
    2026-01-01 00:01:00.000000000Z bids 3 asks 2
    2026-01-01 00:02:00.000000000Z bids 6 asks 5
    2026-01-01 00:03:00.000000000Z bids 9 asks 8
    2026-01-01 00:04:00.000000000Z bids 12 asks 11
    |}];
  return ()
;;

let write ~dir =
  let w =
    Event_log.Writer.create ~snapshot_interval:(Time_ns.Span.of_int_sec 60) ~dir ()
  in
  List.iter events ~f:(Event_log.Writer.append w);
  let%map () = Event_log.Writer.close w in
  w
;;

let%expect_test "writer keeps a snapshot file and a replay starts from it" =
  Sample.with_temp_dir (fun dir ->
    let%bind w = write ~dir in
    List.iter (Event_log.Writer.snapshot_files w) ~f:(fun f ->
      print_endline (Sample.relative ~dir f));
    let%bind entries =
      Snapshot_index.load ~dir Sample.btc (Date.of_string "2026-01-01")
    in
    printf "entries: %d\n" (List.length entries);
    let%bind days = Store.days (Store.create dir) Norm Sample.btc L2 in
    print_s [%sexp (days : Date.t list)];
    [%expect
      {|
      binance/BTCUSDT/norm/l2/_snapshots/2026-01-01.bin
      entries: 4
      (2026-01-01)
      |}];
    let start_at = Sample.ts ((2 * minute) + 30_000) in
    let%bind feed =
      Replay_feed.of_range
        ~speed:0.
        ~start_at
        ~dir
        [ Sample.btc ]
        ~from:(Date.of_string "2026-01-01")
        ~to_:(Date.of_string "2026-01-01")
      >>| ok_exn
    in
    let (module F : Feed.S) = feed in
    let%bind l2 = Pipe.to_list F.l2
    and trades = Pipe.to_list F.trades
    and _ = Pipe.to_list F.bbo
    and _ = Pipe.to_list F.funding in
    List.iter l2 ~f:(fun u ->
      printf !"%{Time_ns.to_string_utc} %{sexp: L2_update.Kind.t}\n" u.recv_ts u.kind);
    List.iter trades ~f:(fun t -> printf !"trade %{Time_ns.to_string_utc}\n" t.recv_ts);
    let replayed = List.fold l2 ~init:L2_book.empty ~f:L2_book.apply in
    printf
      "same final book as a full replay: %b\n"
      (same_levels replayed (book_of events));
    [%expect
      {|
      2026-01-01 00:02:00.000000000Z Snapshot
      2026-01-01 00:02:00.000000000Z Delta
      2026-01-01 00:02:20.000000000Z Delta
      2026-01-01 00:02:40.000000000Z Delta
      2026-01-01 00:03:00.000000000Z Delta
      2026-01-01 00:03:20.000000000Z Delta
      2026-01-01 00:03:40.000000000Z Delta
      2026-01-01 00:04:00.000000000Z Delta
      trade 2026-01-01 00:02:00.002000000Z
      trade 2026-01-01 00:03:00.002000000Z
      trade 2026-01-01 00:04:00.002000000Z
      same final book as a full replay: true
      |}];
    return ())
;;

let%expect_test "without a snapshot file the replay starts at start_at" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    print_s [%sexp (Event_log.Writer.snapshot_files w : string list)];
    let%bind feed =
      Replay_feed.of_range
        ~speed:0.
        ~start_at:(Sample.ts ((3 * minute) + 30_000))
        ~dir
        [ Sample.btc ]
        ~from:(Date.of_string "2026-01-01")
        ~to_:(Date.of_string "2026-01-01")
      >>| ok_exn
    in
    let (module F : Feed.S) = feed in
    let%bind l2 = Pipe.to_list F.l2
    and _ = Pipe.to_list F.trades
    and _ = Pipe.to_list F.bbo
    and _ = Pipe.to_list F.funding in
    List.iter l2 ~f:(fun u ->
      printf !"%{Time_ns.to_string_utc} %{sexp: L2_update.Kind.t}\n" u.recv_ts u.kind);
    [%expect
      {|
      ()
      2026-01-01 00:03:40.000000000Z Delta
      2026-01-01 00:04:00.000000000Z Delta
      |}];
    return ())
;;
