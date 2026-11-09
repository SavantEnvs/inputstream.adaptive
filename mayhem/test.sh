#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS the demuxer oracle built by mayhem/build.sh: ts_dump demuxes each committed
# MPEG-TS sample with lib/mpegts and prints the streams it found (pid, codec, stream info) and the number of
# elementary-stream packets; the output must equal the golden file next to it. A program that exits 0
# without demuxing prints nothing and fails the comparison.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

BIN="$SRC/build/bin/ts_dump"
[ -x "$BIN" ] || { echo "missing $BIN (mayhem/build.sh builds it)" >&2; emit_ctrf ts-dump-golden 0 1; exit $?; }

passed=0; failed=0
for golden in mayhem/golden/*.txt; do
  name=$(basename "$golden" .txt)
  sample="mayhem/fuzz_ts_demux-mined-4c1a0e1/testsuite/$name.ts"
  got=$("$BIN" "$sample" 2>&1)
  if [ -n "$got" ] && [ "$got" == "$(cat "$golden")" ]; then
    passed=$((passed + 1))
  else
    echo "FAIL $name: expected" >&2; cat "$golden" >&2; echo "got:" >&2; printf '%s\n' "$got" >&2
    failed=$((failed + 1))
  fi
done
emit_ctrf ts-dump-golden "$passed" "$failed"
