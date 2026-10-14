# scripts: market-data checks

- `daycheck-diff.sh`: compares two day-close outputs (revisions of the same day).
- `pyarrow-check.sh`: type-checks `examples/query.py` against pyarrow. CI runs it after installing
  pinned Python packages.

Rules:

- Keep scripts simple and portable; take arguments rather than reading the environment.
- Do not hard-code absolute paths; take directories as arguments.
