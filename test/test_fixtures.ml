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
            ~digest_ok:([%equal: string option] digest (Some Event_log.digest) : bool)])
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
