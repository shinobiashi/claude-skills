#!/usr/bin/env bash
# Scenario tests for run-steps.sh in a throwaway directory (no network).
# Usage: bash test-run-steps.sh [path/to/run-steps.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/run-steps.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; printf '%s\n' "${OUT:-}" | sed 's/^/         | /'; }
run() { OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; fi; }
hasnt() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then bad "$1 (unexpected line: $2)"; else ok "$1"; fi; }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; fi; }

mkdir -p "$W/tree"

echo "run-steps.sh"

echo "== every step runs"
run --dir "$W/tree" --log-dir "$W/l1" -- 'echo one >a.txt' 'exit 3' 'echo three >c.txt'
status "a failed step fails the run" 1
has "the first step passed" "PASS  1/1"
has "the failure is reported with the command" "FAIL  0/1"
has "the failed command is named" "exit 3"
has "its exit code is on the log line" "(exit 3)"
has "the total counts it" "steps=3 failed=1"
if [ -f "$W/tree/c.txt" ]; then ok "the step after a failure still ran"; else bad "the step after a failure still ran"; fi

echo "== commands run from --dir"
run --dir "$W/tree" --log-dir "$W/l2" -- 'test -f a.txt'
status "the command sees the tree" 0

echo "== logs"
run --dir "$W/tree" --log-dir "$W/l3" -- 'echo to-stdout; echo to-stderr >&2; exit 1'
LOG="$(ls "$W"/l3/*.log)"
if grep -q to-stdout "$LOG" && grep -q to-stderr "$LOG"; then ok "the log holds both streams"; else bad "the log holds both streams"; fi
has "the log path is printed" "log: $W/l3/"

echo "== versions"
PATH_STUB="$W/stub"
mkdir -p "$PATH_STUB"
printf '#!/bin/sh\necho v24.1.0\n' >"$PATH_STUB/node"
printf '#!/bin/sh\necho 8.5.1\n' >"$PATH_STUB/php"
chmod +x "$PATH_STUB/node" "$PATH_STUB/php"
printf '24\n' >"$W/tree/.nvmrc"
OUT="$(PATH="$PATH_STUB:$PATH" NVM_DIR="$W/no-nvm" bash "$SCRIPT" --dir "$W/tree" --log-dir "$W/l4" -- 'true' 2>&1)"
has "prints the Node version" "node: v24.1.0"
has "prints what .nvmrc asks for" ".nvmrc: 24"
has "prints the PHP version" "php: 8.5.1"
rm "$W/tree/.nvmrc"

echo "== nvm"
mkdir -p "$W/nvm"
cat >"$W/nvm/nvm.sh" <<'EOF'
nvm() { if [ "$1" = use ]; then export PATH="$FAKE_NODE_DIR:$PATH"; return "${FAKE_NVM_RC:-0}"; fi; }
EOF
mkdir -p "$W/node24"
printf '#!/bin/sh\necho v24.99.0\n' >"$W/node24/node"
chmod +x "$W/node24/node"
printf '24\n' >"$W/tree/.nvmrc"
OUT="$(FAKE_NODE_DIR="$W/node24" NVM_DIR="$W/nvm" bash "$SCRIPT" --dir "$W/tree" --log-dir "$W/l5" -- 'node -v >node.txt' 2>&1)"
has "the Node from .nvmrc is the one reported" "node: v24.99.0"
if grep -q 'v24.99.0' "$W/tree/node.txt"; then ok "the steps run on that Node"; else bad "the steps run on that Node"; fi
OUT="$(FAKE_NODE_DIR="$W/node24" FAKE_NVM_RC=3 NVM_DIR="$W/nvm" bash "$SCRIPT" --dir "$W/tree" --log-dir "$W/l6" -- 'true' 2>&1)"
has "a missing Node is a warning" "warning: nvm has no Node for .nvmrc"
rm "$W/tree/.nvmrc"

echo "== repeat"
rm -f "$W/tree/count"
# shellcheck disable=SC2016  # the step is expanded by run-steps.sh, not here
run --dir "$W/tree" --log-dir "$W/l7" --repeat 4 -- 'n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo $n >count; [ $((n % 2)) -eq 0 ]'
status "a sometimes-failing step fails the run" 1
has "and reads as flaky, with the tally" "FLAKY 2/4"
has "the last failing log is named" "log: "

run --dir "$W/tree" --log-dir "$W/l8" --repeat 3 -- 'true'
status "a steady step passes" 0
has "the tally is complete" "PASS  3/3"

run --dir "$W/tree" --log-dir "$W/l9" --repeat 3 -- 'false'
has "a step that never passes is a failure, not flaky" "FAIL  0/3"

echo "== load"
# A leftover `yes` would keep burning CPU after the script has gone, so the stub records its pid.
mkdir -p "$W/yes"
cat >"$W/yes/yes" <<'EOF'
#!/bin/sh
echo $$ >>"$YES_PIDS"
exec sleep 60
EOF
chmod +x "$W/yes/yes"
export YES_PIDS="$W/yes-pids"
OUT="$(PATH="$W/yes:$PATH" bash "$SCRIPT" --dir "$W/tree" --log-dir "$W/l10" --load -- 'sleep 1' 2>&1)"
RC=$?
status "the load does not change the result" 0
has "says the load ran" "busy loops"
if [ -s "$YES_PIDS" ]; then ok "the load really started"; else bad "the load really started"; fi
alive=0
while read -r pid; do
    kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
done <"$YES_PIDS"
if [ "$alive" -eq 0 ]; then ok "the load stops with the script"; else bad "the load stops with the script ($alive left)"; fi

echo "== usage"
run
status "no command is a usage error" 2
run --dir "$W/none" -- 'true'
status "a missing directory is an error" 2
has "names it" "no such directory"
run --repeat 0 -- 'true'
status "--repeat 0 is an error" 2
run --repeat x -- 'true'
status "--repeat x is an error" 2
run 'true'
status "a command before -- is an error" 2
has "says where commands go" "commands go after --"
run --help
status "--help exits 0" 0
has "--help shows the usage" "run-steps.sh [--dir DIR]"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
