# test: market-data tests

- Expect tests for types, framing, merge order (a property test of `Merge`), candles against a
  DuckDB aggregation, the lead-lag query over planted lags, manifests and quality checks.
- `cram/` tests `day-close` end to end; promote its output with `dune promote` after reading it.
- `fixtures/event-log-v1` and `fixtures/event-log-pre-venues` are event logs written by earlier code.
  Tests read them with today's code and never regenerate them. A failure means the reader broke.
- Parquet is read back with DuckDB; tests need the DuckDB CLI on the path.
- Use a synthetic clock (`Time_source`) for rotation tests; do not sleep.
