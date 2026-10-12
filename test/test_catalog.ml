open! Core
open! Async
open Market_data

let eth = Instrument.create Hyperliquid "ETH"
let day = 86_400_000

let events : Event.t list =
  [ Trade (Sample.trade ~ms:0 ~price:"100" ~size:"1" ())
  ; Bbo (Sample.bbo ~ms:5 ~bid:"99" ~ask:"101")
  ; Trade { (Sample.trade ~ms:10 ~price:"3500" ~size:"1" ()) with instrument = eth }
  ; Trade (Sample.trade ~ms:(day + 10) ~price:"101" ~size:"1" ())
  ; Trade (Sample.trade ~ms:((2 * day) + 10) ~price:"102" ~size:"1" ())
  ]
;;

let%expect_test "catalog of tables" =
  Sample.with_temp_dir (fun dir ->
    let%bind () =
      let%map entries = Catalog.scan ~dir in
      print_string (Catalog.to_string_hum entries)
    in
    [%expect {| table  venues  symbols  first  last  files  parts |}];
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let%bind () =
      Deferred.List.iter ~how:`Sequential [ "2026-01-01"; "2026-01-02" ] ~f:(fun d ->
        Day_close.run ~dir (Date.of_string d) |> Deferred.ignore_m)
    in
    let trades = Parquet_kind.kind_dir ~dir Sample.btc Trades in
    let%bind () = Writer.save (trades ^/ "2026-01-03.parquet") ~contents:"" in
    let%bind () = Writer.save (trades ^/ "2026-01-03.1.parquet") ~contents:"" in
    let%bind () = Writer.save (trades ^/ "notes.txt") ~contents:"" in
    let%map entries = Catalog.scan ~dir in
    print_string (Catalog.to_string_hum entries);
    [%expect
      {|
      table    venues               symbols  first       last        files  parts
      trades   hyperliquid,binance  2        2026-01-01  2026-01-03  5      1
      bbo      binance              1        2026-01-01  2026-01-01  1      0
      candles  hyperliquid,binance  2        2026-01-01  2026-01-02  3      0
      leftover part: binance/BTCUSDT/parquet/trades/2026-01-03.1.parquet
      |}])
;;
