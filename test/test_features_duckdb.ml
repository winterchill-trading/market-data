open! Core
open! Async
open Market_data

let fixture = "fixtures/event-log-research"
let day = Date.of_string "2026-01-01"

let query ~dir sql =
  match%map Parquet_views.query ~format:Csv ~dir sql with
  | Ok out -> print_string out
  | Error e -> print_s [%sexp (e : Error.t)]
;;

(* The references, in SQL over the day-close trades table: tick bars are runs of 7 trades
   in file order (bars take the first and last trade's time, which is not the minimum and
   maximum when trades arrive out of order, as some here do); volume bars close on the
   trade where the running volume since the last close reaches 2, which a recursive query
   follows trade by trade. *)
let reference =
  {|
CREATE TEMP TABLE t AS
  SELECT venue, symbol, file_row_number AS rn, exch_ts, price, size, side
  FROM read_parquet('DIR/*/*/parquet/trades/*.parquet', file_row_number = true);
CREATE TEMP TABLE ref_tick AS
  SELECT venue, symbol, rn // 7 AS bar, arg_min(exch_ts, rn) AS first_ts,
         arg_max(exch_ts, rn) AS last_ts,
         arg_min(price, rn) AS open, max(price) AS high, min(price) AS low,
         arg_max(price, rn) AS close, sum(size) AS volume,
         sum(CASE WHEN side = 'buy' THEN size ELSE 0 END) AS buy_volume,
         count(*) AS trade_count, count(*) = 7 AS complete
  FROM t GROUP BY ALL;
CREATE TEMP TABLE ref_volume AS
  WITH RECURSIVE walk(venue, symbol, rn, acc, bar) AS (
    SELECT venue, symbol, rn, size::DECIMAL(38, 8), 0 FROM t WHERE rn = 0
    UNION ALL
    SELECT t.venue, t.symbol, t.rn,
           CASE WHEN w.acc >= 2 THEN t.size ELSE w.acc + t.size END,
           CASE WHEN w.acc >= 2 THEN w.bar + 1 ELSE w.bar END
    FROM walk w JOIN t ON t.venue = w.venue AND t.symbol = w.symbol AND t.rn = w.rn + 1
  )
  SELECT venue, symbol, bar, count(*) AS trade_count, sum(t.size) AS volume
  FROM walk JOIN t USING (venue, symbol, rn) GROUP BY ALL;
CREATE TEMP TABLE bars AS
  SELECT *, row_number() OVER (PARTITION BY venue, symbol, bar_type
                               ORDER BY file_row_number) - 1 AS bar
  FROM read_parquet('DIR/*/*/parquet/bars/*.parquet', file_row_number = true);
CREATE TEMP TABLE tox AS SELECT * FROM read_parquet('DIR/*/*/parquet/toxicity/*.parquet');
|}
;;

let%expect_test "bars and VPIN agree with SQL recomputations from the trades table" =
  Sample.with_temp_dir (fun dir ->
    let%bind () =
      Process.run_expect_no_stdout_exn ~prog:"cp" ~args:[ "-RL"; fixture ^ "/."; dir ] ()
    in
    let%bind () =
      Process.run_expect_no_stdout_exn ~prog:"chmod" ~args:[ "-R"; "u+w"; dir ] ()
    in
    let%bind (_ : Day_close.Result.t list) = Day_close.run ~dir day in
    let%bind results =
      Features.run
        ~dir
        ~bars:[ Tick 7; Volume (Size.of_string "2") ]
        ~toxicity:
          { bucket = Fixed (Size.of_string "5")
          ; window = 3
          ; zscore_window = 10
          ; classification = Aggressor
          }
        day
    in
    List.iter results ~f:(fun r ->
      printf
        "%s: %d trades, %d bars, %d buckets\n"
        (Instrument.to_string r.instrument)
        r.trades
        (Option.value_map r.bars ~default:0 ~f:snd)
        (Option.value_map r.toxicity ~default:0 ~f:(fun (_, n, _) -> n)));
    let reference = String.substr_replace_all reference ~pattern:"DIR" ~with_:dir in
    let%bind () =
      query
        ~dir
        (reference
         ^ {|
SELECT 'tick' AS check, count(*) AS rows,
  (SELECT count(*) FROM (
     SELECT venue, symbol, bar, first_ts, last_ts, open, high, low, close, volume,
            buy_volume, trade_count, complete FROM ref_tick
     EXCEPT ALL
     SELECT venue, symbol, bar, first_ts, last_ts, open, high, low, close, volume,
            buy_volume, trade_count, complete FROM bars WHERE bar_type = 'tick-7')) AS mismatches
FROM ref_tick
UNION ALL
SELECT 'volume', count(*),
  (SELECT count(*) FROM (
     SELECT venue, symbol, bar, trade_count, volume FROM ref_volume
     EXCEPT ALL
     SELECT venue, symbol, bar, trade_count, volume FROM bars WHERE bar_type = 'volume-2'))
FROM ref_volume
UNION ALL
SELECT 'bucket size', count(*), count(*) FILTER (WHERE abs(buy_volume + sell_volume - 5) > 1e-9)
FROM tox
UNION ALL
SELECT 'vpin', count(*), count(*) FILTER (WHERE abs(vpin - ref) > 1e-12)
FROM (SELECT vpin, avg(abs(imbalance)) OVER (PARTITION BY venue, symbol ORDER BY bucket
                                             ROWS 2 PRECEDING) AS ref FROM tox)
UNION ALL
SELECT 'volume conserved', count(*),
  count(*) FILTER (WHERE bucketed > traded + 1e-9 OR bucketed < traded - 5)
FROM (SELECT venue, symbol, sum(size)::DOUBLE AS traded FROM t GROUP BY ALL)
JOIN (SELECT venue, symbol, sum(buy_volume + sell_volume) AS bucketed FROM tox GROUP BY ALL)
USING (venue, symbol);
|}
        )
    in
    [%expect
      {|
      hyperliquid:BTC: 54 trades, 20 bars, 5 buckets
      binance:BTCUSDT: 160 trades, 59 bars, 15 buckets
      check,rows,mismatches
      tick,31,0
      volume,48,0
      bucket size,20,0
      vpin,20,0
      volume conserved,2,0
      |}];
    return ())
;;
