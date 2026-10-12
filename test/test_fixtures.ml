open! Core
open! Async
open Market_data

(* Written once by [Event_log.Writer] when file headers were introduced. Never regenerate
   these files: a failure here means today's code can no longer read old recordings. *)
let dir = "fixtures/event-log-v1"

let%expect_test "checked-in event log still reads" =
  let store = Store.create dir in
  let%bind instruments = Store.instruments store in
  let day = Date.of_string "2026-01-01" in
  let%bind files =
    Deferred.List.concat_map instruments ~how:`Sequential ~f:(fun instrument ->
      Store.files store Norm instrument [ Trades; Bbo; L2; Funding ] ~from:day ~to_:day)
  in
  let%bind () =
    Deferred.List.iter files ~how:`Sequential ~f:(fun path ->
      let%map digest = Framed.read_digest path
      and events, tail = Event_log.load_file path in
      print_s
        [%message
          ""
            ~file:(Sample.relative ~dir path : string)
            ~events:(List.length events : int)
            (tail : Framed.Tail.t)
            ~digest_ok:
              (Option.exists
                 digest
                 ~f:(List.mem Event_log.compatible_digests ~equal:String.equal)
               : bool)])
  in
  [%expect
    {|
    ((file hyperliquid/ETH/norm/trades/2026-01-01.bin) (events 1) (tail Clean)
     (digest_ok true))
    ((file binance/BTCUSDT/norm/trades/2026-01-01.bin) (events 2) (tail Clean)
     (digest_ok true))
    ((file binance/BTCUSDT/norm/bbo/2026-01-01.bin) (events 2) (tail Clean)
     (digest_ok true))
    ((file binance/BTCUSDT/norm/l2/2026-01-01.bin) (events 2) (tail Clean)
     (digest_ok true))
    ((file binance/BTCUSDT/norm/funding/2026-01-01.bin) (events 1) (tail Clean)
     (digest_ok true))
    |}];
  let%map merged = Pipe.to_list (Event_log.read_merged files) in
  List.iter merged ~f:(fun e -> print_s [%sexp (e : Event.t)]);
  [%expect
    {|
    (L2
     ((instrument ((venue Binance) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.000000000Z))
      (recv_ts (2026-01-01 00:00:00.001000000Z)) (kind Snapshot)
      (bids (((price 99.9) (size 1)) ((price 99.8) (size 3))))
      (asks (((price 100.1) (size 2)) ((price 100.2) (size 4))))))
    (Bbo
     ((instrument ((venue Binance) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.001000000Z))
      (recv_ts (2026-01-01 00:00:00.002000000Z)) (bid_price 99.9) (bid_size 1)
      (ask_price 100.1) (ask_size 1)))
    (Trade
     ((instrument ((venue Binance) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.010000000Z))
      (recv_ts (2026-01-01 00:00:00.011000000Z)) (price 100.1) (size 0.5)
      (side Buy) (trade_id 10)))
    (Trade
     ((instrument ((venue Binance) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.020000000Z))
      (recv_ts (2026-01-01 00:00:00.021000000Z)) (price 99.9) (size 1.25)
      (side Sell) (trade_id 20)))
    (L2
     ((instrument ((venue Binance) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.021000000Z))
      (recv_ts (2026-01-01 00:00:00.022000000Z)) (kind Delta)
      (bids (((price 99.9) (size 0)))) (asks (((price 100.1) (size 1.5))))))
    (Bbo
     ((instrument ((venue Binance) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.022000000Z))
      (recv_ts (2026-01-01 00:00:00.023000000Z)) (bid_price 99.8) (bid_size 1)
      (ask_price 100.1) (ask_size 1)))
    (Funding
     ((instrument ((venue Binance) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.030000000Z))
      (recv_ts (2026-01-01 00:00:00.031000000Z)) (rate 0.000125)
      (next_funding_time (2026-01-01 08:00:00.000000000Z)) (mark_price 100)
      (index_price 100)))
    (Trade
     ((instrument ((venue Hyperliquid) (symbol ETH)))
      (exch_ts (2026-01-01 00:00:00.040000000Z))
      (recv_ts (2026-01-01 00:00:00.041000000Z)) (price 3500.25) (size 0.1)
      (side Buy) (trade_id 40)))
    |}]
;;

(* Written by [Event_log.Writer] at the commit before the venue extension (when the venue
   type had three constructors), from a scratch git worktree, then stamped with that
   code's event digest in a file header. Never regenerate. *)
let pre_venues_dir = "fixtures/event-log-pre-venues"

let%expect_test "event log from before the venue extension still reads" =
  let store = Store.create pre_venues_dir in
  let%bind instruments = Store.instruments store in
  let day = Date.of_string "2026-01-01" in
  let%bind files =
    Deferred.List.concat_map instruments ~how:`Sequential ~f:(fun instrument ->
      Store.files store Norm instrument [ Trades; Bbo; L2; Funding ] ~from:day ~to_:day)
  in
  let%bind digests = Deferred.List.map files ~how:`Sequential ~f:Framed.read_digest in
  print_s
    [%sexp
      (List.dedup_and_sort digests ~compare:[%compare: string option]
       : string option list)];
  [%expect {| ((4cf56dfbcb69fbab68b38db7a2944d7b)) |}];
  let%map merged = Pipe.to_list (Event_log.read_merged files) in
  List.iter merged ~f:(fun e -> print_s [%sexp (e : Event.t)]);
  [%expect
    {|
    (L2
     ((instrument ((venue Hyperliquid) (symbol BTC)))
      (exch_ts (2026-01-01 00:00:00.000000000Z))
      (recv_ts (2026-01-01 00:00:00.001000000Z)) (kind Snapshot)
      (bids (((price 64999.5) (size 2)))) (asks (((price 65000.5) (size 1.5))))))
    (L2
     ((instrument ((venue Bybit) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.000000000Z))
      (recv_ts (2026-01-01 00:00:00.001000000Z)) (kind Snapshot)
      (bids (((price 64999.5) (size 2)))) (asks (((price 65000.5) (size 1.5))))))
    (Bbo
     ((instrument ((venue Hyperliquid) (symbol BTC)))
      (exch_ts (2026-01-01 00:00:00.001000000Z))
      (recv_ts (2026-01-01 00:00:00.002000000Z)) (bid_price 64999.5) (bid_size 2)
      (ask_price 65000.5) (ask_size 1.5)))
    (Bbo
     ((instrument ((venue Bybit) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.001000000Z))
      (recv_ts (2026-01-01 00:00:00.002000000Z)) (bid_price 64999.5) (bid_size 2)
      (ask_price 65000.5) (ask_size 1.5)))
    (Trade
     ((instrument ((venue Hyperliquid) (symbol BTC)))
      (exch_ts (2026-01-01 00:00:00.010000000Z))
      (recv_ts (2026-01-01 00:00:00.011000000Z)) (price 65000.5) (size 0.25)
      (side Buy) (trade_id t-1)))
    (Trade
     ((instrument ((venue Bybit) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.010000000Z))
      (recv_ts (2026-01-01 00:00:00.011000000Z)) (price 65000.5) (size 0.25)
      (side Buy) (trade_id t-1)))
    (Funding
     ((instrument ((venue Hyperliquid) (symbol BTC)))
      (exch_ts (2026-01-01 00:00:00.020000000Z))
      (recv_ts (2026-01-01 00:00:00.021000000Z)) (rate 0.0001)
      (next_funding_time (2026-01-01 08:00:00.000000000Z)) (mark_price 65000)
      (index_price 64990)))
    (Funding
     ((instrument ((venue Bybit) (symbol BTCUSDT)))
      (exch_ts (2026-01-01 00:00:00.020000000Z))
      (recv_ts (2026-01-01 00:00:00.021000000Z)) (rate 0.0001)
      (next_funding_time (2026-01-01 08:00:00.000000000Z)) (mark_price 65000)
      (index_price 64990)))
    |}]
;;

(* Written by [Event_log.Writer] at the commit before [Funding_v2] was appended to
   [Event.Stable.V1]: a Hyperliquid funding event whose [exch_ts] copies [recv_ts], one
   with its own [exch_ts], and a trade. Never regenerate. *)
let pre_funding_v2_dir = "fixtures/event-log-pre-funding-v2"

let%expect_test "event log from before funding v2 still reads, and rewrites as v2" =
  let store = Store.create pre_funding_v2_dir in
  let%bind instruments = Store.instruments store in
  let day = Date.of_string "2026-01-01" in
  let%bind files =
    Deferred.List.concat_map instruments ~how:`Sequential ~f:(fun instrument ->
      Store.files store Norm instrument [ Trades; Funding ] ~from:day ~to_:day)
  in
  let%bind digests = Deferred.List.map files ~how:`Sequential ~f:Framed.read_digest in
  print_s
    [%sexp
      (List.dedup_and_sort digests ~compare:[%compare: string option]
       : string option list)];
  [%expect {| ((2f7f1bcba79db3ddd1b04d266342a8af)) |}];
  let%bind merged = Pipe.to_list (Event_log.read_merged files) in
  let show events =
    List.iter events ~f:(fun e ->
      let wire = Event.to_stable e in
      print_s
        [%message
          ""
            ~written_as:
              ((match wire with
                | Trade _ -> "Trade"
                | Bbo _ -> "Bbo"
                | L2 _ -> "L2"
                | Funding _ -> "Funding"
                | Funding_v2 _ -> "Funding_v2")
               : string)
            ~exch_ts:(Event.exch_ts e : Time_ns.Alternate_sexp.t)
            ~recv_ts:(Event.recv_ts e : Time_ns.Alternate_sexp.t)])
  in
  show merged;
  [%expect
    {|
    ((written_as Funding_v2) (exch_ts "2026-01-01 00:00:00.001Z")
     (recv_ts "2026-01-01 00:00:00.001Z"))
    ((written_as Trade) (exch_ts "2026-01-01 00:00:00.005Z")
     (recv_ts "2026-01-01 00:00:00.006Z"))
    ((written_as Funding) (exch_ts "2026-01-01 00:00:01Z")
     (recv_ts "2026-01-01 00:00:01.001Z"))
    |}];
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter merged ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let%map again = Pipe.to_list (Event_log.read_merged (Event_log.Writer.files w)) in
    printf "same events after a rewrite: %b\n" (List.equal Event.equal merged again);
    [%expect {| same events after a rewrite: true |}])
;;

let%expect_test "the digest list starts with the current digest" =
  print_s [%sexp (Event_log.compatible_digests : string list)];
  printf
    "head is current: %b\n"
    (String.equal (List.hd_exn Event_log.compatible_digests) Event_log.digest);
  [%expect
    {|
    (cdf98830f211bb2d1384927d19dab635 2f7f1bcba79db3ddd1b04d266342a8af
     4cf56dfbcb69fbab68b38db7a2944d7b)
    head is current: true
    |}];
  return ()
;;
