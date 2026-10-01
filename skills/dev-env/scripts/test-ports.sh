#!/usr/bin/env bash
# Scenario tests for ports.js against throwaway repos, ledgers and a fake Studio site list.
# Usage: bash test-ports.sh [path/to/ports.js]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/ports.js}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
expect_exit() { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (exit $2, want $3)"; fi }
expect_has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing: $3)"; printf '%s\n' "$2" | sed 's/^/        /'; fi }
# expect_row <name> <output> <repo> <status> [substring of that row]: column widths vary with the longest repo key.
expect_row() {
	local line
	line=$(printf '%s\n' "$2" | grep -E "^[0-9-]{2} +$3 +$4( |\$)")
	if [ -n "$line" ] && { [ -z "${5:-}" ] || printf '%s' "$line" | grep -qF -- "$5"; }; then ok "$1"; else bad "$1 (no row: $3 $4 ${5:-})"; printf '%s\n' "$2" | sed 's/^/        /'; fi
}
expect_not() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (unexpected: $3)"; else ok "$1"; fi }

ROOT="$W/dev"
LEDGER="$W/ledger.json"
STUDIO="$W/studio.json"
mkdir -p "$ROOT"
echo '{ "sites": [ { "name": "Shop A", "port": 8881 }, { "name": "Shop B", "port": 8882 } ] }' > "$STUDIO"

repo() { mkdir -p "$ROOT/$1" && printf '%s\n' "$2" > "$ROOT/$1/.wp-env.json"; }
run() { node "$SCRIPT" "$@" --root "$ROOT" --ledger "$LEDGER" --studio "$STUDIO" 2>&1; }

cat > "$LEDGER" <<'EOF'
{
	"comment": "test ledger",
	"repos": [
		{ "slot": 1, "repo": "alpha" },
		{ "slot": 2, "repo": "beta" },
		{ "slot": 3, "repo": "gamma" },
		{ "slot": 4, "repo": "delta" },
		{ "slot": 5, "repo": "epsilon" },
		{ "slot": 6, "repo": "zeta" },
		{ "slot": 7, "repo": "nested/trunk" },
		{ "slot": 9, "repo": "ghost" }
	]
}
EOF

repo alpha '{ "port": 10010, "testsPort": 10011, "phpmyadminPort": 10012, "env": { "tests": { "phpmyadminPort": 10013 } } }'
repo beta '{ "plugins": [ "." ] }'
repo gamma '{ "env": { "development": { "port": 10030, "phpmyadminPort": 10032 }, "tests": { "port": 10031, "phpmyadminPort": 10033 } } }'
repo delta '{ "port": 8890, "testsPort": 8891 }'
printf '%s\n' '{ "port": 10040, "testsPort": 10041 }' > "$ROOT/delta/.wp-env.override.json"
repo epsilon '{ "port": 10050, "testsPort": 10051, "phpmyadminPort": 10052 }'
repo zeta '{ "port": 10060, "testsPort": 10061, "mysqlPort": 10064, "env": { "tests": { "mysqlPort": 10065 } } }'
repo nested/trunk '{ "port": 10070, "testsPort": 10071 }'

echo "get / list"
out=$(run get alpha); rc=$?
expect_exit "get: registered key exits 0" $rc 0
expect_has "get: prints the slot's ports" "$out" '"slot":1,"port":10010,"testsPort":10011,"phpmyadminPort":10012,"testsPhpmyadminPort":10013'
out=$(cd "$ROOT/nested/trunk" && node "$SCRIPT" get --root "$ROOT" --ledger "$LEDGER" 2>&1); rc=$?
expect_exit "get: cwd resolves to its path relative to the root" $rc 0
expect_has "get: nested key" "$out" '"repo":"nested/trunk","slot":7'
out=$(run get unknown); rc=$?
expect_exit "get: unregistered repo exits 4" $rc 4
out=$(run list); rc=$?
expect_exit "list exits 0" $rc 0
expect_has "list: shows slot 09 ports" "$out" '09    10090/10091'

echo "check: all good"
out=$(run check); rc=$?
expect_exit "check: an error row makes the run exit 1" $rc 1
expect_row "check: root keys -> ok" "$out" alpha ok
expect_row "check: env.development/env.tests keys -> ok" "$out" gamma ok
expect_row "check: .wp-env.override.json wins over .wp-env.json" "$out" delta ok '10040/10041 (override)'
expect_row "check: phpMyAdmin missing from env.tests (root value inherited) -> error" "$out" epsilon ERROR
expect_has "check: names the shared phpMyAdmin port" "$out" 'phpmyadminPort 10052 is shared by development and tests'
expect_row "check: mysqlPort inside the slot's spare range -> ok" "$out" zeta ok
expect_row "check: defaults -> pending" "$out" beta pending '8888/8889 (default)'
expect_row "check: nested repo key" "$out" nested/trunk ok
expect_has "check: pending names the target ports" "$out" 'migrate to 10020/10021 pma 10022/10023'
expect_has "check: pending flags the Studio band" "$out" 'in the Studio band: 8888, 8889'
expect_row "check: ledger entry without a repo -> missing" "$out" ghost missing
expect_has "check: Studio summary" "$out" 'Studio: 2 site(s), ports 8881-8882'

# epsilon made the run fail above; fix it and the rest of the scenarios start from a clean pass.
repo epsilon '{ "port": 10050, "testsPort": 10051, "phpmyadminPort": 10052, "env": { "tests": { "phpmyadminPort": 10053 } } }'
out=$(run check); rc=$?
expect_exit "check: clean tree exits 0" $rc 0
out=$(run check --strict); rc=$?
expect_exit "check --strict: pending fails" $rc 1

echo "check: errors"
repo newcomer '{ "port": 8888 }'
out=$(run check); rc=$?
expect_exit "check: unregistered repo exits 1" $rc 1
expect_has "check: unregistered repo is named with the fix" "$out" 'not in the ledger: run "ports.js assign newcomer"'
rm -rf "$ROOT/newcomer"

repo beta '{ "port": 10010, "testsPort": 10011 }'
out=$(run check); rc=$?
expect_exit "check: copied ports of another slot exit 1" $rc 1
expect_has "check: names the slot's owner" "$out" 'slot 01 belongs to alpha'
expect_has "check: names the expected ports" "$out" 'ports do not match slot 02'
repo beta '{ "plugins": [ "." ] }'

repo gamma '{ "port": 10030, "testsPort": 10031, "mysqlPort": 10012 }'
out=$(run check); rc=$?
expect_exit "check: a port of another slot (mysqlPort) exits 1" $rc 1
repo gamma '{ "env": { "development": { "port": 10030, "phpmyadminPort": 10032 }, "tests": { "port": 10031, "phpmyadminPort": 10033 } } }'

printf '{ "port": 10010' > "$ROOT/beta/.wp-env.json"
out=$(run check); rc=$?
expect_exit "check: invalid JSON exits 1" $rc 1
expect_has "check: invalid JSON is named" "$out" '.wp-env.json is not valid JSON'
repo beta '{ "plugins": [ "." ] }'

echo '{ "sites": [ { "name": "Moved", "port": 10095 } ] }' > "$W/studio-moved.json"
out=$(node "$SCRIPT" check --root "$ROOT" --ledger "$LEDGER" --studio "$W/studio-moved.json" 2>&1); rc=$?
expect_exit "check: Studio site inside the wp-env band exits 1" $rc 1
expect_has "check: names the Studio site" "$out" 'Studio site "Moved" uses 10095'

echo "assign"
cp "$LEDGER" "$W/ledger.before"
repo fresh '{ "plugins": [ "." ] }'
out=$(run assign fresh); rc=$?
expect_exit "assign: exits 0" $rc 0
expect_has "assign: skips the blocked slot 08 and takes 10" "$out" '"repo":"fresh","slot":10,"port":10100'
expect_has "assign: ledger gains one line" "$(diff "$W/ledger.before" "$LEDGER")" '> 		{ "slot": 10, "repo": "fresh" }'
expect_has "assign: line count +1" "$(wc -l < "$LEDGER" | tr -d ' ')" "$(( $(wc -l < "$W/ledger.before") + 1 ))"
cp "$LEDGER" "$W/ledger.after"
out=$(run assign fresh); rc=$?
expect_exit "assign: re-run exits 0" $rc 0
if cmp -s "$LEDGER" "$W/ledger.after"; then ok "assign: re-run leaves the ledger untouched"; else bad "assign: re-run changed the ledger"; fi

repo squatter '{ "port": 10110, "testsPort": 10111 }'
repo late '{ "plugins": [ "." ] }'
out=$(run assign late); rc=$?
expect_has "assign: skips a slot an unregistered config sits on" "$out" 'skipped slot 11: 10110 is used by squatter'
expect_has "assign: takes the next slot" "$out" '"repo":"late","slot":12'
rm -rf "$ROOT/squatter"

mkdir -p "$W/installed/dev-env"
cp "$LEDGER" "$W/installed/dev-env/ports.json"
out=$(CLAUDE_SKILLS_DIR="$W/installed" node "$SCRIPT" assign other --root "$ROOT" --ledger "$W/installed/dev-env/ports.json" --studio "$STUDIO" 2>&1); rc=$?
expect_exit "assign: refuses the installed copy (exit 3)" $rc 3
expect_has "assign: explains why" "$out" 'install.sh overwrites'
if cmp -s "$LEDGER" "$W/installed/dev-env/ports.json"; then ok "assign: installed copy untouched"; else bad "assign: installed copy was modified"; fi

echo "ledger validation"
bad_ledger() {
	printf '%s\n' "$2" > "$W/bad.json"
	out=$(node "$SCRIPT" list --ledger "$W/bad.json" 2>&1); rc=$?
	expect_exit "invalid ledger: $1 (exit 3)" $rc 3
	expect_has "invalid ledger: $1 is explained" "$out" "$3"
}
bad_ledger "duplicate slot" '{ "repos": [ { "slot": 1, "repo": "a" }, { "slot": 1, "repo": "b" } ] }' 'slot 01 is already held by a'
bad_ledger "duplicate repo" '{ "repos": [ { "slot": 1, "repo": "a" }, { "slot": 2, "repo": "a" } ] }' 'a is already registered in slot 01'
bad_ledger "blocked slot 08" '{ "repos": [ { "slot": 8, "repo": "a" } ] }' 'slot 08 is never assigned'
bad_ledger "slot out of range" '{ "repos": [ { "slot": 100, "repo": "a" } ] }' 'slot must be an integer 1-99'
bad_ledger "absolute repo path" '{ "repos": [ { "slot": 1, "repo": "/abs" } ] }' 'repo must be a path relative to the root'
bad_ledger "no repos array" '{ "slots": {} }' 'expected an object with a "repos" array'

echo "usage"
out=$(node "$SCRIPT" 2>&1); rc=$?
expect_exit "no command exits 2" $rc 2
out=$(node "$SCRIPT" frob 2>&1); rc=$?
expect_exit "unknown command exits 2" $rc 2
out=$(node "$SCRIPT" --help 2>&1); rc=$?
expect_exit "--help exits 0" $rc 0
expect_has "--help prints the header" "$out" 'Slot NN owns ports'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
