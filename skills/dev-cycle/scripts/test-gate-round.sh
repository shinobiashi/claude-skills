#!/usr/bin/env bash
# Scenario tests for gate-round.sh using a fake gh and a fake gate-threads.sh
# (no network, no real PR). Usage: bash test-gate-round.sh [path/to/gate-round.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/gate-round.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { # name, condition-as-exit-status
	if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

# ---- fixtures: bare remote + clone on a feature branch
git init -q --bare "$W/remote.git"
git clone -q "$W/remote.git" "$W/repo" 2>/dev/null
cd "$W/repo"
git config user.email t@example.com
git config user.name tester
git checkout -q -b main
echo a > a.txt && git add a.txt && git commit -q -m init && git push -q -u origin main 2>/dev/null
git checkout -q -b feat/x
echo b > b.txt && git add b.txt && git commit -q -m "feat: b"
HEAD_SHA="$(git rev-parse HEAD)"

# ---- fakes
mkdir -p "$W/bin"
LOG="$W/calls.log"
cat > "$W/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pr view" ]; then echo "${FAKE_PR_HEAD:-}"; exit 0; fi
if [ "$1 $2" = "pr comment" ]; then
  echo "gh $*" >> "$FAKE_LOG"
  [ -z "${FAKE_FAIL_COMMENT:-}" ] || exit 1
  exit 0
fi
echo "unexpected gh call: $*" >&2; exit 99
EOF
cat > "$W/bin/gate-threads.sh" <<'EOF'
#!/usr/bin/env bash
echo "gate-threads $*" >> "$FAKE_LOG"
if [ "$1" = "done" ] || [ "$1" = "reply" ]; then
  [ "$3" != "${FAKE_FAIL_ID:-none}" ] || exit 1
fi
exit 0
EOF
chmod +x "$W/bin/gh" "$W/bin/gate-threads.sh"
export PATH="$W/bin:$PATH" FAKE_LOG="$LOG" GATE_THREADS="$W/bin/gate-threads.sh"

printf 'reply one\n' > "$W/r1.md"
printf 'reply two\n' > "$W/r2.md"
printf 'summary\n' > "$W/sum.md"
: > "$W/empty.md"

run() { : > "$LOG"; OUT="$("$SCRIPT" "$@" 2>&1)"; RC=$?; }
calls() { cat "$LOG" 2>/dev/null; }

echo "== push"
run push --dry-run
[ -z "$(git ls-remote --heads origin feat/x)" ]; check "push --dry-run does not push (remote has no feat/x)" $?
echo "$OUT" | grep -q '^T=20' ; check "push --dry-run still prints T" $?

run push
[ "$RC" -eq 0 ]; check "push succeeds" $?
echo "$OUT" | grep -q "^HEAD=${HEAD_SHA:0:7}"; check "push prints HEAD" $?
echo "$OUT" | grep -Eq '^T=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; check "push prints T in ISO 8601 UTC" $?
[ "$(git ls-remote --heads origin feat/x | cut -c1-40)" = "$HEAD_SHA" ]; check "remote now has the pushed HEAD" $?

echo dirty > dirty.txt
run push
echo "$OUT" | grep -q "uncommitted changes are not part of this push"; check "push warns about uncommitted changes" $?
rm -f dirty.txt

git checkout -q main
run push
[ "$RC" -ne 0 ]; check "push refuses main" $?
echo "$OUT" | grep -q "refusing to push the default branch"; check "push explains the refusal" $?
git checkout -q feat/x

run push nonexistent-branch
[ "$RC" -ne 0 ]; check "push of a missing branch fails" $?
echo "$OUT" | grep -q '^T=' && bad "failed push must not print T" || ok "failed push prints no T"

echo "== publish: validation (nothing may be posted)"
export FAKE_PR_HEAD="$HEAD_SHA"
run publish abc --summary "$W/sum.md"
[ "$RC" -ne 0 ] && [ -z "$(calls)" ]; check "non-numeric PR rejected" $?

run publish 3
[ "$RC" -ne 0 ] && echo "$OUT" | grep -q "summary is required"; check "missing --summary rejected" $?

run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/nope.md"
[ "$RC" -ne 0 ] && [ -z "$(calls)" ]; check "missing reply file rejected before any post" $?

run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md" --hold "PRRT_b=$W/empty.md"
[ "$RC" -ne 0 ] && [ -z "$(calls)" ]; check "empty reply file rejected before any post (even for the 2nd entry)" $?

run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md" --hold "PRRT_a=$W/r2.md"
[ "$RC" -ne 0 ] && [ -z "$(calls)" ]; check "duplicate thread id rejected" $?

run publish 3 --summary "$W/sum.md" --done "no-equals-sign"
[ "$RC" -ne 0 ] && [ -z "$(calls)" ]; check "malformed --done rejected" $?

run publish 3 --summary "$W/sum.md" --done "PRRT_a;rm -rf=$W/r1.md"
[ "$RC" -ne 0 ] && [ -z "$(calls)" ]; check "thread id with shell metacharacters rejected" $?

run publish 3 --summary "$W/sum.md" --bogus
[ "$RC" -ne 0 ]; check "unknown option rejected" $?

FAKE_PR_HEAD="0000000000000000000000000000000000000000" run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md"
[ "$RC" -ne 0 ] && [ -z "$(calls)" ] && echo "$OUT" | grep -q "push first"; check "unpushed HEAD rejected (nothing posted)" $?

FAKE_PR_HEAD="0000000000000000000000000000000000000000" run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md" --allow-unpushed
[ "$RC" -eq 0 ]; check "--allow-unpushed overrides the pushed-HEAD check" $?

echo "== publish: order and content"
run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md" --hold "PRRT_b=$W/r2.md" --since 2026-09-20T00:00:00Z
[ "$RC" -eq 0 ]; check "publish succeeds" $?
EXPECT="gate-threads done 3 PRRT_a $W/r1.md
gate-threads reply 3 PRRT_b $W/r2.md
gh pr comment 3 --body-file $W/sum.md
gate-threads status 3 2026-09-20T00:00:00Z"
[ "$(calls)" = "$EXPECT" ]; check "order: done -> reply(hold) -> summary comment -> status" $?
[ "$(calls)" = "$EXPECT" ] || { echo "--- got:"; calls; echo "--- expected:"; echo "$EXPECT"; }

run publish 3 --summary "$W/sum.md"
[ "$RC" -eq 0 ] && [ "$(calls)" = "gh pr comment 3 --body-file $W/sum.md" ]; check "summary-only round posts just the comment (no gate-threads call)" $?

echo "== publish: failure midway"
FAKE_FAIL_ID=PRRT_b run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md" --done "PRRT_b=$W/r2.md"
[ "$RC" -ne 0 ]; check "failure at the 2nd thread exits non-zero" $?
echo "$OUT" | grep -q "stopped at done PRRT_b" ; check "names the entry it stopped at" $?
echo "$OUT" | grep -q "already posted: done:PRRT_a"; check "names what was already posted" $?
calls | grep -q "gh pr comment" && bad "summary must not be posted after a failure" || ok "summary not posted after a failure"

FAKE_FAIL_COMMENT=1 run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md"
[ "$RC" -ne 0 ]; check "summary comment failure exits non-zero" $?
echo "$OUT" | grep -q "post the summary by hand"; check "tells how to post the summary by hand" $?

echo "== dry-run"
run publish 3 --summary "$W/sum.md" --done "PRRT_a=$W/r1.md" --since 2026-09-20T00:00:00Z --dry-run
[ "$RC" -eq 0 ] && [ -z "$(calls)" ]; check "dry-run posts nothing" $?
echo "$OUT" | grep -q "^+ .*done 3 PRRT_a" && echo "$OUT" | grep -q "^+ gh pr comment 3"; check "dry-run prints the planned commands" $?

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
