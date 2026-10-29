#!/usr/bin/env bash
#
# mayhem/build.sh — build dinit's control-protocol fuzz harness (src/tests/cptests/fuzz.cc), its
# standalone reproducer, and dinit's own unit-test suite (normal flags) for mayhem/test.sh.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Project's normal build config + unit tests (upstream's own flags; no LTO because the base
#    image's linker has no LTO plugin). Objects land in src/tests/*.o (gitignored), mconfig and
#    build/includes/mconfig.h are generated here and shared with the fuzz build below.
CXXFLAGS="-std=c++11 -Wall -Os -fno-plt -fno-rtti" TEST_CXXFLAGS="-std=c++11 -Wall -Os -fno-plt -fno-rtti $COVERAGE_FLAGS" \
    LDFLAGS="" LDFLAGS_BASE="" TEST_LDFLAGS="$COVERAGE_FLAGS" ./configure --disable-capabilities
make -C build all
make -C src/tests -j"$MAYHEM_JOBS" build-tests

# 2) Sanitized + coverage-instrumented fuzz build in mayhem/obj (gitignored, wiped each run).
OBJ="$SRC/mayhem/obj"
rm -rf "$OBJ"
mkdir -p "$OBJ"
INC="-I$SRC/src/tests/test-includes -I$SRC/dasynq/include -I$SRC/build/includes -I$SRC/src/includes"
FLAGS="-std=c++11 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"

pids=()
objs=()
for f in control dinit-log service load-service proc-service baseproc-service dinit-env settings dinit-iostream; do
    objs+=("$OBJ/$f.o")
    $CXX $FLAGS $INC -c "$SRC/src/$f.cc" -o "$OBJ/$f.o" &
    pids+=($!)
done
for f in test-bpsys test-dinit test-run-child-proc; do
    objs+=("$OBJ/$f.o")
    $CXX $FLAGS $INC -c "$SRC/src/tests/$f.cc" -o "$OBJ/$f.o" &
    pids+=($!)
done
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o" &
pids+=($!)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o" &
pids+=($!)
$CXX $FLAGS $INC -c "$SRC/src/tests/cptests/fuzz.cc" -o "$OBJ/fuzz.o" &
pids+=($!)
for p in "${pids[@]}"; do wait "$p"; done

$CXX $FLAGS $LIB_FUZZING_ENGINE "$OBJ/fuzz.o" "${objs[@]}" "$OBJ/lsan_off.o" -o "$SRC/cptests-fuzz"
$CXX $FLAGS "$OBJ/fuzz.o" "${objs[@]}" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" -o "$SRC/cptests-fuzz-standalone"
