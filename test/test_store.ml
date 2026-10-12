open! Core
open! Async
open Market_data

let%expect_test "paths" =
  let store = Store.create "/data" in
  let eth = Instrument.create Hyperliquid "ETH" in
  let day = Date.of_string "2026-03-04" in
  List.iter Store.Layer.all ~f:(fun layer ->
    print_endline (Store.path store layer eth Trades day));
  print_endline (Store.stream_dir store Raw eth L2);
  print_s [%sexp (Store.date_of_time (Sample.ts 86_399_999) : Date.t)];
  [%expect
    {|
    /data/hyperliquid/ETH/raw/trades/2026-03-04.binlog
    /data/hyperliquid/ETH/norm/trades/2026-03-04.bin
    /data/hyperliquid/ETH/raw/l2
    2026-01-01
    |}];
  return ()
;;

let%expect_test "listing days, instruments and files" =
  Sample.with_temp_dir (fun dir ->
    let store = Store.create dir in
    let eth = Instrument.create Hyperliquid "ETH" in
    let w = Event_log.Writer.create ~dir () in
    List.iter [ 0; 1; 3 ] ~f:(fun day ->
      let ms = (day * 86_400_000) + 10 in
      Event_log.Writer.append w (Trade (Sample.trade ~ms ~price:"1" ~size:"1" ()));
      Event_log.Writer.append
        w
        (Trade { (Sample.trade ~ms ~price:"1" ~size:"1" ()) with instrument = eth }));
    Event_log.Writer.append w (Bbo (Sample.bbo ~ms:(86_400_000 + 5) ~bid:"1" ~ask:"2"));
    let%bind () = Event_log.Writer.close w in
    let%bind () = Unix.mkdir ~p:() (dir ^/ "kraken/XBT") in
    let%bind () =
      Writer.save
        (Store.stream_dir store Norm Sample.btc Trades ^/ "notes.txt")
        ~contents:""
    in
    let%bind instruments = Store.instruments store in
    print_s [%sexp (List.map instruments ~f:Instrument.to_string : string list)];
    let%bind days = Store.days store Norm Sample.btc Trades in
    print_s [%sexp (days : Date.t list)];
    let%bind none = Store.days store Raw Sample.btc Trades in
    print_s [%sexp (none : Date.t list)];
    let%map files =
      Store.files
        store
        Norm
        Sample.btc
        [ Trades; Bbo ]
        ~from:(Date.of_string "2026-01-02")
        ~to_:(Date.of_string "2026-01-10")
    in
    List.iter files ~f:(fun f -> print_endline (Sample.relative ~dir f));
    [%expect
      {|
      (hyperliquid:ETH binance:BTCUSDT kraken:XBT)
      (2026-01-01 2026-01-02 2026-01-04)
      ()
      binance/BTCUSDT/norm/trades/2026-01-02.bin
      binance/BTCUSDT/norm/bbo/2026-01-02.bin
      binance/BTCUSDT/norm/trades/2026-01-04.bin
      |}])
;;

let%expect_test "symbols with a slash get one directory level" =
  let store = Store.create "/data" in
  let day = Date.of_string "2026-03-04" in
  let kraken s = Instrument.create Kraken s in
  List.iter
    [ kraken "BTC/USD"; kraken "PF_XBTUSD"; Instrument.create Hyperliquid "ETH" ]
    ~f:(fun i ->
      print_endline (Store.path store Norm i Trades day);
      print_endline (Parquet_kind.path ~dir:"/data" i Trades day));
  [%expect
    {|
    /data/kraken/BTC_USD/norm/trades/2026-03-04.bin
    /data/kraken/BTC_USD/parquet/trades/2026-03-04.parquet
    /data/kraken/PF_XBTUSD/norm/trades/2026-03-04.bin
    /data/kraken/PF_XBTUSD/parquet/trades/2026-03-04.parquet
    /data/hyperliquid/ETH/norm/trades/2026-03-04.bin
    /data/hyperliquid/ETH/parquet/trades/2026-03-04.parquet
    |}];
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter [ "BTC/USD"; "PF_XBTUSD" ] ~f:(fun s ->
      Event_log.Writer.append
        w
        (Trade { (Sample.trade ~ms:0 ~price:"1" ~size:"1" ()) with instrument = kraken s }));
    let%bind () = Event_log.Writer.close w in
    List.iter (Event_log.Writer.files w) ~f:(fun f ->
      print_endline (Sample.relative ~dir f));
    let%map instruments = Store.instruments (Store.create dir) in
    print_s [%sexp (List.map instruments ~f:Instrument.to_string : string list)];
    [%expect
      {|
      kraken/BTC_USD/norm/trades/2026-01-01.bin
      kraken/PF_XBTUSD/norm/trades/2026-01-01.bin
      (kraken:BTC/USD kraken:PF_XBTUSD)
      |}])
;;
