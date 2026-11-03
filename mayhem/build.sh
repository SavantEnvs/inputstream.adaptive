#!/usr/bin/env bash
#
# mayhem/build.sh — builds the fuzz harnesses (sanitized, DWARF 3) and the functional test suites
# (normal flags) of inputstream.adaptive WITHOUT Kodi: upstream's own unit-test build
# (INPUTSTREAM_TEST_BUILD + src/test/KodiStubs.h) needs no Kodi headers, so we compile the same source
# list that src/test/CMakeLists.txt names, plus the self-contained lib/webm_parser.
# Everything lands in the gitignored /mayhem/build (rebuilt from scratch on every run, offline: Bento4 comes
# from /opt/toolchains/bento4, put there by the Dockerfile).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
BUILD="$SRC/build"
BENTO_SRC=/opt/toolchains/bento4
rm -rf "$BUILD"
mkdir -p "$BUILD/fuzz/obj" "$BUILD/tests/obj" "$BUILD/bin"

# Sources of the upstream unit-test binary, minus the test files themselves.
mapfile -t LIB_SRCS < <(grep -oE '\.\./[A-Za-z0-9_/]+\.cpp' src/test/CMakeLists.txt | sed 's#^\.\./#src/#')
mapfile -t TEST_SRCS < <(grep -oE '^[[:space:]]+[A-Za-z0-9_]+\.cpp' src/test/CMakeLists.txt | sed 's/[[:space:]]//g; s#^#src/test/#')
WEBM_SRCS=(lib/webm_parser/src/*.cc)

# --- Bento4 (two builds: sanitized for fuzzing, normal for the test oracle) ---------------------------
build_bento4() {  # <dir> <cflags>
  cmake -S "$BENTO_SRC" -B "$1/bento4-build" -G Ninja -DBUILD_APPS=OFF -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_FLAGS="$2" -DCMAKE_CXX_FLAGS="$2" -DCMAKE_INSTALL_PREFIX="$1/bento4" >/dev/null
  cmake --build "$1/bento4-build" -j"$MAYHEM_JOBS" >/dev/null
  cmake --install "$1/bento4-build" >/dev/null
}
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
TEST_FLAGS="-O1 $COVERAGE_FLAGS"
build_bento4 "$BUILD/fuzz"  "$FUZZ_FLAGS"
build_bento4 "$BUILD/tests" "$TEST_FLAGS"
BENTO_LIB_F=$(find "$BUILD/fuzz/bento4" -name 'libap4.a' | head -1)
BENTO_LIB_T=$(find "$BUILD/tests/bento4" -name 'libap4.a' | head -1)

# --- compile helpers -----------------------------------------------------------------------------
CXXSTD="-std=c++20 -DINPUTSTREAM_TEST_BUILD -D__STDC_FORMAT_MACROS"
compile_set() {  # <objdir> <bento-prefix> <flags> <srcs...>   (xargs -P over "src obj" pairs)
  local objdir="$1" bento="$2" flags="$3"; shift 3
  printf '%s\n' "$@" | while read -r s; do echo "$s $objdir/$(echo "$s" | tr '/' '_').o"; done |
    xargs -P "$MAYHEM_JOBS" -L1 bash -c '
      $0 '"$CXXSTD"' '"$flags"' -I src -I lib/webm_parser/include -I lib/webm_parser -I '"$bento"'/include -c "$1" -o "$2"
    ' "$CXX" 2>&1 | grep -E 'error|Error' >&2 || true
  for s in "$@"; do [ -f "$objdir/$(echo "$s" | tr '/' '_').o" ] || { echo "compile failed: $s" >&2; return 1; }; done
}
objs() { local d="$1"; shift; for s in "$@"; do echo "$d/$(echo "$s" | tr '/' '_').o"; done; }

# --- 1) sanitized library objects -----------------------------------------------------------------
compile_set "$BUILD/fuzz/obj" "$BUILD/fuzz/bento4" "$FUZZ_FLAGS" "${LIB_SRCS[@]}"
# webm_parser's own README (Fuzzing) tells fuzz builds to cap ASCII/UTF-8/binary element sizes: a 10-byte
# header can claim a multi-GB string, which is a malloc-size report, not a parser bug.
compile_set "$BUILD/fuzz/obj" "$BUILD/fuzz/bento4" "$FUZZ_FLAGS -DWEBM_FUZZER_BYTE_ELEMENT_SIZE_LIMIT=1048576" "${WEBM_SRCS[@]}"

# leak sanitizer off by default (SPEC §6.2 item 15)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$BUILD/fuzz/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/fuzz/standalone_main.o"

LIB_OBJS=( $(objs "$BUILD/fuzz/obj" "${LIB_SRCS[@]}") )
WEBM_OBJS=( $(objs "$BUILD/fuzz/obj" "${WEBM_SRCS[@]}") )
SYSLIBS=(-lpugixml -lpthread -ldl)

# --- 2) harnesses: each linked once with libFuzzer and once with the run-once standalone driver ------
link_pair() {  # <name> <harness-obj> <objs...>
  local name="$1" hobj="$2"; shift 2
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$hobj" "$BUILD/fuzz/lsan_off.o" "$@" "${SYSLIBS[@]}" -o "$BUILD/bin/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$hobj" "$BUILD/fuzz/standalone_main.o" "$BUILD/fuzz/lsan_off.o" "$@" "${SYSLIBS[@]}" -o "$BUILD/bin/$name-standalone"
}

for kind in dash hls smooth; do
  K=$(echo "$kind" | tr a-z A-Z)
  $CXX $CXXSTD $FUZZ_FLAGS -DFUZZ_$K -I src -I "$BUILD/fuzz/bento4/include" -c mayhem/fuzz_manifest.cc -o "$BUILD/fuzz/fuzz_${kind}.o"
  link_pair "fuzz_${kind}_manifest" "$BUILD/fuzz/fuzz_${kind}.o" "${LIB_OBJS[@]}" "$BENTO_LIB_F"
done

$CXX $CXXSTD $FUZZ_FLAGS -I lib/webm_parser/include -c lib/webm_parser/fuzzing/webm_fuzzer.cc -o "$BUILD/fuzz/webm_fuzzer.o"
link_pair webm_fuzzer "$BUILD/fuzz/webm_fuzzer.o" "${WEBM_OBJS[@]}"

# --- 3) test oracle: upstream's gtest suites, normal flags --------------------------------------------
compile_set "$BUILD/tests/obj" "$BUILD/tests/bento4" "$TEST_FLAGS" "${LIB_SRCS[@]}" "${TEST_SRCS[@]}"
$CXX $TEST_FLAGS $(objs "$BUILD/tests/obj" "${LIB_SRCS[@]}" "${TEST_SRCS[@]}") "$BENTO_LIB_T" \
     -lpugixml -lgtest -lpthread -ldl -o "$BUILD/bin/inputstream.adaptive_test"

WEBM_TESTS=(lib/webm_parser/tests/*.cc lib/webm_parser/test_utils/*.cc)
compile_set "$BUILD/tests/obj" "$BUILD/tests/bento4" "$TEST_FLAGS" "${WEBM_SRCS[@]}" "${WEBM_TESTS[@]}"
$CXX $TEST_FLAGS $(objs "$BUILD/tests/obj" "${WEBM_SRCS[@]}" "${WEBM_TESTS[@]}") \
     -lgmock -lgtest -lgtest_main -lpthread -o "$BUILD/bin/webm_parser_test"
