# Changes

## Unreleased (next patch: 0.1.1)

Additive: no existing module, type or table changed shape.

- `Bars`: information-driven bars from trades (tick, volume, dollar; tick, volume and
  dollar imbalance and run bars with adaptive thresholds). `Bars.Bar.Stable.V1` has its
  bin shape pinned by a test.
- `Directional_change` and `Cusum_filter`: event clocks over a price series.
- `Labels`: triple-barrier labels, meta-labels, EWMA volatility widths.
- `Toxicity`: VPIN over equal-volume buckets with aggressor, tick-rule and bulk volume
  classification, signed imbalance, dominant side, rolling z-score and percentile.
- `Toxicity_feed`: toxicity events from a `Feed.t`.
- `Feature_schemas`, `Features` and the `features` subcommand: `parquet/bars/` and
  `parquet/toxicity/` tables from a day of `norm/` trades, checked against DuckDB
  recomputations.
- `bench/features_bench.exe` (core_bench); `core_bench` is now a test dependency.
- The library depends on `stdlib_upstream_compatible` (shipped with the compiler) for
  unboxed float state.

## 0.1.0

First entry in the organization's opam repository, at `c821ba8`.
