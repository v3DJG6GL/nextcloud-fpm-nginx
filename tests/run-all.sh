#!/usr/bin/env bash
# Runs the full test suite locally. Mirrors the CI test job logic so the
# same script is the source of truth for both.
#
# Usage:
#   ./tests/run-all.sh                                          # default scenario
#   NC_IMAGE=ghcr.io/v3djg6gl/nextcloud-fpm-nginx:v33 ./tests/run-all.sh
#   SCENARIO_DB=sqlite SCENARIO_REDIS=false ./tests/run-all.sh
#
# Env vars:
#   NC_IMAGE              — image-under-test (default: local/nc-fpm-nginx:test)
#   NC_MAJOR              — major version for compose project name uniqueness
#   SCENARIO_DB           — sqlite | postgres | mysql       (default: postgres)
#   SCENARIO_REDIS        — true | false                    (default: true)
#   SCENARIO_NOTIFY_PUSH  — true | false                    (default: true)
#   SCENARIO_CRON         — none | incontainer | sidecar    (default: incontainer)
#   BATS_FILTER           — optional regex to limit which bats files run
#                           (e.g. BATS_FILTER='02|11')
set -euo pipefail

: "${NC_IMAGE:=local/nc-fpm-nginx:test}"
: "${NC_MAJOR:=33}"
: "${SCENARIO_DB:=postgres}"
: "${SCENARIO_REDIS:=true}"
: "${SCENARIO_NOTIFY_PUSH:=true}"
: "${SCENARIO_CRON:=incontainer}"

# --- Scenario sanity --------------------------------------------------------
if [ "$SCENARIO_DB" = sqlite ] && [ "$SCENARIO_NOTIFY_PUSH" = true ]; then
    echo "run-all.sh: SQLite + NOTIFY_PUSH_ENABLE=true is not a valid scenario" >&2
    echo "            (notify_push requires a non-SQLite DB)" >&2
    exit 2
fi
if [ "$SCENARIO_DB" = sqlite ] && [ "$SCENARIO_REDIS" = true ]; then
    echo "run-all.sh: warning: SCENARIO_DB=sqlite forces SCENARIO_REDIS=false (no Redis service in sqlite fixture)" >&2
    SCENARIO_REDIS=false
fi

# --- Pick compose fixture ---------------------------------------------------
case "$SCENARIO_DB" in
    sqlite)   COMPOSE_FILE=tests/compose/sqlite-noredis.yaml ;;
    postgres) COMPOSE_FILE=tests/compose/postgres-redis.yaml ;;
    mysql)    COMPOSE_FILE=tests/compose/mariadb-redis.yaml  ;;
    *) echo "run-all.sh: unknown SCENARIO_DB: $SCENARIO_DB" >&2; exit 2 ;;
esac

# --- Compose profiles based on cron choice ---------------------------------
COMPOSE_PROFILES=
NC_CRON_INCONTAINER=false
case "$SCENARIO_CRON" in
    none)        ;;
    incontainer) NC_CRON_INCONTAINER=true ;;
    sidecar)     COMPOSE_PROFILES=cron-sidecar ;;
    *) echo "run-all.sh: unknown SCENARIO_CRON: $SCENARIO_CRON" >&2; exit 2 ;;
esac

# Unique project name so concurrent test runs in CI don't collide.
COMPOSE_PROJECT_NAME="nctest-${NC_MAJOR}-${SCENARIO_DB}-np${SCENARIO_NOTIFY_PUSH}-cron${SCENARIO_CRON}-$$"

export NC_IMAGE NC_MAJOR \
       SCENARIO_DB SCENARIO_REDIS SCENARIO_NOTIFY_PUSH SCENARIO_CRON \
       NC_CRON_INCONTAINER \
       COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES

mkdir -p tests/reports

# --- Banner -----------------------------------------------------------------
cat <<EOF
─────────────────────────────────────────────────────────────────
  nextcloud-fpm-nginx test suite
  Image:                $NC_IMAGE
  NC major:             $NC_MAJOR
  DB:                   $SCENARIO_DB
  Redis:                $SCENARIO_REDIS
  notify_push:          $SCENARIO_NOTIFY_PUSH
  Cron:                 $SCENARIO_CRON
  Compose file:         $COMPOSE_FILE
  Compose project:      $COMPOSE_PROJECT_NAME
  Compose profiles:     ${COMPOSE_PROFILES:-<none>}
─────────────────────────────────────────────────────────────────
EOF

# --- Step 1: image must be present locally ---------------------------------
if ! docker image inspect "$NC_IMAGE" >/dev/null 2>&1; then
    echo "Image $NC_IMAGE not present locally — pulling..."
    docker pull "$NC_IMAGE" || {
        echo "Could not pull image. Build it first or set NC_IMAGE." >&2
        exit 2
    }
fi

# --- Step 2: container-structure-test (image-static assertions) ------------
echo
echo "── Container Structure Tests ─────────────────────────────────────"
if command -v container-structure-test >/dev/null 2>&1; then
    for cfg in tests/cst/*.yaml; do
        echo "[CST] $cfg"
        container-structure-test test --image "$NC_IMAGE" --config "$cfg"
    done
else
    echo "container-structure-test not installed; skipping CST phase."
    echo "Install via: https://github.com/GoogleContainerTools/container-structure-test"
fi

# --- Step 3: boot fixture ---------------------------------------------------
echo
echo "── Bringing up fixture ───────────────────────────────────────────"
cleanup() {
    echo
    echo "── Tearing down fixture ──────────────────────────────────────────"
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" logs --tail=200 \
        > "tests/reports/${COMPOSE_PROJECT_NAME}.log" 2>&1 || true
    docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" \
        down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" up -d --wait

# --- Step 4: bats suite -----------------------------------------------------
echo
echo "── bats runtime tests ────────────────────────────────────────────"
if ! command -v bats >/dev/null 2>&1; then
    echo "bats not installed. Install with: apt install bats  (or git clone https://github.com/bats-core/bats-core)" >&2
    exit 2
fi

BATS_FILES=$(ls tests/bats/*.bats 2>/dev/null | sort)
if [ -n "${BATS_FILTER:-}" ]; then
    BATS_FILES=$(printf '%s\n' "$BATS_FILES" | grep -E "$BATS_FILTER" || true)
fi
if [ -z "$BATS_FILES" ]; then
    echo "(no bats files to run)"
    exit 0
fi

BATS_REPORT="tests/reports/${COMPOSE_PROJECT_NAME}.xml"
# bats supports -j N for parallel files; on tight test fixtures this can be
# flaky (shared container, race conditions). Stick to sequential by default;
# user can override with BATS_JOBS=4 ./tests/run-all.sh
: "${BATS_JOBS:=1}"

# shellcheck disable=SC2086
bats -j "$BATS_JOBS" --report-formatter junit -o tests/reports/ $BATS_FILES
