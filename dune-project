(lang dune 3.17)

(name market-data)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/market-data))

(package
 (name market-data)
 (synopsis
  "Normalized market data types, raw and normalized append-only logs, candles and replay")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  async
  core_unix
  bin_prot
  fixed-decimal
  exchange-core
  parquet
  zstd
  ppx_jane
  (core_bench :with-test)))
