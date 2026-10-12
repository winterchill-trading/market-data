Day close of the research fixture (three venues of bbo, trades with a gap). Elapsed
times are cut from the output.

  $ cp -RL ../fixtures/event-log-research data && chmod -R u+w data
  $ market-data day-close -dir data -date 2026-01-01 | sed -E 's/, [0-9.]+(ms|s|us)$//'
  wrote data/hyperliquid/BTC/parquet/trades/2026-01-01.parquet (54 rows)
    trades: 54 frames (2775 bytes) in, 2417 bytes out
  wrote data/hyperliquid/BTC/parquet/bbo/2026-01-01.parquet (400 rows)
    bbo: 400 frames (24040 bytes) in, 6647 bytes out
  wrote data/hyperliquid/BTC/parquet/candles/2026-01-01.parquet (11 rows)
    candles: 54 frames (2775 bytes) in, 1846 bytes out
  wrote data/binance/BTCUSDT/parquet/trades/2026-01-01.parquet (160 rows)
    trades: 160 frames (8785 bytes) in, 3980 bytes out
  wrote data/binance/BTCUSDT/parquet/bbo/2026-01-01.parquet (400 rows)
    bbo: 400 frames (25640 bytes) in, 6647 bytes out
  wrote data/binance/BTCUSDT/parquet/candles/2026-01-01.parquet (11 rows)
    candles: 160 frames (8785 bytes) in, 1843 bytes out
  wrote data/bybit/BTCUSDT/parquet/bbo/2026-01-01.parquet (400 rows)
    bbo: 400 frames (25640 bytes) in, 6631 bytes out
  wrote data/instruments/2026-01-01.parquet (3 rows)

A second run finds every table up to date; the instruments table is always rewritten.

  $ market-data day-close -dir data -date 2026-01-01
  up to date data/hyperliquid/BTC/parquet/trades/2026-01-01.parquet
  up to date data/hyperliquid/BTC/parquet/bbo/2026-01-01.parquet
  up to date data/hyperliquid/BTC/parquet/candles/2026-01-01.parquet
  up to date data/binance/BTCUSDT/parquet/trades/2026-01-01.parquet
  up to date data/binance/BTCUSDT/parquet/bbo/2026-01-01.parquet
  up to date data/binance/BTCUSDT/parquet/candles/2026-01-01.parquet
  up to date data/bybit/BTCUSDT/parquet/bbo/2026-01-01.parquet
  wrote data/instruments/2026-01-01.parquet (3 rows)

The same binary on both sides gives identical tables.

  $ ../../scripts/daycheck-diff.sh -data ../fixtures/event-log-research market-data market-data
  trades: identical (214 rows)
  bbo: identical (1200 rows)
  l2: no files
  funding: no files
  candles: identical (22 rows)
  instruments: identical (3 rows)

A difference is reported per table, with exit code 1.

  $ cp -R data other && rm other/hyperliquid/BTC/parquet/trades/2026-01-01.parquet
  $ ../../scripts/daycheck-diff.sh -compare data other
  trades: DIFFERENT (A 214 rows, B 160 rows, 54 only in A, 0 only in B)
  bbo: identical (1200 rows)
  l2: no files
  funding: no files
  candles: identical (22 rows)
  instruments: identical (3 rows)
  [1]
