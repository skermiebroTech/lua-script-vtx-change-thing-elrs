#!/bin/sh
# check.sh : syntax checks (EdgeTX luac 5.3 + desktop luac 5.5) for every .lua file
# of the widget and of tests/, then the harness self-test, the scenario tests
# in both firmware modes (rc1 and 2.12.x) and every tests/unit/*_test.lua.
#
#   sh tests/check.sh                  (from anywhere; paths may contain spaces)
#   sh tests/check.sh --only a,b-rc1   (extra arguments go to tests/run.lua)
#
# Exit code 0 only when every check passes.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ETX="$ROOT/tools/edgetx-luac"
WIDGET="$ROOT/radio sd card/WIDGETS/FPVDASH"
TESTS="$ROOT/tests"
LUA="${LUA:-lua}"
LUAC="${LUAC:-luac}"

LIST="$(mktemp "${TMPDIR:-/tmp}/fpvdash_check.XXXXXX")"
trap 'rm -f "$LIST"' EXIT

find "$WIDGET" "$TESTS" -name '*.lua' -type f | sort > "$LIST"

files=0
bad=0
while IFS= read -r f; do
  files=$((files + 1))
  if [ -x "$ETX" ]; then
    if ! out=$("$ETX" -p "$f" 2>&1); then
      echo "EDGETX-LUAC FAIL: $f"
      echo "$out"
      bad=$((bad + 1))
    fi
  fi
  if ! out=$("$LUAC" -p "$f" 2>&1); then
    echo "LUAC 5.5 FAIL: $f"
    echo "$out"
    bad=$((bad + 1))
  fi
done < "$LIST"

if [ ! -x "$ETX" ]; then
  echo "WARNING: $ETX not found or not executable: EdgeTX syntax check skipped"
  bad=$((bad + 1))
fi
echo "syntax: $files files checked, $bad problems"

cd "$ROOT" || exit 2

echo
echo "== harness self-test =="
"$LUA" tests/run.lua --selftest
selftest=$?

echo
echo "== FPVDASH scenarios, firmware mode rc1 (the radio today) =="
"$LUA" tests/run.lua --mode rc1 "$@"
scen=$?

echo
echo "== FPVDASH scenarios, firmware mode 2.12.x (after an update) =="
"$LUA" tests/run.lua --mode v212x "$@"
scen212=$?

# Unit tests: each file in its own process (some install globals or call os.exit).
echo
echo "== unit tests (tests/unit/*_test.lua) =="
units=0
unitbad=0
for f in tests/unit/*_test.lua; do
  units=$((units + 1))
  if out=$("$LUA" "$f" 2>&1); then
    echo "PASS  $f  ($(printf '%s\n' "$out" | tail -n 1))"
  else
    echo "FAIL  $f"
    printf '%s\n' "$out" | tail -n 25
    unitbad=$((unitbad + 1))
  fi
done

echo
echo "================ SUMMARY ================"
if [ "$bad" -eq 0 ]; then echo "syntax checks     : PASS ($files files)"; else echo "syntax checks     : FAIL ($bad problems)"; fi
if [ "$selftest" -eq 0 ]; then echo "self-test         : PASS"; else echo "self-test         : FAIL (see tests/out/selftest_report.txt)"; fi
if [ "$scen" -eq 0 ]; then echo "scenarios rc1     : PASS"; else echo "scenarios rc1     : FAIL (see tests/out/report.txt)"; fi
if [ "$scen212" -eq 0 ]; then echo "scenarios 2.12.x  : PASS"; else echo "scenarios 2.12.x  : FAIL (see tests/out/v212x/report.txt)"; fi
if [ "$unitbad" -eq 0 ]; then echo "unit tests        : PASS ($units files)"; else echo "unit tests        : FAIL ($unitbad of $units files)"; fi

if [ "$bad" -eq 0 ] && [ "$selftest" -eq 0 ] && [ "$scen" -eq 0 ] && [ "$scen212" -eq 0 ] && [ "$unitbad" -eq 0 ]; then
  exit 0
fi
exit 1
