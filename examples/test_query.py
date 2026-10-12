#!/usr/bin/env python3
"""Type test of the Parquet tables and of examples/query.py, through pyarrow.

    python3 examples/test_query.py ROOT...

Each ROOT is a market-data root after `market-data day-close`. Fails when a column
has another Arrow type than the one below, or when query.py returns other dtypes.
scripts/pyarrow-check.sh builds the roots from the checked-in fixtures.
"""

import glob
import os
import sys

import pyarrow as pa
import pyarrow.dataset as ds

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import query  # noqa: E402

TS = pa.timestamp("ns")
DEC = pa.decimal128(18, 8)
STR = pa.string()
HEADER = [("venue", STR), ("symbol", STR), ("exch_ts", TS), ("recv_ts", TS)]

EXPECTED = {
    "trades": HEADER
    + [("price", DEC), ("size", DEC), ("side", STR), ("trade_id", STR)],
    "bbo": HEADER
    + [("bid_price", DEC), ("bid_size", DEC), ("ask_price", DEC), ("ask_size", DEC)],
    "l2": HEADER
    + [
        ("seq", pa.int64()),
        ("is_snapshot", pa.bool_()),
        ("side", STR),
        ("level", pa.int32()),
        ("price", DEC),
        ("size", DEC),
    ],
    "funding": HEADER
    + [
        ("rate", pa.float64()),
        ("next_funding_time", TS),
        ("mark_price", DEC),
        ("index_price", DEC),
    ],
    "candles": [
        ("venue", STR),
        ("symbol", STR),
        ("interval_ns", pa.int64()),
        ("open_time", TS),
        ("open", DEC),
        ("high", DEC),
        ("low", DEC),
        ("close", DEC),
        ("volume", DEC),
        ("trade_count", pa.int64()),
    ],
    "instruments": [
        ("date", STR),
        ("venue", STR),
        ("symbol", STR),
        ("streams", STR),
        ("in_catalogue", pa.bool_()),
        ("kind", STR),
        ("base", STR),
        ("quote", STR),
        ("size_unit", STR),
        ("units_per_contract", pa.float64()),
        ("units_per_price", pa.float64()),
        ("funding_interval_s", pa.int64()),
        ("tick", DEC),
        ("lot", DEC),
    ],
}


def files(root: str, table: str):
    if table == "instruments":
        return sorted(glob.glob(f"{root}/instruments/*.parquet"))
    return sorted(glob.glob(f"{root}/*/*/parquet/{table}/*.parquet"))


def check_schema(table: str, paths) -> None:
    schema = ds.dataset(paths, format="parquet").schema
    got = [(f.name, f.type) for f in schema]
    if got != EXPECTED[table]:
        raise SystemExit(f"{table}: expected {EXPECTED[table]}\n  got {got}")
    if any(f.nullable for f in schema):
        raise SystemExit(f"{table}: every column must be required (not null)")


def check_query_py(root: str) -> None:
    df = query.trades_duckdb(root)
    # time_bucket returns a microsecond TIMESTAMP, not TIMESTAMP_NS.
    assert str(df["minute"].dtype) == "datetime64[us, UTC]", df["minute"].dtype
    assert str(df["vwap"].dtype) == "float64", df["vwap"].dtype
    assert len(df) > 0
    venue, symbol = df.iloc[0]["venue"], df.iloc[0]["symbol"]
    if files(root, "bbo"):
        bbo = query.bbo_pyarrow(root, venue, symbol)
        assert str(bbo["recv_ts"].dtype) == "datetime64[ns, UTC]", bbo["recv_ts"].dtype
        assert str(bbo["mid"].dtype) == "float64", bbo["mid"].dtype
        assert bbo["recv_ts"].is_monotonic_increasing


def main() -> None:
    roots = sys.argv[1:]
    if not roots:
        raise SystemExit(__doc__)
    seen = set()
    for root in roots:
        for table in EXPECTED:
            paths = files(root, table)
            if paths:
                check_schema(table, paths)
                seen.add(table)
        if files(root, "trades"):
            check_query_py(root)
    missing = set(EXPECTED) - seen
    if missing:
        raise SystemExit(f"no files for tables {sorted(missing)}")
    print(f"ok: {len(seen)} tables, query.py dtypes")


if __name__ == "__main__":
    main()
