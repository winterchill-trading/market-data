# market-data: agent guide

## Purpose

Normalized market data for the organization: the record types shared by every venue, append-only
raw and normalized logs, a live Parquet sink, the day-close batch that rebuilds Parquet from the
event log, DuckDB views, candles and replay. The event log is the system of record; Parquet is the
derived analytical layer.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `market-data` (module `Market_data`): venues, records, framing, event and raw logs, Parquet, day close, feeds, replay; features (`Bars`, `Directional_change`, `Cusum_filter`, `Labels`, `Toxicity`, `Toxicity_feed`, `Features`) |
| `bin/` | The `market-data` CLI: `day-close`, `views`, `query`, `dump`, `check`, `catalog`, `rebuild-norm`, `features` |
| `bench/` | Benchmarks for day close and the raw reader; `features_bench` (core_bench) for the per-trade feature folds |
| `test/` | Expect tests, cram test of `day-close`, pinned event-log fixtures |
| `scripts/` | `daycheck-diff.sh`, `pyarrow-check.sh` |
| `queries/` | `lead_lag.sql`, DuckDB queries kept as files |
| `examples/` | `query.py`, a Python reader of the Parquet tables |
| `data/` | `instruments.sexp`, the instrument catalogue |
| `.github/` | CI workflow |

## Build, test, docs

Run from this repository, inside the workspace:

    opam exec --switch 5.2.0+ox -- dune build --root .. @market-data/all
    opam exec --switch 5.2.0+ox -- dune build --root .. @market-data/runtest

The tests read Parquet back, so the DuckDB CLI (v1.5.6) must be on the path. Several agents building
at once need `DUNE_BUILD_DIR=_build-market-data`.

Standalone, outside the workspace: add the organization's opam repository
(`opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git`), install
the published dependencies, then run `dune build` here.

## Conventions

- Format this repository only: `dune build --root .. @market-data/fmt --auto-promote`. Never
  `dune fmt` at the workspace root.
- Every module has an `.mli`; every public value has an odoc comment.
- Every record type has a `Stable.V1` whose bin shape is pinned by a test. Event logs write the
  digest of `Event.Stable.V1` in each file header.
- Readers accept any digest in the append-only `compatible_digests` list (ADR 0006 in
  `../specs/adr/`). Adding a `Venue` constructor changes the digest: add the old digest to that list
  first, in the same commit.
- Manifests live under `_manifest/` (pyarrow skips `_`-prefixed names).
- The per-trade folds (`Bars`, `Directional_change`, `Cusum_filter`, `Toxicity`) keep their
  state in records with unboxed float fields written in place and return `or_null` or `[]`;
  expect tests pin 0 words for a trade that closes nothing. Keep it that way: no option,
  tuple or boxed float on that path.
- The `bars` and `toxicity` tables are not `Parquet_kind`s on purpose: adding a kind would
  make `day-close`, `views` and `catalog` expect them for every instrument.
- Comments for humans at pinned numbers and at workarounds, including DuckDB's decimal overflow.

## Dependencies

- Depends on sibling repositories `fixed-decimal`, `exchange-core` and `parquet`, and on bin_prot.
- Used by the venue clients, the read-only feeds, `market-recorder`, `market-replay`, and by
  `infra`, which runs the binary as the day-close CronJob.
- CI pin order: `fixed-decimal`, `exchange-core`, `parquet`, as in `.github/workflows/ci.yml`.

## CI

`.github/workflows/ci.yml` runs the `infra` ox-setup action with the pins above, then `dune build`
and `dune test`. It installs the DuckDB CLI and Python, then runs `scripts/pyarrow-check.sh` to type
check `examples/query.py` against pyarrow. The `obj-magic` job calls the reusable workflow in
`winterchill-trading/infra`. To check a run, use `gh run list --limit 1` and at most one
`gh run watch <id> --exit-status`. Never poll in a loop.

## Pitfalls

- Multiplying two `DECIMAL(18,8)` columns in DuckDB overflows; cast to DOUBLE or DECIMAL(38,16) first.
- DuckDB refuses `CREATE VIEW` over a `read_parquet` glob that matches no files; create views only
  for tables that have files.
- Write Parquet to `<path>.tmp` and rename on close, so globs never see a partial file.
- `TIMESTAMP(NANOS, isAdjustedToUTC=true)` makes DuckDB drop nanoseconds; use `isAdjustedToUTC=false`.
- A library module that opens Async cannot refer to its own `Stream` module; alias it before the open.
- Under `open! Async`, `Sys` is shadowed; use `Core.Sys.get_argv`.
- Core's `List.init` calls its function from the last index down; a test tape built with a
  stateful generator inside it comes out reversed. Use a loop.
- `xs @ f t` evaluates `f t` first; with a stateful `f` (`Toxicity.flush`) bind the left
  side first.
- A sibling dependency added here must be pinned in every consumer's CI, or each fails with
  "unknown package".

## Where to read more

- `README.md` (on-disk layout, Parquet tables, SQL quickstart, rebuilding norm, Python reader)
- `../specs/repos/market-data.md` (module map, known gaps)
- `../specs/design/data-platform.md`
- `../oxcaml-claude-skills/AGENTS.md` and `../oxcaml-claude-skills/GOTCHAS.md`
- Skills in `../oxcaml-claude-skills/skills/`: `oxcaml-performance`, `janestreet-ocaml-style`

## Never do

- Regenerate or edit a pinned fixture under `test/fixtures`. Tests read them with today's code.
- Remove a digest from `compatible_digests`.
- Run `opam install`, `upgrade` or `pin` that would change `ocaml-variants`, `core`, `base`,
  `async` or `ppx_jane` on the shared `5.2.0+ox` switch.
- Publish, tag or release.
- Poll CI in a loop.
