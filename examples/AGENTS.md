# examples: market-data Python reader

`query.py` reads the Parquet tables with pyarrow and DuckDB. CI type-checks it through
`scripts/pyarrow-check.sh`.

Rules:

- Keep the script runnable against a local `parquet/` directory with no network access.
- Do not add a dependency that CI does not install; update the workflow in the same commit.
