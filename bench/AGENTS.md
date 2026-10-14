# bench: market-data benchmarks

`day_close_bench.ml` and `raw_reader_bench.ml` measure day close and the raw minute reader. The
reader figure in the README (about 2.7 M lines/s at 39 words per line) is from one core on an
arm64 Mac.

Rules:

- Quote the machine with every new figure; allocation counts differ between arm64 and amd64.
- A change that moves a figure updates the README in the same commit.
- Benchmarks do not run in CI.
