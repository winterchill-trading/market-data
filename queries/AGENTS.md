# queries: DuckDB SQL files

`lead_lag.sql` computes the lead-lag between venues over the Parquet tables. Queries live here so
the README, tests and scripts read one copy.

Rules:

- Cast `DECIMAL(18,8)` products to a wider type before multiplying.
- A query that reads a glob must tolerate an empty glob; test it on a day with no files.
