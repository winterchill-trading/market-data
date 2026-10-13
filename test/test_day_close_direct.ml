open! Core
open! Async
open Market_data

let day = Date.of_string "2026-01-01"
let eth = Instrument.create Hyperliquid "ETH"
let px k = Price.of_string (sprintf "%d.%04d" (1_000 + (k % 997)) (k * 37 % 10_000))
let sz k = Size.of_string (sprintf "%d.%03d" (k % 5) (1 + (k * 13 % 999)))

(* A few thousand events of every kind over the day, for two instruments. *)
let events =
  List.init 3_000 ~f:(fun k ->
    let instrument = if k % 4 = 0 then eth else Sample.btc in
    let ms = k * 28_000 in
    let exch_ts = Sample.ts ms
    and recv_ts = Sample.ts (ms + 3) in
    match k % 4 with
    | 0 | 1 ->
      Event.Trade
        { instrument
        ; exch_ts
        ; recv_ts
        ; price = px k
        ; size = sz k
        ; side = (if k % 3 = 0 then Sell else Buy)
        ; trade_id = Int.to_string k
        }
    | 2 ->
      Bbo
        { instrument
        ; exch_ts
        ; recv_ts
        ; bid_price = px k
        ; bid_size = sz k
        ; ask_price = px (k + 1)
        ; ask_size = sz (k + 1)
        }
    | _ when k % 40 = 3 ->
      Funding
        { instrument
        ; exch_ts
        ; recv_ts
        ; rate = Float.of_int ((k % 11) - 5) *. 1e-5
        ; next_funding_time = Sample.ts (ms + 3_600_000)
        ; mark_price = px k
        ; index_price = px (k + 2)
        }
    | _ ->
      let levels n =
        List.init n ~f:(fun i ->
          { L2_update.Level.price = px (k + i); size = sz (k * i) })
      in
      L2
        { instrument
        ; exch_ts
        ; recv_ts
        ; kind = (if k % 50 = 3 then Snapshot else Delta)
        ; bids = levels (k % 6)
        ; asks = levels (k % 5)
        })
;;

(* The conversion before [Parquet_schemas.Direct]: rows built per event, written through
   the schema accessors. *)
let reference_rows instrument (kind : Parquet_kind.t) events =
  let mine (e : Event.t) = Instrument.equal (Event.instrument e) instrument in
  let events = List.filter events ~f:mine in
  match kind with
  | Trades ->
    `Trade
      (List.filter_map events ~f:(function
        | Event.Trade t -> Some t
        | _ -> None))
  | Bbo ->
    `Bbo
      (List.filter_map events ~f:(function
        | Event.Bbo b -> Some b
        | _ -> None))
  | Funding ->
    `Funding
      (List.filter_map events ~f:(function
        | Event.Funding f -> Some f
        | _ -> None))
  | L2 ->
    `L2
      (List.filter_map events ~f:(function
         | Event.L2 u -> Some u
         | _ -> None)
       |> List.concat_mapi ~f:(fun seq u -> Parquet_schemas.L2_row.of_update ~seq u))
  | Candles ->
    let agg = Candle_agg.create instrument ~interval:Time_ns.Span.minute in
    let closed =
      List.concat_map events ~f:(function
        | Event.Trade t -> Candle_agg.add agg t
        | _ -> [])
    in
    `Candle (closed @ Option.to_list (Candle_agg.current agg))
;;

let write_reference ~compression ~row_group_rows path rows =
  let write schema rows =
    Parquet.Writer.with_file ~schema ~compression ~row_group_rows path ~f:(fun w ->
      Parquet.Writer.add_all w rows)
  in
  match rows with
  | `Trade rows -> write Parquet_schemas.trade rows
  | `Bbo rows -> write Parquet_schemas.bbo rows
  | `Funding rows -> write Parquet_schemas.funding rows
  | `L2 rows -> write Parquet_schemas.l2 rows
  | `Candle rows -> write Parquet_schemas.candle rows
;;

let%expect_test "day close writes the same bytes as the schema path" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let%map () =
      Deferred.List.iter
        ~how:`Sequential
        [ `None, 64; `Zstd, 64; `Zstd, Day_close.default_row_group_rows ]
        ~f:(fun (compression, row_group_rows) ->
          let%map results =
            Day_close.run ~compression ~row_group_rows ~force:true ~dir day
          in
          List.iter results ~f:(fun (r : Day_close.Result.t) ->
            match r.outcome with
            | No_source | Up_to_date -> ()
            | Written { rows; _ } ->
              let reference = dir ^/ "reference.parquet" in
              write_reference
                ~compression
                ~row_group_rows
                reference
                (reference_rows r.instrument r.kind events);
              let same =
                String.equal (In_channel.read_all reference) (In_channel.read_all r.path)
              in
              printf
                "%s %d rows: %s\n"
                (Sample.relative ~dir r.path)
                rows
                (if same then "identical" else "DIFFERENT")))
    in
    [%expect
      {|
      hyperliquid/ETH/parquet/trades/2026-01-01.parquet 750 rows: identical
      hyperliquid/ETH/parquet/candles/2026-01-01.parquet 1399 rows: identical
      binance/BTCUSDT/parquet/trades/2026-01-01.parquet 750 rows: identical
      binance/BTCUSDT/parquet/bbo/2026-01-01.parquet 750 rows: identical
      binance/BTCUSDT/parquet/l2/2026-01-01.parquet 3300 rows: identical
      binance/BTCUSDT/parquet/funding/2026-01-01.parquet 75 rows: identical
      binance/BTCUSDT/parquet/candles/2026-01-01.parquet 1399 rows: identical
      hyperliquid/ETH/parquet/trades/2026-01-01.parquet 750 rows: identical
      hyperliquid/ETH/parquet/candles/2026-01-01.parquet 1399 rows: identical
      binance/BTCUSDT/parquet/trades/2026-01-01.parquet 750 rows: identical
      binance/BTCUSDT/parquet/bbo/2026-01-01.parquet 750 rows: identical
      binance/BTCUSDT/parquet/l2/2026-01-01.parquet 3300 rows: identical
      binance/BTCUSDT/parquet/funding/2026-01-01.parquet 75 rows: identical
      binance/BTCUSDT/parquet/candles/2026-01-01.parquet 1399 rows: identical
      hyperliquid/ETH/parquet/trades/2026-01-01.parquet 750 rows: identical
      hyperliquid/ETH/parquet/candles/2026-01-01.parquet 1399 rows: identical
      binance/BTCUSDT/parquet/trades/2026-01-01.parquet 750 rows: identical
      binance/BTCUSDT/parquet/bbo/2026-01-01.parquet 750 rows: identical
      binance/BTCUSDT/parquet/l2/2026-01-01.parquet 3300 rows: identical
      binance/BTCUSDT/parquet/funding/2026-01-01.parquet 75 rows: identical
      binance/BTCUSDT/parquet/candles/2026-01-01.parquet 1399 rows: identical
      |}])
;;
