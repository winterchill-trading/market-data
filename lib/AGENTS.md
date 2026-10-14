# lib: market-data library

Library `market-data` (module `Market_data`). Groups:

- Types: `Venue`, `Stream`, `Instrument`, `Price`, `Size`, `Side`, `Symbol`, `Trade`, `Bbo`,
  `L2_update`, `Funding`, `Candle`, `Event`. Each record has a `Stable` module.
- Logs: `Framed` (length-prefixed frames, optional digest header, tail-tolerant reader), `Frame_log`
  (raw records), `Event_log` (normalized events per stream per day), `Snapshot_index`.
- Raw minutes: `Raw_minute`, `Raw_reader` (merged by `recv_ts`, empty lines become gaps), `Gap`,
  `Feed.With_gaps`.
- Feeds and rebuild: `Feed` (the `module type S` each client implements), `Normalizer`,
  `Rebuild_norm`, `Replay_feed`.
- Parquet and day close: `Parquet_*`, `Parquet_sink`, `Day_close`, `Instruments_table`,
  `Parquet_views`, `Quality_check`, `Catalog`.
- Analysis: `Candle_agg`, `Merge`, `L2_book`, `Event_dump`, `Funding`, `Contract_units`.

Rules:

- A `Feed.S` implementation never changes its signature to add fields; add a wrapper such as
  `Feed.With_gaps` instead.
- `Day_close` manifests skip a table only when its inputs and code version match; bump the code
  version when a table's content changes.
- The catalogue (`data/instruments.sexp`) carries the V2 facts (kind, size unit, funding interval);
  event records do not.
