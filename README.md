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
```

One file per instrument, stream and UTC day of the local receive time.
Every file is a sequence of frames:

```
+----------------------+---------------------------+----------------------+---
| size (8 bytes, LE)   | bin_io payload (size B)   | size (8 bytes, LE)   | ...
+----------------------+---------------------------+----------------------+---
```

the layout of `Bin_prot.Utils.bin_dump ~header:true`. Files are only appended
to, so a crash can at worst leave a partial last frame: readers stop there and
report it, and a writer reopening the file cuts it off before appending.

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

Writers buffer frames and flush every 100 ms, at 1 MiB, on `flush` and on
`close` (both configurable).

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

CI pins `fixed-decimal` and `exchange-core` from GitHub.

## TODO

- Parquet sink: convert `norm/` day files to Parquet for research tools,
  using the separate `parquet` library once it is published. Not a dependency
  yet.
- Venue normalizers from `raw/` to `norm/` live in the venue protocol
  libraries.
- Live `Feed.S` implementations on top of the venue clients.
