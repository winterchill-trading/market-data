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
  <venue>/                      hyperliquid | binance | bybit
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
        funding/...
      parquet/                  Parquet tables for research (DuckDB, pandas, ...)
        trades/2026-01-01.parquet
        bbo/...
        l2/...                  one row per price level
        funding/...
        candles/...             1 minute candles from trades
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
read unchecked. Readers raise on a file whose digest differs, rather than
decoding garbage, and a writer refuses to append to one. Any change to the
event type's shape, including a new `Venue` constructor, changes the digest;
such a change needs a `Stable.V2` and a reader for the old files.
`test/fixtures/event-log-v1` holds files written by the code of that time; a
test checks they still read, so never regenerate them.

## Modules

| Module | Purpose |
| --- | --- |
| `Venue` | `Hyperliquid \| Binance \| Bybit`, stable lowercase names |
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
| `Feed` | module type of a market data source: one pipe per stream plus `close` |
| `Replay_feed` | a `Feed.t` replaying `Event_log` files, paced by `recv_ts` with a speed factor (0 = as fast as possible) |
| `Store` | paths, day and instrument listing, file selection by date range |
| `Parquet_kind` | parquet tables (`trades`, `bbo`, `l2`, `funding`, `candles`) and their paths |
| `Parquet_schemas` | Parquet schemas of the normalized types; `L2_row` flattens book updates |
| `Parquet_file` | a Parquet file written through `In_thread`, renamed into place on close |
| `Parquet_sink` | live batching writer: row groups handed to a separate job chain, daily files |
| `Day_close` | rebuilds a day of `parquet/` from `norm/`, skipping tables that are up to date |
| `Parquet_views` | DuckDB `CREATE VIEW`s over all instruments, derived views and a `duckdb` CLI runner |
| `Contract_units` | token units per price and per size unit of known listings (`1000PEPEUSDT`, `kPEPE`, OKX swaps) |
| `Quality_check` | DuckDB data-quality assertions and the `gaps` view |
| `Catalog` | per table venues, symbols, first/last day, files and leftover parts |
| `L2_book` | an L2 book rebuilt from snapshots and deltas |
| `Event_dump` | one-line rendering of events and books as of a time |
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

`Replay_feed.of_range` replays the files of instruments and a date range and
fails, naming the range, when there are none.

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

## Live feeds

`Feed.S` is implemented as `Live_feed` in `hl-client`, `binance-client` and
`bybit-client`; `market-recorder` runs them and writes raw and normalized
files. Rebuilding `norm/` from stored raw frames is not wired up yet.
