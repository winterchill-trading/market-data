open! Core
open! Async
open Market_data

let bbo ?(instrument = Sample.btc) ~ms ~bid ~ask () =
  Event.Bbo { (Sample.bbo ~ms ~bid ~ask) with instrument }
;;

let i = Instrument.create

(* PEPE quoted per 1000 on binance, bybit and hyperliquid; BTC per coin everywhere. *)
let events : Event.t list =
  [ bbo ~ms:0 ~bid:"100" ~ask:"101" ()
  ; Trade (Sample.trade ~ms:5 ~id:"t1" ~price:"101" ~size:"1" ())
  ; bbo ~ms:10 ~bid:"100.5" ~ask:"101.5" ()
  ; Trade (Sample.trade ~ms:20 ~id:"t2" ~price:"100.5" ~size:"2" ())
  ; bbo ~instrument:(i Okx "BTC-USDT-SWAP") ~ms:3 ~bid:"100.6" ~ask:"101.4" ()
  ; bbo ~instrument:(i Binance "1000PEPEUSDT") ~ms:1 ~bid:"0.0100" ~ask:"0.0102" ()
  ; bbo ~instrument:(i Bybit "1000PEPEUSDT") ~ms:1 ~bid:"0.01005" ~ask:"0.01015" ()
  ; bbo ~instrument:(i Hyperliquid "kPEPE") ~ms:1 ~bid:"0.010095" ~ask:"0.010105" ()
  ]
;;

let query ~dir sql =
  match%map Parquet_views.query ~format:Csv ~dir sql with
  | Ok out -> print_string out
  | Error e -> print_s [%sexp (e : Error.t)]
;;

let%expect_test "derived views" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let%bind (_ : Day_close.Result.t list) =
      Day_close.run ~dir (Date.of_string "2026-01-01")
    in
    let%bind () =
      query
        ~dir
        "SELECT trade_id, price, bbo_recv_ts, bid_price, ask_price FROM trades_with_bbo \
         ORDER BY recv_ts"
    in
    [%expect
      {|
      trade_id,price,bbo_recv_ts,bid_price,ask_price
      t1,101.00000000,2026-01-01 00:00:00.001,100.00000000,101.00000000
      t2,100.50000000,2026-01-01 00:00:00.011,100.50000000,101.50000000
      |}];
    let%bind () =
      query
        ~dir
        "SELECT table_name, venue, symbol, n, p50_ms, p99_ms FROM lag ORDER BY ALL"
    in
    [%expect
      {|
      table_name,venue,symbol,n,p50_ms,p99_ms
      bbo,binance,1000PEPEUSDT,1,1.0,1.0
      bbo,binance,BTCUSDT,2,1.0,1.0
      bbo,bybit,1000PEPEUSDT,1,1.0,1.0
      bbo,hyperliquid,kPEPE,1,1.0,1.0
      bbo,okx,BTC-USDT-SWAP,1,1.0,1.0
      trades,binance,BTCUSDT,2,1.0,1.0
      |}];
    let%bind () =
      query
        ~dir
        "SELECT token, venue, symbol, round(mid, 10) AS mid FROM token_bbo ORDER BY ALL"
    in
    [%expect
      {|
      token,venue,symbol,mid
      BTC,binance,BTCUSDT,100.5
      BTC,binance,BTCUSDT,101.0
      BTC,okx,BTC-USDT-SWAP,101.0
      PEPE,binance,1000PEPEUSDT,1.01e-05
      PEPE,bybit,1000PEPEUSDT,1.01e-05
      PEPE,hyperliquid,kPEPE,1.01e-05
      |}];
    (* Per-token mids agree across venues within 1%. *)
    let%bind () =
      query
        ~dir
        "SELECT token, count(DISTINCT venue) AS venues, max(mid) / min(mid) - 1 < 0.01 \
         AS agree FROM token_bbo GROUP BY token ORDER BY token"
    in
    [%expect {|
      token,venues,agree
      BTC,2,true
      PEPE,3,true
      |}];
    return ())
;;

let%expect_test "a units csv replaces defaults" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let%bind (_ : Day_close.Result.t list) =
      Day_close.run ~dir (Date.of_string "2026-01-01")
    in
    let%bind () =
      Writer.save
        (dir ^/ "units_per_contract.csv")
        ~contents:
          "venue,symbol,token,units_per_contract,units_per_price\n\
           hyperliquid,kPEPE,KPEPE,1,1\n"
    in
    let%bind () =
      query
        ~dir
        "SELECT * FROM units_per_contract WHERE venue = 'hyperliquid' ORDER BY ALL"
    in
    [%expect
      {|
      venue,symbol,token,units_per_contract,units_per_price
      hyperliquid,BTC,BTC,1.0,1.0
      hyperliquid,ETH,ETH,1.0,1.0
      hyperliquid,kPEPE,KPEPE,1.0,1.0
      |}];
    return ())
;;
