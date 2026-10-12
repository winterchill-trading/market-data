open! Core
open Market_data

let%expect_test "trade" =
  print_endline [%bin_digest: Trade.Stable.V1.t];
  let t = Sample.trade ~ms:1_500 ~price:"113377.5" ~size:"0.012" () in
  print_s [%sexp (t : Trade.t)];
  Sample.bin_round_trip (module Trade) ~equal:Trade.equal t;
  [%expect
    {|
    8a9019c8c768525261b3aa4062600d9c
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
    8604b14f66b95d5eb8c7bb9c52fda52e
    ((mid 100.25) (spread 0.3))
    bin_io: 55 bytes, round trip true
    |}]
;;

let%expect_test "l2 update" =
  print_endline [%bin_digest: L2_update.Stable.V1.t];
  let level price size : L2_update.Level.t =
    { price = Price.of_string price; size = Size.of_string size }
  in
  let u : L2_update.t =
    { instrument = Sample.btc
    ; exch_ts = Sample.ts 0
    ; recv_ts = Sample.ts 1
    ; kind = Delta
    ; bids = [ level "100" "2"; level "99.5" "0" ]
    ; asks = [ level "100.5" "1" ]
    }
  in
  print_s [%sexp (u.bids : L2_update.Level.t list)];
  Sample.bin_round_trip (module L2_update) ~equal:L2_update.equal u;
  [%expect
    {|
    3187cac79dfac0af257cb77677526f66
    (((price 100) (size 2)) ((price 99.5) (size 0)))
    bin_io: 68 bytes, round trip true
    |}]
;;

let%expect_test "funding" =
  print_endline [%bin_digest: Funding.Stable.V1.t];
  let f : Funding.t =
    { instrument = Sample.btc
    ; exch_ts = Sample.ts 0
    ; recv_ts = Sample.ts 3
    ; rate = 0.000125
    ; next_funding_time = Sample.ts 3_600_000
    ; mark_price = Price.of_string "100.2"
    ; index_price = Price.of_string "100.18"
    }
  in
  print_s [%sexp (f.next_funding_time : Time_ns.Alternate_sexp.t)];
  Sample.bin_round_trip (module Funding) ~equal:Funding.equal f;
  [%expect
    {|
    48ddfc47956585cccc7e97fc8526009f
    "2026-01-01 01:00:00Z"
    bin_io: 62 bytes, round trip true
    |}]
;;

let%expect_test "candle" =
  print_endline [%bin_digest: Candle.Stable.V1.t];
  let p = Price.of_string in
  let c : Candle.t =
    { instrument = Sample.btc
    ; interval = Time_ns.Span.minute
    ; open_time = Sample.ts 0
    ; open_ = p "100"
    ; high = p "101"
    ; low = p "99"
    ; close = p "100.5"
    ; volume = Size.of_string "12.25"
    ; trade_count = 42
    }
  in
  print_s [%sexp (c : Candle.t)];
  print_s [%sexp (Candle.close_time c : Time_ns.Alternate_sexp.t)];
  Sample.bin_round_trip (module Candle) ~equal:Candle.equal c;
  [%expect
    {|
    e5ca1ead96dc7aa7036acd969e8625fb
    ((instrument ((venue Binance) (symbol BTCUSDT))) (interval 1m)
     (open_time (2026-01-01 00:00:00.000000000Z)) (open_ 100) (high 101)
     (low 99) (close 100.5) (volume 12.25) (trade_count 42))
    "2026-01-01 00:01:00Z"
    bin_io: 69 bytes, round trip true
    |}]
;;
