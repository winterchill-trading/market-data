open! Core
open! Async
open Market_data

let fixture = "fixtures/event-log-research"
let day = Date.of_string "2026-01-01"

let with_fixture_copy f =
  Sample.with_temp_dir (fun dir ->
    let%bind () =
      Process.run_expect_no_stdout_exn ~prog:"cp" ~args:[ "-RL"; fixture ^ "/."; dir ] ()
    in
    f dir)
;;

let query ~dir sql =
  match%map Parquet_views.query ~format:Csv ~dir sql with
  | Ok out -> print_string out
  | Error e -> print_s [%sexp (e : Error.t)]
;;

(* The reference: what [Candle_agg] does, in SQL. Trades are bucketed by [exch_ts]; a
   trade older than the candle in progress counts in it (the running maximum of buckets in
   file order); empty minutes between the first and last carry the previous close. *)
let reference =
  {|
WITH t AS (
  SELECT venue, symbol, file_row_number AS rn, price, size,
         max(epoch_ns(exch_ts) // 60000000000)
           OVER (PARTITION BY venue, symbol ORDER BY file_row_number
                 ROWS UNBOUNDED PRECEDING) AS bucket
  FROM read_parquet('DIR/*/*/parquet/trades/*.parquet', file_row_number = true)
),
full_ AS (
  SELECT venue, symbol, bucket,
         arg_min(price, rn) AS open, max(price) AS high, min(price) AS low,
         arg_max(price, rn) AS close, sum(size) AS volume, count(*) AS trade_count
  FROM t GROUP BY ALL
),
grid AS (
  SELECT venue, symbol, unnest(range(min(bucket), max(bucket) + 1)) AS bucket
  FROM full_ GROUP BY ALL
),
filled AS (
  SELECT g.venue, g.symbol, g.bucket, f.open, f.high, f.low, f.close, f.volume,
         f.trade_count,
         last_value(f.close IGNORE NULLS)
           OVER (PARTITION BY g.venue, g.symbol ORDER BY g.bucket
                 ROWS UNBOUNDED PRECEDING) AS carried
  FROM grid g LEFT JOIN full_ f USING (venue, symbol, bucket)
)
SELECT venue, symbol, 60000000000::BIGINT AS interval_ns,
       make_timestamp_ns(bucket * 60000000000) AS open_time,
       coalesce(open, carried) AS open, coalesce(high, carried) AS high,
       coalesce(low, carried) AS low, coalesce(close, carried) AS close,
       coalesce(volume, 0)::DECIMAL(18, 8) AS volume,
       coalesce(trade_count, 0) AS trade_count
FROM filled
|}
;;

let%expect_test "candles equal a DuckDB aggregation of the trades, row for row" =
  with_fixture_copy (fun dir ->
    let%bind (_ : Day_close.Result.t list) = Day_close.run ~dir day in
    let reference = String.substr_replace_all reference ~pattern:"DIR" ~with_:dir in
    let%bind () =
      query
        ~dir
        (sprintf
           {|
CREATE TEMP TABLE ref AS %s;
CREATE TEMP TABLE got AS
  SELECT venue, symbol, interval_ns::BIGINT AS interval_ns, open_time, open, high, low,
         close, volume, trade_count::BIGINT AS trade_count
  FROM candles;
SELECT (SELECT count(*) FROM got) AS candles,
       (SELECT count(*) FROM (SELECT * FROM ref EXCEPT ALL SELECT * FROM got)) AS only_ref,
       (SELECT count(*) FROM (SELECT * FROM got EXCEPT ALL SELECT * FROM ref)) AS only_got,
       (SELECT count(*) FROM got WHERE trade_count = 0) AS empty;
SELECT * FROM got WHERE venue = 'binance' AND minute(open_time) BETWEEN 3 AND 6
ORDER BY open_time;
|}
           reference)
    in
    [%expect
      {|
      candles,only_ref,only_got,empty
      22,0,0,4
      venue,symbol,interval_ns,open_time,open,high,low,close,volume,trade_count
      binance,BTCUSDT,60000000000,2026-01-01 00:03:00,65003.40000000,65006.40000000,65003.40000000,65004.40000000,10.30100000,20
      binance,BTCUSDT,60000000000,2026-01-01 00:04:00,65004.40000000,65004.40000000,65004.40000000,65004.40000000,0.00000000,0
      binance,BTCUSDT,60000000000,2026-01-01 00:05:00,65004.40000000,65004.40000000,65004.40000000,65004.40000000,0.00000000,0
      binance,BTCUSDT,60000000000,2026-01-01 00:06:00,64999.40000000,65000.60000000,64996.40000000,64998.40000000,8.61700000,20
      |}];
    return ())
;;
