open! Core
open! Async
open Market_data

let files =
  [ "fixtures/event-log-v1/binance/BTCUSDT/norm/trades/2026-01-01.bin"
  ; "fixtures/event-log-v1/binance/BTCUSDT/norm/bbo/2026-01-01.bin"
  ; "fixtures/event-log-v1/binance/BTCUSDT/norm/l2/2026-01-01.bin"
  ; "fixtures/event-log-v1/binance/BTCUSDT/norm/funding/2026-01-01.bin"
  ; "fixtures/event-log-v1/hyperliquid/ETH/norm/trades/2026-01-01.bin"
  ]
;;

let%expect_test "dump prints one line per event in recv_ts order" =
  let%map () = Event_dump.print files in
  [%expect
    {|
    2026-01-01T00:00:00.001000000Z binance:BTCUSDT l2 snapshot bids=[99.9 x 1, 99.8 x 3] asks=[100.1 x 2, 100.2 x 4]
    2026-01-01T00:00:00.002000000Z binance:BTCUSDT bbo 99.9 x 1 / 100.1 x 1
    2026-01-01T00:00:00.011000000Z binance:BTCUSDT trades buy 0.5 @ 100.1 id=10
    2026-01-01T00:00:00.021000000Z binance:BTCUSDT trades sell 1.25 @ 99.9 id=20
    2026-01-01T00:00:00.022000000Z binance:BTCUSDT l2 delta bids=[99.9 x 0] asks=[100.1 x 1.5]
    2026-01-01T00:00:00.023000000Z binance:BTCUSDT bbo 99.8 x 1 / 100.1 x 1
    2026-01-01T00:00:00.031000000Z binance:BTCUSDT funding rate=0.000125 mark=100 index=100 next=2026-01-01T08:00:00.000000000Z
    2026-01-01T00:00:00.041000000Z hyperliquid:ETH trades buy 0.1 @ 3500.25 id=40
    |}]
;;

let%expect_test "book at a time" =
  let%bind () =
    Deferred.List.iter ~how:`Sequential [ 0; 1; 21; 22; 1_000 ] ~f:(fun ms ->
      let%map books = Event_dump.book_at files ~at:(Sample.ts ms) in
      printf "at %dms: %d book(s)\n" ms (List.length books);
      List.iter books ~f:(fun (i, b) ->
        printf "%s\n%s" (Instrument.to_string i) (L2_book.to_string_hum b)))
  in
  [%expect
    {|
    at 0ms: 0 book(s)
    at 1ms: 1 book(s)
    binance:BTCUSDT
    ask  100.2  4
    ask  100.1  2
    bid   99.9  1
    bid   99.8  3
    at 21ms: 1 book(s)
    binance:BTCUSDT
    ask  100.2  4
    ask  100.1  2
    bid   99.9  1
    bid   99.8  3
    at 22ms: 1 book(s)
    binance:BTCUSDT
    ask  100.2  4
    ask  100.1  1.5
    bid   99.8  3
    at 1000ms: 1 book(s)
    binance:BTCUSDT
    ask  100.2  4
    ask  100.1  1.5
    bid   99.8  3
    |}];
  return ()
;;
