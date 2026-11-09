#!/usr/bin/env bash
#
# mayhem/build.sh — builds the MPEG-TS demuxer harness (lib/mpegts, sanitized, DWARF 3) and the
# normal-flags ts_dump tool that test.sh uses as its oracle. lib/mpegts is self-contained (no Kodi headers).
# Everything lands in the gitignored /mayhem/build, rebuilt from scratch on every run.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"
BUILD="$SRC/build"
rm -rf "$BUILD"
mkdir -p "$BUILD/fuzz/obj" "$BUILD/tests/obj" "$BUILD/bin"

CXXSTD="-std=c++17"
MPEGTS_SRCS=(lib/mpegts/*.cpp)
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS"
TEST_FLAGS="-O1"

compile_set() {  # <objdir> <flags> <srcs...>
  local objdir="$1" flags="$2"; shift 2
  printf '%s\n' "$@" | while read -r s; do echo "$s $objdir/$(basename "$s").o"; done |
    xargs -P "$MAYHEM_JOBS" -L1 bash -c '$0 '"$CXXSTD"' '"$flags"' -I lib/mpegts -c "$1" -o "$2"' "$CXX"
}
objs() { local d="$1"; shift; for s in "$@"; do echo "$d/$(basename "$s").o"; done; }

# 1) sanitized library + harness; each harness linked with libFuzzer and with the run-once driver
compile_set "$BUILD/fuzz/obj" "$FUZZ_FLAGS" "${MPEGTS_SRCS[@]}" mayhem/fuzz_ts_demux.cc
# leak sanitizer off by default (SPEC §6.2 item 15)
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$BUILD/fuzz/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/fuzz/standalone_main.o"
LIB_OBJS=( $(objs "$BUILD/fuzz/obj" "${MPEGTS_SRCS[@]}") )
HARNESS_OBJ="$BUILD/fuzz/obj/fuzz_ts_demux.cc.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$HARNESS_OBJ" "$BUILD/fuzz/lsan_off.o" "${LIB_OBJS[@]}" -lpthread -o "$BUILD/bin/fuzz_ts_demux"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$HARNESS_OBJ" "$BUILD/fuzz/standalone_main.o" "$BUILD/fuzz/lsan_off.o" "${LIB_OBJS[@]}" -lpthread -o "$BUILD/bin/fuzz_ts_demux-standalone"

# 2) test oracle: ts_dump with the project's normal flags
compile_set "$BUILD/tests/obj" "$TEST_FLAGS" "${MPEGTS_SRCS[@]}" mayhem/ts_dump.cc
$CXX $TEST_FLAGS $(objs "$BUILD/tests/obj" "${MPEGTS_SRCS[@]}" mayhem/ts_dump.cc) -lpthread -o "$BUILD/bin/ts_dump"
