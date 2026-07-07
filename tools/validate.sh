#!/bin/sh
# VizG validation script.
#
# Builds, runs tests, and exercises the CLI on representative fixtures. All
# output is appended to a timestamped log under logs/. Exit code reflects whether
# the build+tests succeeded (0) or not (non-zero).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
LOGS_DIR="${REPO_ROOT}/logs"
mkdir -p "${LOGS_DIR}"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOGS_DIR}/validate-${STAMP}.log"

# Truncate the log file before starting so we get a clean run every time.
: > "${LOG}"

run_and_log() {
    # Run a command, capture output to LOG alongside any non-zero exit codes.
    printf "%s\n" "--> $*" >> "${LOG}" 2>&1 || true
    "$@" >> "${LOG}" 2>&1
}

cd "${REPO_ROOT}"

# --- build ---------------------------------------------------------------
{
    echo "== zig build =="
    zig build --global-cache-dir /tmp/zigcache || { echo "FAIL: zig build exited non-zero"; exit 1; }
    echo
} >> "${LOG}"

# --- run tests -----------------------------------------------------------
# `zig build test --summary all` exercises both the library module tests and
# the executable module tests in a single pass. The --summary flag prints a
# concise summary line at the end so we get an authoritative pass/fail without
# inspecting each binary individually.
{
    echo "== zig build test --summary all =="
    zig build test --global-cache-dir /tmp/zigcache --summary all || { echo "FAIL: tests exited non-zero"; exit 1; }
    echo
} >> "${LOG}"

# --- CLI smoke checks ----------------------------------------------------
BIN="./zig-out/bin/vizg"

{
    echo "== vizg help =="
    "${BIN}" help || { echo "FAIL: vizg help"; exit 1; }
    echo
} >> "${LOG}"

run_cli_fixture() {
    printf "%s\n" "== modules: $* ===" >> "${LOG}"
    timeout 5 "${BIN}" modules "$@" || true
    echo "" >> "${LOG}"
}

{ run_cli_fixture "named import (Case A)" test/modules/linking/named/main.ts; }
{ run_cli_fixture "aliased import (Case B)" test/modules/linking/aliased-import/main.ts; }
{ run_cli_fixture "aliased export (Case C)" test/modules/linking/alias-export/main.ts; }
{ run_cli_fixture "external import (Case D)" test/modules/linking/external/main.ts; }
{ run_cli_fixture "missing module (Case E)" test/modules/linking/missing-module/main.ts; }
{ run_cli_fixture "missing export (Case F)" test/modules/linking/missing-export/main.ts; }

CAPABILITIES="test/frontend/vizg_capabilities_test.ts"
if [ -f "${REPO_ROOT}/${CAPABILITIES}" ]; then
    {
        echo "== check: vizg check ${CAPABILITIES} =="
        "${BIN}" check "${REPO_ROOT}/${CAPABILITIES}" || true
        echo

        echo "== refs: vizg refs ${CAPABILITIES} =="
        "${BIN}" refs "${REPO_ROOT}/${CAPABILITIES}" || true
        echo
    } >> "${LOG}"
fi

echo "== done ==" >> "${LOG}"
