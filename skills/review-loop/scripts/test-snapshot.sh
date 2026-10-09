#!/usr/bin/env bash
# Scenario tests for snapshot.sh using a throwaway git repo (no network).
# Usage: bash test-snapshot.sh [path/to/snapshot.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/snapshot.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi }
snap() { bash "$SCRIPT" "$@"; }

git init -q -b main "$W/repo"
cd "$W/repo" || exit 2
git config user.email t@example.com
git config user.name tester
printf 'ignored.log\n' > .gitignore
printf 'one\n' > a.txt
git add . && git commit -q -m init
git switch -q -c feature/review

echo "snapshot.sh"

# 1. A clean working tree is recorded as HEAD itself.
head=$(git rev-parse HEAD)
sha=$(snap save R0)
check "clean tree: save prints HEAD" "$([ "$sha" = "$head" ]; echo $?)"
check "clean tree: ref refs/review-loop/feature/review/R0 points at HEAD" \
	"$([ "$(git rev-parse refs/review-loop/feature/review/R0)" = "$head" ]; echo $?)"

# 2. R1 on uncommitted work: a modified file, a staged file, a new untracked
#    file and an ignored file.
printf 'one\ntwo\n' > a.txt
printf 'staged\n' > b.txt
git add b.txt
mkdir -p tools && printf 'new\n' > tools/new.sh
printf 'noise\n' > ignored.log
status_before=$(git status --porcelain --untracked-files=all)
staged_before=$(git diff --cached)
r1=$(snap save R1)
check "R1: HEAD unchanged" "$([ "$(git rev-parse HEAD)" = "$head" ]; echo $?)"
check "R1: branch unchanged" "$([ "$(git branch --show-current)" = feature/review ]; echo $?)"
check "R1: git status unchanged" "$([ "$(git status --porcelain --untracked-files=all)" = "$status_before" ]; echo $?)"
check "R1: staged changes unchanged" "$([ "$(git diff --cached)" = "$staged_before" ]; echo $?)"
check "R1: snapshot holds the modified file" "$([ "$(git show "$r1:a.txt")" = "$(printf 'one\ntwo')" ]; echo $?)"
check "R1: snapshot holds the untracked file" "$(git cat-file -e "$r1:tools/new.sh" 2>/dev/null; echo $?)"
check "R1: snapshot holds the staged file" "$(git cat-file -e "$r1:b.txt" 2>/dev/null; echo $?)"
check "R1: snapshot leaves out ignored files" "$(! git cat-file -e "$r1:ignored.log" 2>/dev/null; echo $?)"
check "R1: snapshot's parent is HEAD" "$([ "$(git rev-parse "$r1^")" = "$head" ]; echo $?)"

# 3. R1 fixes, still uncommitted: diff R1 shows only the fixes, including the
#    change to the untracked file.
printf 'one\ntwo\nthree\n' > a.txt
printf 'new\nfixed\n' > tools/new.sh
out=$(snap diff R1 --name-only)
check "diff R1 (to working tree): only the fixed files" "$([ "$out" = "$(printf 'a.txt\ntools/new.sh')" ]; echo $?)"
check "diff R1: the fix line is there" "$(snap diff R1 | grep -q '^+three$'; echo $?)"
check "diff R1: R1's own change is not repeated" "$(! snap diff R1 | grep -q '^+two$'; echo $?)"

# 4. Committing everything between rounds does not change the fix diff.
git add -A && git commit -q -m "R1 target and fixes"
out=$(snap diff R1 --name-only)
check "diff R1 after commit: still only the fixed files" "$([ "$out" = "$(printf 'a.txt\ntools/new.sh')" ]; echo $?)"

# 5. diff between two saved rounds.
r2=$(snap save R2)
check "R2 on a clean tree is the new HEAD" "$([ "$r2" = "$(git rev-parse HEAD)" ]; echo $?)"
out=$(snap diff R1 R2 --stat | tail -1)
check "diff R1 R2 --stat: 2 files changed" "$(echo "$out" | grep -q '2 files changed'; echo $?)"
check "diff R2 (no change since): empty" "$([ -z "$(snap diff R2)" ]; echo $?)"
check "diff accepts a commit-ish" "$([ "$(snap diff "$r1" R2 --name-only)" = "$(snap diff R1 R2 --name-only)" ]; echo $?)"

# 6. list and clean.
out=$(snap list | awk '{print $1}' | tr '\n' ' ')
check "list shows R0 R1 R2" "$([ "$out" = "R0 R1 R2 " ]; echo $?)"
printf 'x\n' > a.txt
snap save R2 2>"$W/err" >/dev/null
check "save over an existing round warns" "$(grep -q 'replaced R2' "$W/err"; echo $?)"
git checkout -q -- a.txt
out=$(snap clean)
check "clean reports the deleted refs" "$([ "$(echo "$out" | wc -l | tr -d ' ')" = 3 ]; echo $?)"
check "clean leaves no refs" "$([ -z "$(git for-each-ref refs/review-loop/)" ]; echo $?)"
check "clean on a branch without snapshots is a no-op" "$(snap clean >/dev/null; echo $?)"

# 7. Other branches' snapshots are left alone.
snap save R1 >/dev/null
git switch -q -c other
snap save R1 >/dev/null
snap clean >/dev/null
check "clean only touches the current branch" "$(git rev-parse -q --verify refs/review-loop/feature/review/R1 >/dev/null; echo $?)"
git switch -q feature/review

# 8. Errors.
snap diff R9 >/dev/null 2>&1; rc=$?; check "unknown round: exit 2" "$([ $rc -eq 2 ]; echo $?)"
snap save '../x' >/dev/null 2>&1; rc=$?; check "invalid round name: exit 2" "$([ $rc -eq 2 ]; echo $?)"
snap save >/dev/null 2>&1; rc=$?; check "save without a round: exit 2" "$([ $rc -eq 2 ]; echo $?)"
snap bogus >/dev/null 2>&1; rc=$?; check "unknown command: exit 2" "$([ $rc -eq 2 ]; echo $?)"
git switch -q --detach
snap save R1 >/dev/null 2>&1; rc=$?; check "detached HEAD: exit 2" "$([ $rc -eq 2 ]; echo $?)"
git switch -q feature/review
(cd "$W" && bash "$SCRIPT" list >/dev/null 2>&1); rc=$?; check "outside a repository: exit 2" "$([ $rc -eq 2 ]; echo $?)"

# 9. Runs from a subdirectory and still snapshots the whole tree.
printf 'sub\n' > a.txt
sub=$(cd tools && bash "$SCRIPT" save R3)
check "save from a subdirectory includes files above it" "$([ "$(git show "$sub:a.txt")" = sub ]; echo $?)"
git checkout -q -- a.txt

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
