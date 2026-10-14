# bin: market-data CLI

`market_data_cli.ml` is the `market-data` executable. Subcommands:

- `day-close`: rebuilds one day of `parquet/` from `norm/`; `-row-group`, `-jobs`, `-processes`.
- `views`, `query`: DuckDB views and SQL. `query` appends each run to `query-log.ndjson`.
- `dump`, `dump -book-at`: renders events, or the book at a time.
- `check`: DuckDB assertions (gaps, non-positive sizes, crossed BBO).
- `catalog`: venues, symbols, first and last day, leftover parts.
- `rebuild-norm`: rebuilds `norm/` from raw minutes. It links no venue code; it needs a binary that
  links the feed libraries' normalizers, so run it through the recorder or a feed binary.

Rules:

- Keep the flag names stable; the day-close CronJob in `infra` calls them.
