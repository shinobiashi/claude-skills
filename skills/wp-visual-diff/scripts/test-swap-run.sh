#!/usr/bin/env bash
# Scenario tests for swap-run.sh in a throwaway git repository (no network).
# Usage: bash test-swap-run.sh [path/to/swap-run.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/swap-run.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', expected '$3')"; fi }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }
run() { OUT="$(cd "$R" && bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
content() { if [ -e "$R/$1" ]; then cat "$R/$1"; else echo "<absent>"; fi; }

# Repository: main has a.php v1, d.php, bin.sh (executable), other/x.txt v1; the feature branch
# changes a.php to v2, adds b.php, deletes d.php and changes other/x.txt to v2.
R="$W/repo"
mkdir -p "$R/theme" "$R/other"
cd "$R" || exit 1
git init -q -b main
git config user.email t@example.com
git config user.name t
echo v1 >theme/a.php
echo keep-d >theme/d.php
printf '#!/bin/sh\necho v1\n' >theme/bin.sh
chmod +x theme/bin.sh
echo v1 >other/x.txt
git add -A && git commit -qm base
git switch -qc feature
echo v2 >theme/a.php
echo new-b >theme/b.php
git rm -q theme/d.php
printf '#!/bin/sh\necho v2\n' >theme/bin.sh
echo v2 >other/x.txt
git add -A && git commit -qm change
cd - >/dev/null || exit 1

# Records what the command sees while the files are swapped.
SEE="cat theme/a.php; [ -e theme/b.php ] && echo b-present || echo b-absent; cat theme/d.php 2>/dev/null || echo d-absent; cat other/x.txt"

echo "swap-run.sh"

run --ref main -- sh -c "{ $SEE; } >$W/seen"
status "a clean swap exits with the command's status" 0
eq "the command sees the ref's versions (modified, added, deleted)" "$(tr '\n' ' ' <"$W/seen")" "v1 b-absent keep-d v1 "
eq "a.php is restored" "$(content theme/a.php)" "v2"
eq "b.php is back" "$(content theme/b.php)" "new-b"
eq "d.php is removed again" "$(content theme/d.php)" "<absent>"
eq "the working tree is clean afterwards" "$(cd "$R" && git status --porcelain)" ""
if [ -x "$R/theme/bin.sh" ]; then ok "the executable bit survives"; else bad "the executable bit survives"; fi

run --ref main --path theme -- sh -c "cat other/x.txt >$W/seen-x"
eq "--path limits the swap (other/x.txt keeps v2)" "$(cat "$W/seen-x")" "v2"

run --ref main -- sh -c 'exit 7'
status "a failing command's status is passed through" 7
eq "files are restored after a failure" "$(content theme/a.php)" "v2"

# signal_run SIGNAL EXPECTED_EXIT: start a long command, send SIGNAL once the swap is in place.
# Job control (set -m) keeps SIGINT from being ignored by the background job, as it is in a
# terminal where Ctrl-C reaches the foreground process.
signal_run() {
	rm -f "$W/child.pid"
	set -m
	# shellcheck disable=SC2016 # $$ is the inner sh, which then becomes the long command
	bash "$SCRIPT" --repo "$R" --ref main -- sh -c 'echo $$ >"$0"; exec sleep 30' "$W/child.pid" >"$W/sig.log" 2>&1 &
	local pid=$!
	set +m
	# Wait until the command itself is running (the swap happens before it starts).
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -s "$W/child.pid" ] && break; sleep 0.3; done
	kill -"$1" "$pid"
	wait "$pid"
	RC=$?
	OUT="$(cat "$W/sig.log")"
	status "$1 exits $2" "$2"
	eq "files are restored after $1" "$(content theme/a.php)" "v2"
	eq "the working tree is clean after $1" "$(cd "$R" && git status --porcelain)" ""
	sleep 0.3
	if [ ! -s "$W/child.pid" ]; then
		bad "the running command is stopped on $1 (the command never started)"
	elif kill -0 "$(cat "$W/child.pid")" 2>/dev/null; then
		bad "the running command is stopped on $1"
		kill "$(cat "$W/child.pid")" 2>/dev/null
	else
		ok "the running command is stopped on $1"
	fi
}
signal_run INT 130
signal_run TERM 143

echo dirty-edit >"$R/theme/a.php"
run --ref main -- true
status "uncommitted changes are refused" 2
eq "the uncommitted edit is untouched" "$(content theme/a.php)" "dirty-edit"
run --ref main --allow-dirty -- sh -c "cat theme/a.php >$W/seen-dirty"
status "--allow-dirty runs" 0
eq "the command sees the ref's version" "$(cat "$W/seen-dirty")" "v1"
eq "the uncommitted edit is restored exactly" "$(content theme/a.php)" "dirty-edit"
(cd "$R" && git checkout -q -- theme/a.php)

echo scratch >"$R/theme/new-untracked.php"
run --ref main -- true
status "an untracked file under the path is refused" 2
run --ref main --allow-dirty -- sh -c "[ -e theme/new-untracked.php ] && echo present >$W/seen-u || echo absent >$W/seen-u"
eq "the untracked file is moved aside while the command runs" "$(cat "$W/seen-u")" "absent"
eq "the untracked file comes back" "$(content theme/new-untracked.php)" "scratch"
rm -f "$R/theme/new-untracked.php"

# shellcheck disable=SC2016 # expanded by the inner sh, where SWAP_RUN_BACKUP is set
run --ref main -- sh -c 'printf corrupted >"$SWAP_RUN_BACKUP/files/theme/a.php"'
status "a backup that no longer matches makes the run fail with 3" 3
case "$OUT" in *"RESTORE FAILED"*) ok "says the restore failed and keeps the backup" ;; *) bad "says the restore failed and keeps the backup"; printf '%s\n' "$OUT" | sed 's/^/         | /' ;; esac
(cd "$R" && git checkout -q -- theme/a.php)

# A file that cannot be swapped: restore and do not run the command. A git that writes part of
# the file and then fails on `show` stands in for a full disk.
mkdir -p "$W/shim"
# shellcheck disable=SC2016 # $1 and $@ belong to the shim
printf '#!/bin/sh\nif [ "$1" = show ]; then echo partial; exit 1; fi\nexec "%s" "$@"\n' "$(command -v git)" >"$W/shim/git"
chmod +x "$W/shim/git"
rm -f "$W/ran"
OUT="$(cd "$R" && PATH="$W/shim:$PATH" bash "$SCRIPT" --ref main -- sh -c "touch $W/ran" 2>&1)"
RC=$?
status "a file that cannot be swapped: exit 2" 2
if [ -e "$W/ran" ]; then bad "the command is not run after a failed swap"; else ok "the command is not run after a failed swap"; fi
eq "a.php is restored after a failed swap" "$(content theme/a.php)" "v2"
eq "the working tree is clean after a failed swap" "$(cd "$R" && git status --porcelain)" ""

# Symbolic links would come back as regular files (cp -p and git show follow them): refused.
(cd "$R" && git switch -qc links feature && ln -s a.php theme/link.php && git add theme/link.php && git commit -qm link)
rm -f "$W/ran"
run --ref feature -- sh -c "touch $W/ran"
status "a symbolic link in the working tree is refused" 2
if [ -L "$R/theme/link.php" ]; then ok "the link is left as a link"; else bad "the link is left as a link"; fi
if [ -e "$W/ran" ]; then bad "the command is not run when a link is refused"; else ok "the command is not run when a link is refused"; fi
(cd "$R" && git checkout -q -- theme/link.php && git switch -q feature)
run --ref links -- true
status "a symbolic link at the ref is refused" 2
eq "the working tree is clean after the refusal" "$(cd "$R" && git status --porcelain)" ""

run --ref feature -- true
status "nothing differs from the ref: exit 2" 2
run --ref no-such-ref -- true
status "an unknown ref: exit 2" 2
run --ref main
status "no command: exit 2" 2

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
