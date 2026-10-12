#!/usr/bin/env python3
"""Read market-data Parquet tables from Python.

    pip install duckdb pyarrow pandas
    python3 examples/query.py /data/md

Timestamps are TIMESTAMP_NS without a time zone; the values are UTC. Prices and
sizes are DECIMAL(18,8): exact, but pandas turns them into Python Decimal
objects, so cast to DOUBLE for arithmetic.
"""

import sys

import duckdb
import pyarrow.dataset as ds


def trades_duckdb(root: str):
    """One minute VWAP per instrument, computed in DuckDB, returned as pandas."""
    con = duckdb.connect()
    glob = f"{root}/*/*/parquet/trades/*.parquet"
    df = con.execute(
        """
        SELECT venue, symbol,
               time_bucket(INTERVAL 1 MINUTE, recv_ts) AS minute,
               sum(price::DOUBLE * size::DOUBLE) / sum(size::DOUBLE) AS vwap,
               sum(size::DOUBLE) AS volume
        FROM read_parquet(?, hive_partitioning = false)
        GROUP BY ALL ORDER BY ALL
        """,
        [glob],
    ).df()
    # Naive datetime64[ns] holding UTC; make that explicit.
    df["minute"] = df["minute"].dt.tz_localize("UTC")
    return df


def bbo_pyarrow(root: str, venue: str, symbol: str):
    """Raw bbo rows of one instrument through pyarrow, without DuckDB."""
    symbol_dir = symbol.replace("/", "_")  # Kraken spot: BTC/USD -> BTC_USD
    table = ds.dataset(f"{root}/{venue}/{symbol_dir}/parquet/bbo", format="parquet").to_table()
    df = table.to_pandas()
    for col in ("exch_ts", "recv_ts"):
        df[col] = df[col].dt.tz_localize("UTC")
    for col in ("bid_price", "bid_size", "ask_price", "ask_size"):
        df[col] = df[col].astype("float64")
    df["mid"] = (df["bid_price"] + df["ask_price"]) / 2
    return df.sort_values("recv_ts")


def main() -> None:
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    print(trades_duckdb(root).head(20))
    if len(sys.argv) > 3:
        print(bbo_pyarrow(root, sys.argv[2], sys.argv[3]).head(20))


if __name__ == "__main__":
    main()
