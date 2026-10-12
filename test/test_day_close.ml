open! Core
open! Async
open Market_data

let eth = Instrument.create Hyperliquid "ETH"
let minute = 60_000

let level price size : L2_update.Level.t =
  { price = Price.of_string price; size = Size.of_string size }
;;

let l2 ~ms ~kind ~bids ~asks : L2_update.t =
  { instrument = Sample.btc
  ; exch_ts = Sample.ts ms
  ; recv_ts = Sample.ts (ms + 1)
  ; kind
  ; bids
  ; asks
  }
;;

let events : Event.t list =
  [ L2
      (l2
         ~ms:0
         ~kind:Snapshot
         ~bids:[ level "99.9" "1"; level "99.8" "3" ]
         ~asks:[ level "100.1" "2" ])
  ; Bbo (Sample.bbo ~ms:1 ~bid:"99.9" ~ask:"100.1")
  ; Trade (Sample.trade ~ms:10 ~price:"100.1" ~size:"0.5" ())
  ; Trade (Sample.trade ~side:Sell ~ms:20 ~price:"99.9" ~size:"1.25" ())
  ; L2 (l2 ~ms:21 ~kind:Delta ~bids:[ level "99.9" "0" ] ~asks:[])
  ; Funding (Sample.funding ~ms:30 ~rate:0.000125)
  ; Trade (Sample.trade ~ms:(minute + 5) ~price:"100.3" ~size:"2" ())
  ; Trade { (Sample.trade ~ms:40 ~price:"3500.25" ~size:"0.1" ()) with instrument = eth }
  ; Trade (Sample.trade ~ms:86_400_000 ~price:"101" ~size:"1" ())
  ]
;;

let day = Date.of_string "2026-01-01"

let write_log ~dir =
  let w = Event_log.Writer.create ~dir () in
  List.iter events ~f:(Event_log.Writer.append w);
  Event_log.Writer.close w
;;

let print_results ~dir results =
  List.iter results ~f:(fun (r : Day_close.Result.t) ->
    match r.outcome with
    | No_source -> ()
    | outcome ->
      printf
        "%s %s\n"
        (Sample.relative ~dir r.path)
        (Sexp.to_string [%sexp (outcome : Day_close.Outcome.t)]))
;;

let query ~dir sql =
  match%map Parquet_views.query ~format:Csv ~dir sql with
  | Ok out -> print_string out
  | Error e -> print_s [%sexp (e : Error.t)]
;;

let%expect_test "day close writes every table and duckdb reads them" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_log ~dir in
    let%bind results = Day_close.run ~dir day in
    print_results ~dir results;
    [%expect
      {|
      hyperliquid/ETH/parquet/trades/2026-01-01.parquet (Written(rows 1)(tail Clean))
      hyperliquid/ETH/parquet/candles/2026-01-01.parquet (Written(rows 1)(tail Clean))
      binance/BTCUSDT/parquet/trades/2026-01-01.parquet (Written(rows 3)(tail Clean))
      binance/BTCUSDT/parquet/bbo/2026-01-01.parquet (Written(rows 1)(tail Clean))
      binance/BTCUSDT/parquet/l2/2026-01-01.parquet (Written(rows 4)(tail Clean))
      binance/BTCUSDT/parquet/funding/2026-01-01.parquet (Written(rows 1)(tail Clean))
      binance/BTCUSDT/parquet/candles/2026-01-01.parquet (Written(rows 2)(tail Clean))
      |}];
    let%bind () =
      query
        ~dir
        "SELECT venue, symbol, count(*) AS n, sum(size) AS volume, max(price) AS high \
         FROM trades GROUP BY ALL ORDER BY ALL"
    in
    [%expect
      {|
      venue,symbol,n,volume,high
      binance,BTCUSDT,3,3.75000000,100.30000000
      hyperliquid,ETH,1,0.10000000,3500.25000000
      |}];
    let%bind () = query ~dir "SELECT column_name, column_type FROM (DESCRIBE trades)" in
    [%expect
      {|
      column_name,column_type
      venue,VARCHAR
      symbol,VARCHAR
      exch_ts,TIMESTAMP_NS
      recv_ts,TIMESTAMP_NS
      price,"DECIMAL(18,8)"
      size,"DECIMAL(18,8)"
      side,VARCHAR
      trade_id,VARCHAR
      |}];
    let%bind () =
      query ~dir "SELECT seq, is_snapshot, side, level, price, size FROM l2 ORDER BY ALL"
    in
    [%expect
      {|
      seq,is_snapshot,side,level,price,size
      0,true,ask,0,100.10000000,2.00000000
      0,true,bid,0,99.90000000,1.00000000
      0,true,bid,1,99.80000000,3.00000000
      1,false,bid,0,99.90000000,0.00000000
      |}];
    let%bind () =
      query
        ~dir
        "SELECT recv_ts, bid_price, ask_price, ask_price - bid_price AS spread FROM bbo"
    in
    [%expect
      {|
      recv_ts,bid_price,ask_price,spread
      2026-01-01 00:00:00.002,99.90000000,100.10000000,0.20000000
      |}];
    let%bind () = query ~dir "SELECT exch_ts, rate, mark_price FROM funding" in
    [%expect
      {|
      exch_ts,rate,mark_price
      2026-01-01 00:00:00.03,0.000125,100.00000000
      |}];
    let%bind () =
      query
        ~dir
        "SELECT symbol, open_time, open, high, low, close, volume, trade_count FROM \
         candles ORDER BY ALL"
    in
    [%expect
      {|
      symbol,open_time,open,high,low,close,volume,trade_count
      BTCUSDT,2026-01-01 00:00:00,100.10000000,100.10000000,99.90000000,99.90000000,1.75000000,2
      BTCUSDT,2026-01-01 00:01:00,100.30000000,100.30000000,100.30000000,100.30000000,2.00000000,1
      ETH,2026-01-01 00:00:00,3500.25000000,3500.25000000,3500.25000000,3500.25000000,0.10000000,1
      |}];
    return ())
;;

let%expect_test "day close is idempotent and replaces sink parts" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_log ~dir in
    let%bind (_ : Day_close.Result.t list) = Day_close.run ~dir day in
    let%bind results = Day_close.run ~dir day in
    print_results ~dir results;
    [%expect
      {|
      hyperliquid/ETH/parquet/trades/2026-01-01.parquet Up_to_date
      hyperliquid/ETH/parquet/candles/2026-01-01.parquet Up_to_date
      binance/BTCUSDT/parquet/trades/2026-01-01.parquet Up_to_date
      binance/BTCUSDT/parquet/bbo/2026-01-01.parquet Up_to_date
      binance/BTCUSDT/parquet/l2/2026-01-01.parquet Up_to_date
      binance/BTCUSDT/parquet/funding/2026-01-01.parquet Up_to_date
      binance/BTCUSDT/parquet/candles/2026-01-01.parquet Up_to_date
      |}];
    let part = Parquet_kind.kind_dir ~dir Sample.btc Trades ^/ "2026-01-01.1.parquet" in
    let%bind () = Writer.save part ~contents:"" in
    let%bind results = Day_close.run ~force:true ~instruments:[ Sample.btc ] ~dir day in
    print_results ~dir results;
    let%bind exists = Sys.file_exists_exn part in
    printf "part left: %b\n" exists;
    [%expect
      {|
      binance/BTCUSDT/parquet/trades/2026-01-01.parquet (Written(rows 3)(tail Clean))
      binance/BTCUSDT/parquet/bbo/2026-01-01.parquet (Written(rows 1)(tail Clean))
      binance/BTCUSDT/parquet/l2/2026-01-01.parquet (Written(rows 4)(tail Clean))
      binance/BTCUSDT/parquet/funding/2026-01-01.parquet (Written(rows 1)(tail Clean))
      binance/BTCUSDT/parquet/candles/2026-01-01.parquet (Written(rows 2)(tail Clean))
      part left: false
      |}];
    return ())
;;

let%expect_test "manifests decide what is up to date" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_log ~dir in
    let run () =
      let%map results = Day_close.run ~instruments:[ Sample.btc ] ~dir day in
      List.iter results ~f:(fun (r : Day_close.Result.t) ->
        printf
          "%s %s\n"
          (Parquet_kind.to_string r.kind)
          (Sexp.to_string [%sexp (r.outcome : Day_close.Outcome.t)]))
    in
    let%bind () = run () in
    let trades = Parquet_kind.path ~dir Sample.btc Trades day in
    let%bind manifest = Day_close.Manifest.load trades in
    let manifest = Option.value_exn manifest in
    print_s
      [%message
        ""
          ~inputs:
            (List.map manifest.inputs ~f:(fun i -> i.path, i.size) : (string * int) list)
          ~output:(manifest.output : string)
          ~has_bytes:(manifest.output_bytes > 0 : bool)
          ~rows:(manifest.rows : int)
          ~version_ok:
            (String.equal manifest.code_version Day_close.Manifest.code_version : bool)];
    [%expect
      {|
      trades (Written(rows 3)(tail Clean))
      bbo (Written(rows 1)(tail Clean))
      l2 (Written(rows 4)(tail Clean))
      funding (Written(rows 1)(tail Clean))
      candles (Written(rows 2)(tail Clean))
      ((inputs ((binance/BTCUSDT/norm/trades/2026-01-01.bin 205)))
       (output binance/BTCUSDT/parquet/trades/2026-01-01.parquet) (has_bytes true)
       (rows 3) (version_ok true))
      |}];
    let%bind () = run () in
    [%expect
      {|
      trades Up_to_date
      bbo Up_to_date
      l2 Up_to_date
      funding Up_to_date
      candles Up_to_date
      |}];
    (* New events for the day change the trades input only. *)
    let w = Event_log.Writer.create ~dir () in
    Event_log.Writer.append w (Trade (Sample.trade ~ms:50 ~price:"100" ~size:"1" ()));
    let%bind () = Event_log.Writer.close w in
    let%bind () = run () in
    [%expect
      {|
      trades (Written(rows 4)(tail Clean))
      bbo Up_to_date
      l2 Up_to_date
      funding Up_to_date
      candles (Written(rows 2)(tail Clean))
      |}];
    (* A table from before manifests existed is rebuilt. *)
    let%bind () = Unix.unlink (Day_close.Manifest.path trades) in
    let%bind () = run () in
    [%expect
      {|
      trades (Written(rows 4)(tail Clean))
      bbo Up_to_date
      l2 Up_to_date
      funding Up_to_date
      candles Up_to_date
      |}];
    return ())
;;
