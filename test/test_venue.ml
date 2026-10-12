open! Core
open Market_data

let%expect_test "venue names round trip" =
  List.iter Venue.all ~f:(fun v ->
    let s = Venue.to_string v in
    assert (Venue.equal v (Venue.of_string s));
    print_endline s);
  [%expect {|
    hyperliquid
    binance
    bybit
    |}];
  print_s [%sexp (Venue.of_string_opt "BYBIT" : Venue.t option)];
  print_s [%sexp (Venue.of_string_opt "kraken" : Venue.t option)];
  [%expect {|
    (Bybit)
    ()
    |}]
;;

let%expect_test "stream names round trip" =
  List.iter Stream.all ~f:(fun s ->
    let name = Stream.to_string s in
    assert (Stream.equal s (Stream.of_string name));
    print_endline name);
  [%expect {|
    trades
    bbo
    l2
    funding
    private
    |}]
;;

let%expect_test "instrument string form" =
  let i = Instrument.create Bybit "BTCUSDT" in
  print_endline (Instrument.to_string i);
  print_s [%sexp (i : Instrument.t)];
  assert (Instrument.equal i (Instrument.of_string (Instrument.to_string i)));
  [%expect {|
    bybit:BTCUSDT
    ((venue Bybit) (symbol BTCUSDT))
    |}]
;;
