open! Core
open! Async
open Market_data

let day = Date.of_string "2026-01-01"
let eth = Instrument.create Hyperliquid "ETH"
let unknown = Instrument.create Bybit "NOTLISTED"

let events : Event.t list =
  [ Trade (Sample.trade ~ms:10 ~price:"100.1" ~size:"0.5" ())
  ; Bbo (Sample.bbo ~ms:11 ~bid:"99.9" ~ask:"100.1")
  ; Funding (Sample.funding ~ms:30 ~rate:0.000125)
  ; Trade { (Sample.trade ~ms:40 ~price:"3500.25" ~size:"0.1" ()) with instrument = eth }
  ; Trade { (Sample.trade ~ms:50 ~price:"1" ~size:"1" ()) with instrument = unknown }
    (* the next day: not part of [day]'s universe *)
  ; Trade
      { (Sample.trade ~ms:86_400_000 ~price:"3501" ~size:"1" ()) with
        instrument = Instrument.create Hyperliquid "BTC"
      }
  ]
;;

let%expect_test "the instruments table lists the day's universe with catalogue facts" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let%bind rows = Instruments_table.rows ~dir day in
    List.iter rows ~f:(fun (r : Instruments_table.Row.t) ->
      print_s
        [%message
          ""
            ~instrument:(r.instrument : Instrument.t)
            ~streams:(r.streams : Stream.t list)
            ~in_catalogue:(Option.is_some r.info : bool)]);
    [%expect
      {|
      ((instrument ((venue Hyperliquid) (symbol ETH))) (streams (Trades))
       (in_catalogue true))
      ((instrument ((venue Binance) (symbol BTCUSDT)))
       (streams (Trades Bbo Funding)) (in_catalogue true))
      ((instrument ((venue Bybit) (symbol NOTLISTED))) (streams (Trades))
       (in_catalogue false))
      |}];
    let%bind n = Instruments_table.write ~dir day in
    printf "rows %d, %s\n" n (Sample.relative ~dir (Instruments_table.path ~dir day));
    [%expect {| rows 3, instruments/2026-01-01.parquet |}];
    let%bind empty = Instruments_table.write ~dir (Date.of_string "2025-12-31") in
    printf "empty day: %d rows\n" empty;
    [%expect {| empty day: 0 rows |}];
    let%bind () =
      match%map
        Parquet_views.query
          ~format:Csv
          ~dir
          "SELECT date, venue, symbol, streams, in_catalogue, kind, base, quote, \
           size_unit, units_per_contract, funding_interval_s, tick, lot FROM instruments \
           ORDER BY venue, symbol"
      with
      | Ok out -> print_string out
      | Error e -> print_s [%sexp (e : Error.t)]
    in
    [%expect
      {|
      date,venue,symbol,streams,in_catalogue,kind,base,quote,size_unit,units_per_contract,funding_interval_s,tick,lot
      2026-01-01,binance,BTCUSDT,"trades,bbo,funding",true,perp,BTC,USDT,base,1.0,28800,0.10000000,0.00100000
      2026-01-01,bybit,NOTLISTED,trades,false,,,,,nan,0,0.00000000,0.00000000
      2026-01-01,hyperliquid,ETH,trades,true,perp,ETH,USD,base,1.0,3600,0.10000000,0.00010000
      |}];
    return ())
;;
