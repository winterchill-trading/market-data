open! Core
open Market_data

let print_candles candles =
  List.iter candles ~f:(fun (c : Candle.t) ->
    printf
      !"%{Time_ns.to_string_utc} o=%{Price} h=%{Price} l=%{Price} c=%{Price} v=%{Size} \
        n=%d\n"
      c.open_time
      c.open_
      c.high
      c.low
      c.close
      c.volume
      c.trade_count)
;;

let%expect_test "one minute candles with a gap" =
  let trades =
    [ Sample.trade ~ms:1_000 ~price:"100" ~size:"1" ()
    ; Sample.trade ~ms:20_000 ~price:"102" ~size:"0.5" ()
    ; Sample.trade ~ms:59_999 ~price:"99" ~size:"2" ()
    ; Sample.trade ~ms:200_000 ~price:"101" ~size:"1" ()
    ; Sample.trade ~ms:190_000 ~price:"103" ~size:"1" ()
    ]
  in
  print_candles (Candle_agg.of_trades Sample.btc ~interval:Time_ns.Span.minute trades);
  [%expect
    {|
    2026-01-01 00:00:00.000000000Z o=100 h=102 l=99 c=99 v=3.5 n=3
    2026-01-01 00:01:00.000000000Z o=99 h=99 l=99 c=99 v=0 n=0
    2026-01-01 00:02:00.000000000Z o=99 h=99 l=99 c=99 v=0 n=0
    2026-01-01 00:03:00.000000000Z o=101 h=103 l=101 c=103 v=2 n=2
    |}]
;;

let%expect_test "interval validation" =
  let try_ span =
    match Candle_agg.create Sample.btc ~interval:span with
    | (_ : Candle_agg.t) -> print_endline "ok"
    | exception _ -> print_endline "rejected"
  in
  List.iter
    Time_ns.Span.
      [ of_int_ms 500; second; of_int_sec 7; minute; of_int_sec 900; day; day + day ]
    ~f:try_;
  [%expect {|
    rejected
    ok
    rejected
    ok
    ok
    ok
    rejected
    |}]
;;

let trades_gen =
  let open Quickcheck.Generator.Let_syntax in
  let trade =
    let%map gap_ms = Int.gen_incl 0 300_000
    and price = Int.gen_incl 1 1_000_000
    and size = Int.gen_incl 1 1_000_000 in
    gap_ms, price, size
  in
  let%map steps = List.gen_non_empty trade in
  let _, trades =
    List.fold_map steps ~init:0 ~f:(fun ms (gap_ms, price, size) ->
      let ms = ms + gap_ms in
      ( ms
      , Sample.trade
          ~ms
          ~price:(Int.to_string price ^ ".25")
          ~size:("0.0" ^ Int.to_string size)
          () ))
  in
  trades
;;

let interval_gen =
  Quickcheck.Generator.of_list
    Time_ns.Span.[ second; of_int_sec 5; minute; of_int_sec 900; hour; day ]
;;

let%test_unit "quickcheck: candle invariants" =
  Quickcheck.test
    ~trials:500
    ~sexp_of:[%sexp_of: Time_ns.Span.t * Trade.t list]
    (Quickcheck.Generator.both interval_gen trades_gen)
    ~f:(fun (interval, trades) ->
      let candles = Candle_agg.of_trades Sample.btc ~interval trades in
      List.iter candles ~f:(fun (c : Candle.t) ->
        assert (Price.(c.high >= max c.open_ c.close));
        assert (Price.(c.low <= min c.open_ c.close));
        assert (Time_ns.equal c.open_time (Candle_agg.align c.open_time ~interval)));
      [%test_result: Size.t]
        (Size.sum (List.map candles ~f:Candle.volume))
        ~expect:(Size.sum (List.map trades ~f:Trade.size));
      [%test_result: int]
        (List.sum (module Int) candles ~f:Candle.trade_count)
        ~expect:(List.length trades);
      (* contiguous: no missing intervals, each opens at the previous close *)
      List.iter
        (List.zip_exn (List.drop_last_exn candles) (List.tl_exn candles))
        ~f:(fun (a, b) ->
          assert (Time_ns.equal b.open_time (Candle.close_time a));
          if b.trade_count = 0 then assert (Price.equal b.open_ a.close)))
;;
