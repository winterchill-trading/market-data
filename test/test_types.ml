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
