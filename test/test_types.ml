open! Core
open Market_data

let%expect_test "trade" =
  print_endline [%bin_digest: Trade.Stable.V1.t];
  let t = Sample.trade ~ms:1_500 ~price:"113377.5" ~size:"0.012" () in
  print_s [%sexp (t : Trade.t)];
  Sample.bin_round_trip (module Trade) ~equal:Trade.equal t;
  [%expect
    {|
    73a9af9ebd8c5fa1db2af823f730850f
    ((instrument ((venue Binance) (symbol BTCUSDT)))
     (exch_ts (2026-01-01 00:00:01.500000000Z))
     (recv_ts (2026-01-01 00:00:01.501000000Z)) (price 113377.5) (size 0.012)
     (side Buy) (trade_id 1500))
    bin_io: 47 bytes, round trip true
    |}]
;;

let%expect_test "bbo" =
  print_endline [%bin_digest: Bbo.Stable.V1.t];
  let b : Bbo.t =
    { instrument = Sample.btc
    ; exch_ts = Sample.ts 0
    ; recv_ts = Sample.ts 2
    ; bid_price = Price.of_string "100.1"
    ; bid_size = Size.of_string "3"
    ; ask_price = Price.of_string "100.4"
    ; ask_size = Size.of_string "1.5"
    }
  in
  print_s [%message "" ~mid:(Bbo.mid b : Price.t) ~spread:(Bbo.spread b : Price.t)];
  Sample.bin_round_trip (module Bbo) ~equal:Bbo.equal b;
  [%expect
    {|
    0d94a08074b73d849c735b2e66b6e8f5
    ((mid 100.25) (spread 0.3))
    bin_io: 55 bytes, round trip true
    |}]
;;
