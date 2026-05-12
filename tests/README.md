# Test suite

Exhaustive test coverage for `nextcloud-fpm-nginx`. Runs the same suite
locally and in CI — no drift.

## Layout

```
tests/
├── cst/         # container-structure-test (Google) — image-structure assertions
├── bats/        # bats-core — runtime tests against a booted container
├── helpers/     # shared bash libraries sourced from bats files
├── fixtures/    # static files mounted into containers for tests
├── compose/     # docker compose fixtures (postgres+redis, mariadb+redis, sqlite-only)
├── reports/     # JUnit XML output (gitignored)
└── run-all.sh   # entry point — invokes CST + bats with fixture lifecycle
```

## Dependencies (local)

- `docker` and `docker compose` (v2)
- [`bats-core`](https://github.com/bats-core/bats-core) ≥ 1.10 (`apt install bats` on Debian/Ubuntu; or `git clone … && ./install.sh`)
- [`container-structure-test`](https://github.com/GoogleContainerTools/container-structure-test) — install via:
  ```
  curl -fsSL -o /usr/local/bin/container-structure-test \
    https://storage.googleapis.com/container-structure-test/latest/container-structure-test-linux-amd64
  chmod +x /usr/local/bin/container-structure-test
  ```
- `curl`, `jq`, `python3` (for JSON parsing in tests)

CI installs both `bats-core` and `container-structure-test` via official
GitHub Actions:
- `bats-core/bats-action@3.0.1`
- `plexsystems/container-structure-test-action@c0a028aa…` (v0.3.0)

## Running locally

```bash
# Default: postgres + redis + notify_push + cron-in-container
./tests/run-all.sh

# Override scenario via env vars
SCENARIO_DB=sqlite SCENARIO_REDIS=false SCENARIO_NOTIFY_PUSH=false \
SCENARIO_CRON=none ./tests/run-all.sh

# Use a specific image tag (defaults to local/nc-fpm-nginx:test)
NC_IMAGE=ghcr.io/v3djg6gl/nextcloud-fpm-nginx:v33 ./tests/run-all.sh
```

## Scenario matrix

| `SCENARIO_DB` | `SCENARIO_REDIS` | `SCENARIO_NOTIFY_PUSH` | `SCENARIO_CRON` |
|---|---|---|---|
| `sqlite` | `false` | `false` | `none` / `incontainer` / `sidecar` |
| `postgres` | `true` | `true` / `false` | `none` / `incontainer` / `sidecar` |
| `mysql` | `true` | `true` / `false` | `none` / `incontainer` / `sidecar` |

Notes:
- `notify_push` requires a non-SQLite database AND Redis — invalid
  combinations are auto-rejected by the wrapper.
- `cron=sidecar` brings up a second container in the compose stack via
  `COMPOSE_PROFILES=cron-sidecar`.
- `cron=incontainer` sets `NEXTCLOUD_CRON_ENABLE=true` on the main container.

## CI

Every push runs the full cartesian matrix (2 majors × 15 scenarios = 30
cells) on `ubuntu-latest` + smoke (CST + container start) on
`ubuntu-24.04-arm` (2 cells per major). The `build` job waits on both
test jobs — failed tests block the push to ghcr.io.

JUnit XML is uploaded as a workflow artifact and surfaced inline on PRs
via `mikepenz/action-junit-report`.

## Tests not covered (by design)

Some scenarios from the failure-mode research are noted in the plan but
deferred to **manual verification** because they can't be cheaply tested
in CI:

- Chunked-upload assembly correctness (needs >1 GB PUT through a proxy)
- `rsync` hang mid-upgrade (needs deliberate interruption + recovery)
- NFS-specific quirks (`no_root_squash`, locking)
- `config.php` filesystem-permission edge cases
- Real-arm64 runtime bugs (smoke-only on arm64 native runner)

If you hit one of these in production, capture the diagnostic data and
file an issue.

## Failure mode → test file map

See the plan at `~/.claude/plans/sparkling-orbiting-globe.md` for the
exhaustive mapping. Briefly: all 30 ranked failure modes from
`nextcloud/docker` issue research are exercised by at least one bats
file, except the four manual-only ones above.
