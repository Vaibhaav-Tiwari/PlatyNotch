#!/bin/bash
# Runs every variant in its own process and prints a summary line per variant.
# Usage: research/isolated-deinit/run.sh   (from anywhere)
set -u
cd "$(dirname "$0")"
verdict() { case "$1" in 0) echo OK;; 3) echo SKIP;; 134) echo "CRASH(SIGABRT)";; *) echo "FAIL/CRASH";; esac; }
echo "== environment"
sw_vers; uname -m; xcodebuild -version 2>/dev/null | head -2; swift --version 2>&1 | head -1
echo "REPRO_DEPLOY=${REPRO_DEPLOY:-14.0 (default)}"
# REPRO_BIN: run prebuilt products (built on another runner) instead of building here.
if [ -n "${REPRO_BIN:-}" ]; then
  BIN="$REPRO_BIN"
else
  if ! swift build --build-tests > build.log 2>&1; then cat build.log; exit 1; fi
  BIN=$(swift build --show-bin-path)
fi
echo "== deploy target in binary"; otool -l "$BIN/Repro" | grep -A4 LC_BUILD_VERSION | grep -E "minos|sdk"
echo "== deinitOnExecutor symbols in binary"; nm "$BIN/Repro" | grep -i deinitOnExecutor || true
summary=()
for v in a_noTask_noTaskLocal a_noTask_taskLocal a_noTask_noTaskLocal_weakRef a_noTask_taskLocal_weakRef \
         control_plainDeinit_noTask_taskLocal b_task_noTaskLocal b_task_taskLocal b_task_inheritedTaskLocal \
         e_customActor_noTask_noTaskLocal e_customActor_noTask_taskLocal e_customActor_onActor_taskLocal; do
  echo "== exe $v"
  "$BIN/Repro" "$v" 2>&1; rc=$?
  summary+=("exe  $v rc=$rc $(verdict $rc)")
done
for t in test_sync_noTaskLocal test_sync_taskLocal test_sync_plainDeinit test_async_noTaskLocal test_sync_customActor; do
  echo "== xctest $t"
  if [ -n "${REPRO_BIN:-}" ]; then
    xcrun xctest -XCTest "ReproTests.ReproTests/$t" "$(ls -d "$BIN"/*.xctest)" > t.log 2>&1; rc=$?
  else
    swift test --skip-build --filter "ReproTests.ReproTests/$t" > t.log 2>&1; rc=$?
  fi
  grep -vE "^\s*$" t.log | tail -12
  summary+=("test $t rc=$rc $(verdict $rc)$(grep -q 'pointer being freed was not allocated' t.log && echo ' malloc:pointer-being-freed-not-allocated')")
done
echo "== lldb backtrace: exe a_noTask_taskLocal"
lldb --batch -o run -k "bt 14" -k "image list -b libswift_Concurrency.dylib" -k "quit 1" -- "$BIN/Repro" a_noTask_taskLocal 2>&1 \
  | grep -E "frame #|stop reason|malloc|RESULT|libswift_Concurrency" | head -24
echo "== lldb: who pushes task-locals during a synchronous XCTest (test_sync_noTaskLocal)?"
XCT=$(ls -d "$BIN"/*.xctest)
lldb --batch -o "breakpoint set -n swift_task_localValuePush" -o "run" -o "bt 8" -o "continue" -o "bt 8" -k "quit 1" \
  -- "$(xcrun --find xctest)" -XCTest "ReproTests.ReproTests/test_sync_noTaskLocal" "$XCT" 2>&1 \
  | grep -E "frame #|stop reason|malloc|passed|failed" | head -40
echo "== SUMMARY"
printf '%s\n' "${summary[@]}"
