#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's own gtest suites (manifest-parser tests in src/test and the webm_parser
# unit tests), already built by mayhem/build.sh with normal flags. They assert parsed values (segment
# counts, URLs, timings, codecs, DRM info, ...); a program that exits 0 immediately produces no gtest
# summary and is counted as a failure here.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/build/bin"
passed=0; failed=0; skipped=0; ran_any=0

run_gtest() {  # <name> <cmd...> — accumulates passed/failed/skipped from gtest's summary lines
  local name="$1"; shift
  local out; out=$("$@" 2>&1); local rc=$?
  printf '%s\n' "$out" | tail -n 15
  local total f s
  total=$(printf '%s\n' "$out" | sed -n 's/^\[==========\] \([0-9]\+\) tests\? from .* ran\..*/\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9]\+\) tests\?, listed below:.*/\1/p' | tail -1)
  s=$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9]\+\) tests\?, listed below:.*/\1/p' | tail -1)
  if [ -z "$total" ] || [ "$total" -eq 0 ]; then
    echo "$name: no gtest summary (runner missing, crashed or neutered)" >&2
    failed=$((failed + 1)); return
  fi
  : "${f:=0}" "${s:=0}"
  ran_any=1
  [ "$rc" -ne 0 ] && [ "$f" -eq 0 ] && f=1
  passed=$((passed + total - f - s)); failed=$((failed + f)); skipped=$((skipped + s))
}

for exe in inputstream.adaptive_test webm_parser_test; do
  [ -x "$BIN/$exe" ] || { echo "missing $BIN/$exe (mayhem/build.sh builds it)" >&2; failed=$((failed + 1)); continue; }
done
run_gtest manifest-tests "$BIN/inputstream.adaptive_test" "$SRC/src/test/manifests"
# Upstream builds no CMake target for the webm_parser unit tests; these four Seek* tests already fail
# on pristine upstream (parser returns -3 instead of kOkCompleted after DidSeek()), so they are excluded.
run_gtest webm-tests "$BIN/webm_parser_test" \
  "--gtest_filter=-ClusterParserTest.SkipOnClusterBegin:SegmentParserTest.Seek:WebmParserTest.SeekEbml:WebmParserTest.SeekSegment"

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
