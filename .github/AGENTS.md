# .github: market-data CI

`workflows/ci.yml` runs the `infra` ox-setup action with the pins, then build, tests, DuckDB and
Python installs, and the pyarrow type check.

Rules:

- The DuckDB CLI version is pinned (v1.5.6) and must match the one the tests were written against.
- Keep the pins in dependency order and in step with `dune-project`.
- To check a run: `gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.
