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

# Truncate the log file so each run is a clean, deterministic snapshot.
: > "${LOG}"

cd "${REPO_ROOT}"

# --- build ---------------------------------------------------------------
echo "== zig build ==" >> "${LOG}"
zig build --global-cache-dir /tmp/zigcache || { echo "FAIL: zig build exited non-zero" >> "${LOG}"; exit 1; }
echo >> "${LOG}"

# --- run tests -----------------------------------------------------------
echo "== zig build test --summary all ==" >> "${LOG}"
zig build test --global-cache-dir /tmp/zigcache --summary all || { echo "FAIL: tests exited non-zero" >> "${LOG}"; exit 1; }
echo >> "${LOG}"

# --- CLI smoke checks ----------------------------------------------------
BIN="./zig-out/bin/vizg"

echo "== vizg help ==" >> "${LOG}"
"${BIN}" help >> "${LOG}" 2>&1 || { echo "FAIL: vizg help exited non-zero" >> "${LOG}"; exit 1; }
echo >> "${LOG}"

# run_modules_fixture LABEL FILE — writes the label as a section header, then runs `vizg modules FILE`.
# Failure is suppressed so negative fixtures still get logged without aborting the script.
run_modules_fixture() {
    printf "== %s ==\n" "$1" >> "${LOG}"
    timeout 5 "${BIN}" modules "$2" >> "${LOG}" 2>&1 || true
    echo >> "${LOG}"
}

{ run_modules_fixture "named import (Case A)" test/modules/linking/named/main.ts; }
{ run_modules_fixture "aliased import (Case B)" test/modules/linking/aliased-import/main.ts; }
{ run_modules_fixture "aliased export (Case C)" test/modules/linking/alias-export/main.ts; }
{ run_modules_fixture "external import (Case D)" test/modules/linking/external/main.ts; }
{ run_modules_fixture "missing module (Case E)" test/modules/linking/missing-module/main.ts; }
{ run_modules_fixture "missing export (Case F)" test/modules/linking/missing-export/main.ts; }

CAPABILITIES="test/frontend/vizg_capabilities_test.ts"
if [ -f "${REPO_ROOT}/${CAPABILITIES}" ]; then
    {
        echo "== vizg check ${CAPABILITIES} ==" >> "${LOG}"
        "${BIN}" check "${REPO_ROOT}/${CAPABILITIES}" >> "${LOG}" 2>&1 || true

        echo "== vizg refs ${CAPABILITIES} ==" >> "${LOG}"
        "${BIN}" refs "${REPO_ROOT}/${CAPABILITIES}" >> "${LOG}" 2>&1 || true
    }
fi

echo "== done ==" >> "${LOG}"
echo "Log written to: ${LOG}" >&2
