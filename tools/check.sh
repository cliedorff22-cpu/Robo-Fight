#!/bin/sh
# Parse every script and run the headless tests.
#   tools/check.sh              parse + every test suite + the wheel audit
#   tools/check.sh parse        parse only
#   tools/check.sh core career  only those suites
#   tools/check.sh record       record the suites' reference output again
#                               (tests/golden/) - after a change that is meant
#                               to alter what the logic produces
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
cd "$(dirname "$0")/.."
"$GODOT" --headless --path . --import >/dev/null 2>&1
"$GODOT" --headless --path . -s tests/parse_all.gd > .parse.log 2>&1
status=$?
grep -v "^Godot Engine" .parse.log | grep -v "^$" | head -60
rm -f .parse.log
[ $status -ne 0 ] && exit 1
[ "$1" = "parse" ] && exit 0
"$GODOT" --headless --path . -s tests/run_tests.gd -- "$@" 2>&1 | grep -v "^Godot Engine" | grep -v "^$"
# Every robot's wheels: nothing may cut into a tyre (tools/wheel_audit.gd).
if [ $# -eq 0 ]; then
  "$GODOT" --headless --path . -s tools/wheel_audit.gd 2>&1 | grep -E "cut +([3-9]|[0-9]{2,}) mm|cutting into a tyre"
fi
