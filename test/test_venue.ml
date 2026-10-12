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
  [%expect {| |}]
;;
