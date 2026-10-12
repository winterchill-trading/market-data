# market-data

Normalized market data types, append-only raw and normalized logs, candle
aggregation and replay, for the trading stack in this organization. Written in
OxCaml with Core and Async.

Price, size, side and symbol types are the ones from
[exchange-core](https://github.com/winterchill-trading/exchange-core),
re-exported here with stable bin_io encodings.

## On-disk layout

```
<root>/
  <venue>/                      hyperliquid | binance | bybit | okx | ...
    <symbol>/                   venue's own name: ETH, BTCUSDT, ...
      raw/                      Frame_log: messages as received
        trades/2026-01-01.binlog
        bbo/2026-01-01.binlog
        l2/...
        funding/...
        private/...
      norm/                     Event_log: normalized events
        trades/2026-01-01.bin
        bbo/...
        l2/...
        l2/_snapshots/2026-01-01.bin   Snapshot_index: periodic full books (optional)
        funding/...
      parquet/                  Parquet tables for research (DuckDB, pandas, ...)
        trades/2026-01-01.parquet
        bbo/...
        l2/...                  one row per price level
        funding/...
        candles/...             1 minute candles from trades
  instruments/2026-01-01.parquet  the day's universe, written by day-close
```

`raw/` and `norm/` hold one file per instrument, stream and UTC day of the local
receive time. A `/` in a symbol (Kraken spot `BTC/USD`) becomes `_` in its
directory name (`kraken/BTC_USD/...`); listing maps Kraken spot names back
(names starting with the futures prefixes `PF_`, `PI_`, `FI_`, `FF_` stay as
they are). Other symbols are used unchanged.

The root may also hold `query-log.ndjson` (see `query`) and an optional
`units_per_contract.csv` (see the derived views).

Every file is a sequence of frames:

```
+----------------------+---------------------------+----------------------+---
| size (8 bytes, LE)   | bin_io payload (size B)   | size (8 bytes, LE)   | ...
+----------------------+---------------------------+----------------------+---
```

the layout of `Bin_prot.Utils.bin_dump ~header:true`. Files are only appended
to, so a crash can at worst leave a partial last frame: readers stop there and
report it, and a writer reopening the file cuts it off before appending.

`norm/` files written since headers were introduced start with a 40-byte
header: the magic `MDFRAME1` and the 32-character hex `bin_shape` digest of
`Event.Stable.V1.t` (`Event_log.digest`). Read as a frame size the magic is far
above the 256 MiB limit, so headerless files from before stay readable and are
read unchecked. Readers accept any digest in `Event_log.compatible_digests`
and raise, listing the accepted ones, on any other, rather than decoding
garbage; a writer refuses to append to such a file. Any change to the event
type's shape, including a new `Venue` constructor, changes the digest.

Adding a digest (Stable discipline):

1. Only make changes that keep old bytes decoding the same, such as appending
   a variant constructor at the end. Anything else needs a `Stable.V2` and a
   reader for the old files, not a list entry.
2. Put the new digest at the head of `compatible_digests` with a comment naming
   the change. The list is append-only: never remove or reorder entries.
3. Check in a fixture written by the previous code: `git worktree add` the
   commit before the change in a scratch directory, run `Event_log.Writer`
   there, and copy the files under `test/fixtures/`. Add a test that reads it.
4. Update the pinned digests in `test/test_event_log.ml` and
   `test/test_fixtures.ml`.

`test/fixtures/event-log-v1` holds files written by the code of that time,
`test/fixtures/event-log-pre-venues` files written before the venue list grew
from three to eleven entries (digest `4cf56dfb...`), and
`test/fixtures/event-log-pre-funding-v2` files written before `Funding_v2`
(digest `2f7f1bcb...`); tests check they still read, so never regenerate them.

### Funding without an exchange timestamp

Some venues (Hyperliquid) send funding with no exchange time, and their
normalizers copy `recv_ts` into `exch_ts`. `Funding.Stable.V2` makes that
explicit with `exch_ts : Time_ns.t option`; `Stable.V2.of_v1`/`to_v1` convert
(a missing `exch_ts` becomes `recv_ts`). The in-memory `Funding.t` and
`Event.t` are unchanged, so feeds keep building them as before.

On disk, `Event.Stable.V1` gained a fifth constructor, `Funding_v2`, appended
after the others (digest `cdf98830...`). The writer encodes a funding event
whose `exch_ts` equals its `recv_ts` (`Funding.exch_ts_opt` is `None`) as
`Funding_v2` with no `exch_ts`, and every other event as before, byte for byte
and without allocating. Readers turn `Funding_v2` back into `Funding` with
`exch_ts = recv_ts`, so `Event.t` round-trips exactly; `Event.to_stable` shows
which constructor a value is written as. The Parquet `funding` table still has
a required `exch_ts` column (the Parquet writer has no optional columns), so it
holds `recv_ts` for such rows.

## Modules

| Module | Purpose |
| --- | --- |
| `Venue` | `Hyperliquid \| Binance \| Bybit \| ...` (eleven venues), stable lowercase names |
| `Stream` | `Trades \| Bbo \| L2 \| Funding \| Private`, stable names |
| `Instrument` | venue plus symbol, `binance:BTCUSDT` |
| `Price`, `Size`, `Side`, `Symbol` | exchange-core types with bin_io added |
| `Trade`, `Bbo`, `L2_update`, `Funding`, `Candle` | normalized types, each with a `Stable.V1` whose bin shape is pinned by a test |
| `Event` | `Trade \| Bbo \| L2 \| Funding` |
| `Framed` | length-prefixed framing, tail-tolerant reader, buffered daily-rotating writer |
| `Merge` | deterministic k-way merge of sorted pipes |
| `Frame_log` | raw `{ recv_ts; stream_id; payload }` records, writer and readers |
| `Event_log` | normalized events routed to per-stream daily files |
| `Candle_agg` | trades to aligned candles (1s..1d), empty intervals carry the close |
| `Feed` | module type of a market data source: one pipe per stream plus `close`; `Feed.With_gaps` adds a `gaps` pipe |
| `Gap` | a break in a feed (disconnect, resync, damaged log) with its venue, instrument and stream |
| `Snapshot_index` | periodic full L2 books in `norm/l2/_snapshots/<date>.bin`, written by `Event_log.Writer ~snapshot_interval` |
| `Replay_feed` | a `Feed.t` replaying `Event_log` files, paced by `recv_ts` with a speed factor (0 = as fast as possible); `of_raw` replays raw minute files through a normalizer |
| `Store` | paths, day and instrument listing, file selection by date range |
| `Parquet_kind` | parquet tables (`trades`, `bbo`, `l2`, `funding`, `candles`) and their paths |
| `Parquet_schemas` | Parquet schemas of the normalized types; `L2_row` flattens book updates |
| `Parquet_file` | a Parquet file written through `In_thread`, renamed into place on close |
| `Parquet_sink` | live batching writer: row groups handed to a separate job chain, daily files |
| `Day_close` | rebuilds a day of `parquet/` from `norm/`, skipping tables that are up to date |
| `Instruments_table` | the point-in-time universe of a day: instruments with event logs that day and their catalogue facts, `<root>/instruments/<date>.parquet` |
| `Parquet_views` | DuckDB `CREATE VIEW`s over all instruments, derived views and a `duckdb` CLI runner |
| `Instrument_info` | catalogue per venue and symbol: kind (`Spot \| Perp \| Future \| Option`), base, quote, size unit (`Base \| Quote \| Contracts m`), funding interval, tick, lot; built from [`data/instruments.sexp`](data/instruments.sexp) |
| `Contract_units` | token units per price and per size unit, derived from the `Instrument_info` catalogue (quote-sized instruments have no row) |
| `Quality_check` | DuckDB data-quality assertions and the `gaps` view |
| `Catalog` | per table venues, symbols, first/last day, files and leftover parts |
| `L2_book` | an L2 book rebuilt from snapshots and deltas |
| `Event_dump` | one-line rendering of events and books as of a time |
| `Raw_minute` | market-recorder raw minute files: path parsing, zstd (multi-frame) decoding, `<recv_ts> <frame>` lines |
| `Raw_reader` | streams the raw minute files of one venue and symbol over a time range, all streams merged by `recv_ts`, empty lines as gaps |
| `Normalizer` | `Normalizer.S`, the raw-frame-to-events interface a feed library implements |
| `Rebuild_norm` | rebuilds a day of `norm/` from raw minute files with the given normalizers; `command` for binaries that link them |
| `Query_log` | ndjson audit log of SQL run through `query` |

Writers buffer frames and flush every 100 ms, at 1 MiB, on `flush` and on
`close` (both configurable).

## Parquet tables

Every table starts with `venue`, `symbol` (strings), `exch_ts` and `recv_ts`
(`TIMESTAMP_NS`). Prices and sizes are `DECIMAL(18,8)`, the exact fixed-decimal
units. Candles have `interval_ns` and `open_time` instead of the two
timestamps.

| Table | Columns after the common ones |
| --- | --- |
| `trades` | `price`, `size`, `side` (`buy`/`sell`, taker), `trade_id` |
| `bbo` | `bid_price`, `bid_size`, `ask_price`, `ask_size` |
| `l2` | `seq` (update number in the day), `is_snapshot`, `side` (`bid`/`ask`), `level`, `price`, `size` (0 removes the level in a delta) |
| `funding` | `rate` (double), `next_funding_time`, `mark_price`, `index_price` |
| `candles` | `interval_ns`, `open_time`, `open`, `high`, `low`, `close`, `volume`, `trade_count` |

`instruments` is not per instrument: day close writes
`<root>/instruments/<date>.parquet` with one row per instrument that has a
`norm/` file that day, so a backtest can select the universe of a past day
instead of today's catalogue. Columns: `date` (`YYYY-MM-DD`), `venue`,
`symbol`, `streams` (`trades,bbo,...`), `in_catalogue`, then the
`Instrument_info` facts at the time of the run (empty, zero or NaN when not in
the catalogue): `kind`, `base`, `quote`, `size_unit`, `units_per_contract`,
`units_per_price`, `funding_interval_s`, `tick`, `lot`. Runs limited by
`-venue` or `-symbol` leave it alone; full runs rewrite it. `query` defines an
`instruments` view over these files.

There are two ways to fill `parquet/`:

- `Parquet_sink` next to a live feed. `add` only buffers; full row groups go
  over a pipe to a writer job that encodes and writes through `In_thread`, so
  a slow disk never stalls the feed (past `max_pending_rows` batches are
  dropped and counted). The first row of a new UTC day on the sink clock closes the previous
  file. A restart on the same day writes `<date>.1.parquet`, `.2`, ...
- `market-data day-close` (or `Day_close.run`) from the event log after the day
  is over. Every table it writes gets a manifest,
  `parquet/<kind>/_manifest/<date>.sexp`, with its input files (size, mtime),
  output bytes, rows and a code version that includes the event digest. A
  table whose manifest matches the current inputs and code version is skipped
  (`-force` rewrites it); one without a manifest is rebuilt. A rewrite removes
  the numbered parts of a restarted sink. Per table it prints input frames and
  bytes, output bytes, elapsed time and the parts it replaced. The `_manifest`
  directory is skipped by pyarrow and Spark dataset readers.

  `-jobs N` converts up to N tables of the process at once. Parquet encoding
  runs in `In_thread`, but OCaml threads share one domain, so this mostly
  overlaps I/O. `-processes N` converts up to N instruments at once, each in a
  child `day-close` process, and prints their output in instrument order; this
  is the flag that uses several cores. On a synthetic day of four instruments
  (3M events, 290 MB of `norm/`, M-series Mac): 6.0 s sequential, 5.4 s with
  `-jobs 2`, 2.9 s with `-processes 2`, 1.5 s with `-processes 4`. Handing rows
  to the Parquet thread in 64k-row batches instead of one call per pipe chunk
  took the sequential run from 23.6 s to 6.0 s.

  Day close writes row groups of 65,536 rows (`-row-group N`,
  `Day_close.default_row_group_rows`); it used to write 1,048,576. Each row
  group carries min and max statistics per column, so DuckDB skips the groups
  a time filter rules out, and it scans row groups in parallel. On a synthetic
  day of 2M Binance trades (one file, 12.8 MB at 1M rows per group, 13.1 MB at
  64k), DuckDB 1.5.6 on an M-series Mac, `PRAGMA threads=1`:

  ```sql
  EXPLAIN ANALYZE SELECT count(*) AS n, avg(price::DOUBLE) AS avg_price FROM trades
  WHERE recv_ts >= TIMESTAMP_NS '2026-01-01 12:00:00'
    AND recv_ts <  TIMESTAMP_NS '2026-01-01 12:05:00';
  ```

  | Row group | Total Time (5 runs) | Rows out of TABLE_SCAN |
  | --- | --- | --- |
  | 1,048,576 (before) | 11.6 to 12.6 ms | 6,945 |
  | 65,536 (now) | 1.8 to 2.3 ms | 6,945 |

  A full-day `count(*), avg(price)` with default threads went from 6.7 ms to
  2.8 ms; writing the table took about the same time (2.0 s against 2.1 s).
  The manifest code version changed with the default (`day-close-2`), so the
  next run rewrites every table once; another `-row-group` needs `-force`.

Files are written as `<name>.tmp` and renamed when complete, so readers
globbing `*.parquet` never see a partial file.

## SQL quickstart

```
$ market-data day-close -dir /data/md -date 2026-01-01
wrote /data/md/binance/BTCUSDT/parquet/trades/2026-01-01.parquet (3 rows)
...
$ market-data query -dir /data/md \
    "SELECT venue, symbol, count(*) AS n, sum(size) AS volume, max(price) AS high
     FROM trades GROUP BY ALL ORDER BY ALL"
```

`query` runs the `duckdb` CLI (`-duckdb PATH`, default
`/opt/homebrew/bin/duckdb` when present, else `duckdb` on `PATH`;
`-format box|csv|json|markdown`) with a view per table that has files.
DuckDB multiplies two `DECIMAL(18,8)` values without widening and raises
an overflow error past 18 digits; cast to `DOUBLE` or `DECIMAL(38,16)` first.
`market-data views -dir /data/md` prints the same statements to paste into a
DuckDB shell or notebook:

```sql
CREATE VIEW trades AS SELECT * FROM read_parquet('/data/md/*/*/parquet/trades/*.parquet', hive_partitioning=false);
CREATE VIEW bbo AS SELECT * FROM read_parquet('/data/md/*/*/parquet/bbo/*.parquet', hive_partitioning=false);
-- l2, funding, candles likewise

-- 1 minute VWAP per instrument
SELECT venue, symbol, time_bucket(INTERVAL 1 MINUTE, exch_ts) AS minute,
       sum(price::DOUBLE * size::DOUBLE) / sum(size::DOUBLE) AS vwap
FROM trades GROUP BY ALL ORDER BY ALL;

-- exact notional: widen before multiplying
SELECT sum(price::DECIMAL(38,16) * size) AS notional FROM trades;

-- book at the last snapshot
SELECT side, level, price, size FROM l2
WHERE seq = (SELECT max(seq) FROM l2 WHERE is_snapshot) ORDER BY side, level;
```

### Derived views

`query` and `views` also define, when their tables exist:

| View | Contents |
| --- | --- |
| `trades_with_bbo` | each trade with the bbo prevailing at its `recv_ts` (`ASOF LEFT JOIN` on venue and symbol): `bbo_recv_ts`, `bid_price`, `bid_size`, `ask_price`, `ask_size` |
| `lag` | per table, venue and symbol: `n`, `p50_ms`, `p99_ms` of `recv_ts - exch_ts` |
| `units_per_contract` | table: `venue`, `symbol`, `token`, `units_per_contract` (tokens per size unit), `units_per_price` (tokens a price is for); built-in rows, replaced per venue and symbol by `<root>/units_per_contract.csv` (same columns, with a header) |
| `token_bbo` | bbo of instruments in `units_per_contract` in token terms: `token`, `bid`, `ask`, `mid`, `bid_qty`, `ask_qty` |

```sql
-- the same token across venues
SELECT token, venue, symbol, avg(mid) FROM token_bbo GROUP BY ALL ORDER BY ALL;
```

### Other commands

```
market-data dump FILE...                     # events of norm/ files, merged by recv_ts
market-data dump -book-at 2026-01-01T12:00:00Z -depth 10 .../norm/l2/2026-01-01.bin
market-data check -dir /data/md -max-gap 30s # exits 1 when any check fails
market-data catalog -dir /data/md
```

`dump` prints one line per event (`<recv_ts> <venue>:<symbol> <stream> ...`);
with `-book-at` it instead prints the L2 book of each instrument after every
update received at or before that time. `check` counts, per table, `recv_ts`
gaps longer than `-max-gap` within an instrument (trades, bbo, l2),
non-positive sizes (zero l2 sizes only in snapshots) and crossed bbo
(`bid > ask`), then prints the largest gaps from its `gaps` view. `catalog`
lists per table the venues, number of symbols, first and last day, file count
and leftover numbered sink parts. `query` appends `{"time", "user", "sql"}`
to `<root>/query-log.ndjson` before running (`-no-log` to skip).

`Funding.normalized_8h` scales a rate to an 8 hour interval using the
instrument's catalogued `funding_interval` (Hyperliquid and Kraken Futures fund
hourly, the others every 8 hours), so venues compare directly.

`Replay_feed.of_range` replays the files of instruments and a date range and
fails, naming the range, when there are none. With `~start_at` it starts each
instrument at its last `Snapshot_index` entry at or before that time: the book
arrives first as an L2 snapshot, then the events from the entry's minute on,
so a replay can begin mid-day without reading from midnight. Snapshots are
written only by an `Event_log.Writer` created with `~snapshot_interval`
(e.g. one minute); the entry at `at` holds every L2 update received before
`at`.

### Reading raw files

`Raw_reader.read ~data_dir ~venue ~symbol ~start ~stop ()` is the one reader of
the recorder's raw minute files: it yields `Frame { recv_ts; stream; frame }`
and `Gap { recv_ts; stream }` (an empty line) for every stream of the symbol,
merged by `recv_ts`, with frames outside `[start, stop)` dropped. Each stream
holds at most one decompressed minute in memory. `Rebuild_norm` and
`Replay_feed.of_raw` both read through it. `dune exec bench/raw_reader_bench.exe`
measures it: 600k lines of 140-byte frames over three streams take 0.9 to 1.2 s
(0.5 to 0.7 M lines/s) on an M-series laptop; the per-line pipe merge, not
timestamp parsing, is the bulk of it.

`Replay_feed.of_raw ~normalizer ~data_dir ~symbol ~start ~stop ()` turns those
frames into a `Feed.With_gaps.t`: each empty line resets the stream's normalizer
and arrives on `gaps` as a `Disconnect`. `Replay_feed.of_files_with_gaps` does
the same for event logs, reporting a file that ends in a damaged frame as a
`Damaged_log` gap. `Feed.With_gaps.of_feed` lifts a plain feed (no gaps).

### Rebuilding norm/ from raw files

`market-data rebuild-norm -data-dir DIR -out NEW_DIR -date YYYY-MM-DD` reads
the recorder's `raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/*.ndjson[.zst]`
files of the day and writes event logs under `NEW_DIR` (which must be new or
empty, since event logs are appended to). Each `(venue, stream, symbol)` series
gets a fresh normalizer fed its minutes in order through `Raw_reader`; an empty
line calls `disconnect`. It prints counts of files, frames, disconnects, events,
errors (frames the normalizer rejected and raw lines that do not parse, with the
first ten) and skipped files.

L2 events also feed the snapshot index `norm/l2/_snapshots/<date>.bin` through
the same `Event_log.Writer` the recorder uses, so a rebuilt day has the same
index byte for byte; `-snapshot-interval SPAN` (`?snapshot_interval`) changes
the one-minute default and `0s` writes none.

Market-data has no venue code, so this binary has no normalizers and only
counts files as skipped. A feed library plugs in by implementing
`Market_data.Normalizer.S` over its own normalizer:

```ocaml
module Okx_normalizer : Market_data.Normalizer.S = struct
  type t = Okx_feed.Normalizer.t

  let venue = Market_data.Venue.Okx
  let create () = Okx_feed.Normalizer.create ()

  let frame t ~recv_ts payload =
    Or_error.map (Okx_feed.Normalizer.frame t ~recv_ts payload) ~f:(fun o -> o.events)
  ;;

  let disconnect t = Okx_feed.Normalizer.reset t
end
```

and a binary that links the feed libraries mounts
`Market_data.Rebuild_norm.command [ (module Okx_normalizer); ... ]` (or calls
`Rebuild_norm.run`). Normalizers that return several outputs (Deribit) or no
`reset` (Coinbase, Bitget) adapt the same way: concatenate the events, and
recreate the state on `disconnect` by keeping it in a `ref`.

### From Python

[`examples/query.py`](examples/query.py) reads the tables with DuckDB and with
pyarrow (`pip install duckdb pyarrow pandas`; not run in CI). Notes for pandas:

- `exch_ts`, `recv_ts`, `open_time` are `TIMESTAMP_NS` without a time zone
  (`isAdjustedToUTC=false`), so they arrive as naive `datetime64[ns]` holding
  UTC. Call `.dt.tz_localize("UTC")`, not `tz_convert`, to label them.
- Nanoseconds survive into pandas; going through Python `datetime` objects
  (e.g. `.to_pydatetime()`) truncates to microseconds.
- Prices and sizes are `DECIMAL(18,8)`: pandas gets `decimal.Decimal` objects
  (slow, object dtype). Cast to `DOUBLE` in SQL or `.astype("float64")` for
  numeric work; keep the decimals when exact sums matter.
- `candles.interval_ns` is an integer number of nanoseconds:
  `pd.to_timedelta(df.interval_ns, unit="ns")`.

## Usage

```ocaml
open! Core
open! Async
open Market_data

let record ~dir instrument msgs =
  let w = Frame_log.Writer.create ~dir instrument Trades in
  Pipe.iter_without_pushback msgs ~f:(fun payload ->
    Frame_log.Writer.write w ~recv_ts:(Time_ns.now ()) ~stream_id:0 payload)
  >>= fun () -> Frame_log.Writer.close w

let replay ~dir instrument ~from ~to_ =
  let store = Store.create dir in
  let%bind files = Store.files store Norm instrument [ Trades; Bbo ] ~from ~to_ in
  let (module F : Feed.S) = Replay_feed.of_files ~speed:0. files in
  Pipe.close_read F.l2;
  Pipe.close_read F.funding;
  Deferred.both
    (Pipe.iter_without_pushback F.trades ~f:(fun t -> print_s [%sexp (t : Trade.t)]))
    (Pipe.iter_without_pushback F.bbo ~f:ignore)
  >>| fun ((), ()) -> ()
```

Open `Market_data` after `Async`: both define a `Stream` module.

## Building

```
opam install . --deps-only --with-test
dune build && dune test
```

The tests read the Parquet files back with the `duckdb` CLI, which must be on
`PATH`.

CI pins `fixed-decimal`, `exchange-core` and `parquet` from GitHub.

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## Live feeds

`Feed.S` is implemented as `Live_feed` in `hl-client`, `binance-client` and
`bybit-client`; `market-recorder` runs them and writes raw and normalized
files. `Feed.S` has no `gaps` pipe so these keep compiling; a live feed that
reports resyncs implements `Feed.With_gaps.S` instead.
