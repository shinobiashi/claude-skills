#!/usr/bin/env bash
# Scenario tests for mutate-check.sh using a throwaway git repo and a fake
# test runner (no network, no real test suite).
# Usage: bash test-mutate-check.sh [path/to/mutate-check.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/mutate-check.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi }

# ---- fixture: a repo with a "guard" and a fake runner that only fails when
#      the guard is gone.
git init -q "$W/repo"
cd "$W/repo" || exit 2
git config user.email t@example.com
git config user.name tester

cat > guard.php <<'EOF'
<?php
function visible( $ids ) {
	return array_filter( $ids, 'current_user_can' );
}
EOF

# Fails (exit 1) when the guard line is missing — i.e. a covered guard.
cat > runner.sh <<'EOF'
#!/usr/bin/env bash
if grep -q "current_user_can" guard.php; then
	echo "OK (3 tests, 5 assertions)"
	exit 0
fi
echo "There was 1 failure:"
echo ""
echo "1) Test_Guard::test_hides_invisible_items"
echo "Failed asserting that two arrays are identical."
exit 1
EOF
chmod +x runner.sh

# A runner that never notices anything — i.e. an uncovered guard.
cat > blind.sh <<'EOF'
#!/usr/bin/env bash
echo "OK (3 tests, 5 assertions)"
exit 0
EOF
chmod +x blind.sh

git add . && git commit -q -m init
ORIGINAL="$(cat guard.php)"

clean_tree() { git diff --quiet -- guard.php; }

echo "mutate-check.sh"

# ---- 1. a covered guard: mutation caught, file restored
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "caught: exits 0 when the mutation breaks a test" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
check "caught: says CAUGHT" "$(echo "$OUT" | grep -q 'CAUGHT' && echo 0 || echo 1)"
check "caught: restores the file" "$(clean_tree && echo 0 || echo 1)"
check "caught: content is byte-identical" "$( [ "$(cat guard.php)" = "$ORIGINAL" ] && echo 0 || echo 1 )"

# ---- 2. an uncovered guard: mutation not caught, file still restored
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./blind.sh \
	--delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "uncovered: exits 1 when the tests pass anyway" "$( [ "$STATUS" -eq 1 ] && echo 0 || echo 1 )"
check "uncovered: says NOT CAUGHT" "$(echo "$OUT" | grep -q 'NOT CAUGHT' && echo 0 || echo 1)"
check "uncovered: restores the file" "$(clean_tree && echo 0 || echo 1)"

# ---- 3. a no-op mutation is refused (would otherwise read as "covered")
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--delete-matching 'this_pattern_matches_nothing' 2>&1)"
STATUS=$?
check "no-op: exits 2" "$( [ "$STATUS" -eq 2 ] && echo 0 || echo 1 )"
check "no-op: explains that nothing changed" "$(echo "$OUT" | grep -q 'changed nothing' && echo 0 || echo 1)"
check "no-op: leaves the file alone" "$(clean_tree && echo 0 || echo 1)"

# ---- 4. --expect matches the failing test name
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--expect 'test_hides_invisible_items' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "expect: exits 0 when the named test fails" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"

# ---- 5. --expect naming a test that did not fail
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--expect 'test_some_other_thing' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "expect: exits 1 when a different test failed" "$( [ "$STATUS" -eq 1 ] && echo 0 || echo 1 )"
check "expect: says which expectation missed" "$(echo "$OUT" | grep -q 'NOT CAUGHT BY THE NAMED TEST' && echo 0 || echo 1)"

# ---- 6. a dirty file is refused (restore could not be verified)
echo "// scratch" >> guard.php
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "dirty: exits 2" "$( [ "$STATUS" -eq 2 ] && echo 0 || echo 1 )"
check "dirty: mentions uncommitted changes" "$(echo "$OUT" | grep -q 'uncommitted changes' && echo 0 || echo 1)"
check "dirty: points at --allow-dirty" "$(echo "$OUT" | grep -q -- '--allow-dirty' && echo 0 || echo 1)"

# ---- 6b. --allow-dirty: a fix that is not committed yet (waiting at a
#      confirmation gate) can be checked; the uncommitted change survives
DIRTY="$(cat guard.php)"
same_as_dirty() { [ "$(cat guard.php)" = "$DIRTY" ]; }
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh --allow-dirty \
	--expect 'test_hides_invisible_items' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "allow-dirty: exits 0 when caught" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
check "allow-dirty: says CAUGHT" "$(echo "$OUT" | grep -q 'CAUGHT' && echo 0 || echo 1)"
check "allow-dirty: restores the uncommitted content byte-for-byte" "$(same_as_dirty && echo 0 || echo 1)"
check "allow-dirty: the uncommitted change is still uncommitted" "$(clean_tree && echo 1 || echo 0)"
check "allow-dirty: prints where the pre-run copy is" "$(echo "$OUT" | grep -q 'pre-run copy' && echo 0 || echo 1)"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./blind.sh --allow-dirty \
	--delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "allow-dirty: exits 1 when not caught" "$( [ "$STATUS" -eq 1 ] && echo 0 || echo 1 )"
check "allow-dirty: restored after a miss too" "$(same_as_dirty && echo 0 || echo 1)"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh --allow-dirty \
	--delete-matching 'this_pattern_matches_nothing' 2>&1)"
STATUS=$?
check "allow-dirty: a no-op mutation is still refused" "$( [ "$STATUS" -eq 2 ] && echo "$OUT" | grep -q 'changed nothing' && echo 0 || echo 1)"
OUT="$(bash "$SCRIPT" --file guard.php --dry-run --allow-dirty \
	--replace "'current_user_can'" "'__return_true'" 2>&1)"
STATUS=$?
check "allow-dirty dry-run: shows the mutation" "$( [ "$STATUS" -eq 0 ] && echo "$OUT" | grep -q '^+.*__return_true' && echo 0 || echo 1)"
check "allow-dirty dry-run: does not show the uncommitted change as part of it" "$(echo "$OUT" | grep -qE '^[-+]// scratch' && echo 1 || echo 0)"
check "allow-dirty dry-run: restores" "$(same_as_dirty && echo 0 || echo 1)"
printf '#!/usr/bin/env bash\nexit 143\n' > killed.sh && chmod +x killed.sh
bash "$SCRIPT" --file guard.php --test-cmd ./killed.sh --allow-dirty --quiet \
	--delete-matching 'current_user_can' >/dev/null 2>&1
check "allow-dirty: restores after an interrupted runner" "$(same_as_dirty && echo 0 || echo 1)"
git checkout -q -- guard.php
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh --allow-dirty \
	--delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "allow-dirty on a clean file: works as usual" "$( [ "$STATUS" -eq 0 ] && clean_tree && echo 0 || echo 1)"

# ---- 7. --replace and --dry-run
OUT="$(bash "$SCRIPT" --file guard.php --dry-run \
	--replace "'current_user_can'" "'__return_true'" 2>&1)"
STATUS=$?
check "dry-run: exits 0" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
check "dry-run: shows the diff" "$(echo "$OUT" | grep -q '__return_true' && echo 0 || echo 1)"
check "dry-run: restores without running tests" "$(clean_tree && echo 0 || echo 1)"

# ---- 8. --replace-file for a multi-line body
printf 'function visible( $ids ) {\n\treturn array_filter( $ids, '"'"'current_user_can'"'"' );\n}\n' > "$W/old.txt"
printf 'function visible( $ids ) {\n\treturn $ids;\n}\n' > "$W/new.txt"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--replace-file "$W/old.txt" "$W/new.txt" 2>&1)"
STATUS=$?
check "replace-file: exits 0 (caught)" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
check "replace-file: restores the file" "$(clean_tree && echo 0 || echo 1)"

# ---- 9. restores even when the runner is killed mid-way
cat > slow.sh <<'EOF'
#!/usr/bin/env bash
exit 143
EOF
chmod +x slow.sh
bash "$SCRIPT" --file guard.php --test-cmd ./slow.sh --quiet \
	--delete-matching 'current_user_can' >/dev/null 2>&1
check "interrupted runner: still restores" "$(clean_tree && echo 0 || echo 1)"

# ---- 10. rejects two mutations at once
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--delete-matching 'a' --replace 'b' 'c' 2>&1)"
STATUS=$?
check "two mutations: exits 2" "$( [ "$STATUS" -eq 2 ] && echo 0 || echo 1 )"

# ---- 11. --expect reads Vitest and Jest failure headers too
cat > vitest.sh <<'EOF'
#!/usr/bin/env bash
if grep -q "current_user_can" guard.php; then
	echo " Test Files  1 passed (1)"
	exit 0
fi
echo " ❯ assets/src/Guard.test.tsx (3 tests | 1 failed) 40ms"
echo "     ✓ shows visible items 5ms"
echo "     × hides invisible items 12ms"
echo " FAIL  assets/src/Guard.test.tsx > Guard > hides invisible items"
echo "      Tests  1 failed | 2 passed (3)"
exit 1
EOF
cat > jest.sh <<'EOF'
#!/usr/bin/env bash
if grep -q "current_user_can" guard.php; then
	exit 0
fi
echo "  Guard"
echo "    ✓ shows visible items (3 ms)"
echo "    ✕ hides invisible items (5 ms)"
echo "  ● Guard › hides invisible items"
exit 1
EOF
chmod +x vitest.sh jest.sh
for runner in vitest jest; do
	OUT="$(bash "$SCRIPT" --file guard.php --test-cmd "./$runner.sh" \
		--expect 'hides invisible items' --delete-matching 'current_user_can' 2>&1)"
	STATUS=$?
	check "$runner: --expect matches the failing test" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
	OUT="$(bash "$SCRIPT" --file guard.php --test-cmd "./$runner.sh" \
		--expect 'shows visible items' --delete-matching 'current_user_can' 2>&1)"
	STATUS=$?
	check "$runner: --expect ignores a test that passed" "$( [ "$STATUS" -eq 1 ] && echo 0 || echo 1 )"
done
check "vitest/jest: file restored" "$(clean_tree && echo 0 || echo 1)"

# ---- 12. a mutation that breaks the code (fatal / parse error) is BROKEN,
#      even though the named test is among the failures
cat > fatal.sh <<'EOF'
#!/usr/bin/env bash
if grep -q "current_user_can" guard.php; then
	exit 0
fi
echo "There were 2 errors:"
echo ""
echo "1) Test_Guard::test_hides_invisible_items"
echo 'Error: Class "OverwritePolicy" not found'
echo "2) Test_Guard::test_shows_visible_items"
echo 'Error: Class "OverwritePolicy" not found'
exit 2
EOF
chmod +x fatal.sh
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./fatal.sh \
	--expect 'test_hides_invisible_items' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "broken: exits 1 when the code itself broke" "$( [ "$STATUS" -eq 1 ] && echo 0 || echo 1 )"
check "broken: says BROKEN and quotes the error" "$(echo "$OUT" | grep -q 'BROKEN' && echo "$OUT" | grep -q 'not found' && echo 0 || echo 1)"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./fatal.sh --allow-errors \
	--expect 'test_hides_invisible_items' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "broken: --allow-errors accepts it" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"

# ---- 13. other tests failing too: a warning by default, a failure with --only
cat > wide.sh <<'EOF'
#!/usr/bin/env bash
if grep -q "current_user_can" guard.php; then
	exit 0
fi
echo "1) Test_Guard::test_hides_invisible_items"
echo "Failed asserting that two arrays are identical."
echo "2) Test_Guard::test_counts_items"
echo "Failed asserting that 2 is identical to 3."
exit 1
EOF
chmod +x wide.sh
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./wide.sh \
	--expect 'test_hides_invisible_items' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "others: still caught by default" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
check "others: warns about the other failure" "$(echo "$OUT" | grep -q 'WARNING: 1 other failing test' && echo 0 || echo 1)"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./wide.sh --only \
	--expect 'test_hides_invisible_items' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "--only: exits 1 when other tests failed" "$( [ "$STATUS" -eq 1 ] && echo 0 || echo 1 )"
check "--only: says NOT CAUGHT CLEANLY" "$(echo "$OUT" | grep -q 'NOT CAUGHT CLEANLY' && echo 0 || echo 1)"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./wide.sh --only \
	--expect 'test_hides_invisible_items|test_counts_items' --delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "--only: exits 0 when every failure is expected" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh --only \
	--delete-matching 'current_user_can' 2>&1)"
STATUS=$?
check "--only: without --expect is a setup error" "$( [ "$STATUS" -eq 2 ] && echo 0 || echo 1 )"
OUT="$(bash "$SCRIPT" --file guard.php --test-cmd ./runner.sh \
	--expect 'test_hides_invisible_items' --delete-matching 'current_user_can' 2>&1)"
check "clean catch: no warning" "$(echo "$OUT" | grep -q 'WARNING' && echo 1 || echo 0)"
check "broken/others: file restored" "$(clean_tree && echo 0 || echo 1)"

# ---- 14. --help prints the whole leading comment block
OUT="$(bash "$SCRIPT" --help 2>&1)"
STATUS=$?
check "help: exits 0" "$( [ "$STATUS" -eq 0 ] && echo 0 || echo 1 )"
check "help: lists --allow-dirty" "$(echo "$OUT" | grep -q -- '--allow-dirty' && echo 0 || echo 1)"
check "help: ends with the exit codes, not the code" "$(echo "$OUT" | tail -1 | grep -q 'setup error' && ! echo "$OUT" | grep -q 'pipefail' && echo 0 || echo 1)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
