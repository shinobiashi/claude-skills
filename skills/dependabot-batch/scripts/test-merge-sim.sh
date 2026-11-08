#!/usr/bin/env bash
# Scenario tests for merge-sim.sh on throwaway git repositories (no network).
# Usage: bash test-merge-sim.sh [path/to/merge-sim.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/merge-sim.sh}"
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

human() { git -c user.name=Maintainer -c user.email=m@example.invalid "$@"; }
bot() { git -c "user.name=dependabot[bot]" -c user.email=b@example.invalid "$@"; }

REPO="$W/repo"
git init --quiet --initial-branch=main "$REPO"
cd "$REPO" || exit 2
printf '{\n  "a": "1",\n  "b": "1",\n  "c": "1",\n  "d": "1"\n}\n' >package.json
printf 'lock a1\nlock-spacer\nlock-spacer\nlock-spacer\nlock b1\n' >package-lock.json
mkdir -p .github
printf 'uses: actions/checkout@v4\n' >.github/ci.yml
printf 'docs\n' >README.md
human add -A
human commit --quiet -m base

branch() { # branch NAME FROM
    git checkout --quiet -b "$1" "$2"
}
edit() { # edit FILE SED_EXPR
    sed -i.bak "$2" "$1" && rm -f "$1.bak"
}

# bot-a and bot-b change the same line of package.json: only one can land without a rebase.
branch bot-a main
edit package.json 's/"a": "1"/"a": "2"/'
bot add -A
bot commit --quiet -m 'bump a'

branch bot-b main
edit package.json 's/"a": "1"/"a": "3"/'
bot add -A
bot commit --quiet -m 'bump a again'

# bot-c does not touch what the others touch.
branch bot-c main
edit .github/ci.yml 's/@v4/@v5/'
bot add -A
bot commit --quiet -m 'bump checkout'

# human-d starts as Dependabot's and gets commits by a person. It conflicts with bot-a too.
# Several commits above the base: the kind check has to survive grep -q closing the pipe early.
branch human-d main
edit package.json 's/"a": "1"/"a": "4"/'
bot add -A
bot commit --quiet -m 'bump a further'
for n in 1 2 3 4 5 6; do
    printf 'fix %s\n' "$n" >>README.md
    human add -A
    human commit --quiet -m "fix $n"
done

# human-e is stacked on human-d.
branch human-e human-d
printf 'more\n' >>README.md
human add -A
human commit --quiet -m 'more on top'

git checkout --quiet main
HEAD_MAIN="$(git rev-parse HEAD)"
BRANCHES_BEFORE="$(git for-each-ref | sort)"

echo "merge-sim.sh"

echo "== one order"
run --base main --no-fetch a=bot-a c=bot-c
status "clean merges exit 0" 0
has "first PR is clean" "1. a        bot    clean"
has "second PR is clean" "2. c        bot    clean"
has "summary counts them" "summary: clean=2 already-in=0 dependabot-rebase=0 manual=0"
has "prints a tip" "tip "

run --base main --no-fetch a=bot-a b=bot-b
status "a conflict exits 1" 1
has "conflict names the file" "2. b        bot    conflict: package.json"
has "a bot PR is left to Dependabot" "Dependabot rebases it; wait for its CI"
has "summary counts the rebase" "dependabot-rebase=1 manual=0"
has "says a conflicted PR is not in the tip" "a PR that conflicted is not in the tip"

run --base main --no-fetch a=bot-a d=human-d
status "a conflict on an edited PR exits 1" 1
has "many commits above the base still read as edited" "2. d        edited conflict: package.json"
has "an edited PR needs a person" "MANUAL: Dependabot will not rebase this PR"
has "summary counts the manual one" "dependabot-rebase=0 manual=1"

echo "== the simulation goes on after a conflict"
run --base main --no-fetch a=bot-a b=bot-b c=bot-c
has "the PR after a conflict still merges" "3. c        bot    clean"
has "only the clean ones count" "clean=2"

echo "== stacks"
run --base main --no-fetch d=human-d e=human-e
status "a stack in order merges" 0
has "the top of the stack merges" "2. e        edited clean"

run --base main --no-fetch e=human-e d=human-d
status "a stack the wrong way round is not a conflict" 0
has "the lower PR is already in" "2. d        edited already in the tip"
has "and is counted so" "already-in=1"

if [ "$(git for-each-ref | sort)" = "$BRANCHES_BEFORE" ]; then
    ok "the runs so far add or move no refs"
else
    bad "the runs so far add or move no refs"
fi

echo "== squash"
git checkout --quiet -b stack-low main
printf 'one\n' >stack.txt
human add -A
human commit --quiet -m one
git checkout --quiet -b stack-high stack-low
printf 'two\n' >stack.txt
human add -A
human commit --quiet -m two
git checkout --quiet main
BRANCHES_BEFORE="$(git for-each-ref | sort)"  # the two stack branches are the test's own
run --base main --no-fetch low=stack-low high=stack-high
status "a stack merges cleanly with merge commits" 0
hasnt "merge commits keep the history: no conflict" "conflict"
run --base main --no-fetch --method squash low=stack-low high=stack-high
status "the same stack conflicts once the lower PR is squashed" 1
has "the upper PR conflicts" "2. high     edited conflict: stack.txt"

echo "== plan"
run --plan --base main --no-fetch 1=bot-a 2=bot-b 3=bot-c 4=human-d
status "the plan's status is the recommended order's: bot conflicts remain" 1
has "lists the pairs" "1 x 2  package.json"
has "lists a pair with the edited PR" "1 x 4  package.json"
has "recommended order is announced" "order: recommended"
has "the numeric order is announced" "order: ascending numbers"

# The first PR of the recommended order is the edited one; the numeric order hits MANUAL.
REC="$(printf '%s\n' "$OUT" | sed -n '/order: recommended/,/^tip /p')"
NUM="$(printf '%s\n' "$OUT" | sed -n '/order: ascending numbers/,/^tip /p')"
case "$REC" in
    *"1. 4 "*"edited clean"*) ok "the edited PR goes first in the recommended order" ;;
    *) bad "the edited PR goes first in the recommended order"; printf '%s\n' "$REC" ;;
esac
case "$REC" in
    *"manual=0"*) ok "the recommended order leaves no manual work" ;;
    *) bad "the recommended order leaves no manual work" ;;
esac
case "$NUM" in
    *"MANUAL"*"manual=1"*) ok "the numeric order shows the manual work it costs" ;;
    *) bad "the numeric order shows the manual work it costs" ;;
esac

run --plan --base main --no-fetch 7=human-e 4=human-d
status "a stack alone is clean" 0
REC="$(printf '%s\n' "$OUT" | sed -n '/order: recommended/,/^tip /p')"
case "$REC" in
    *"1. 4 "*"2. 7 "*) ok "a stack sorts by depth, not by number" ;;
    *) bad "a stack sorts by depth, not by number"; printf '%s\n' "$REC" ;;
esac

# A PR that conflicts with the base itself is no pair's fault, whichever place it is given in.
run --plan --base bot-a --no-fetch b=bot-b c=bot-c
has "a PR that conflicts with the base is listed apart" "conflicting with the base by itself (left out of the pairs):"
has "with its files" "  b  package.json"
PAIRS="$(printf '%s\n' "$OUT" | sed -n '/^conflicting pairs/,/^$/p')"
case "$PAIRS" in
    *"  none"*) ok "and no pair is blamed for it" ;;
    *) bad "and no pair is blamed for it" ;;
esac
run --plan --base bot-a --no-fetch c=bot-c b=bot-b
hasnt "nor when it comes last" "c x b"

run --plan --base main --no-fetch 1=bot-a 3=bot-c
has "no conflicts reads as none" "  none"
status "no conflicts exits 0" 0
has "one order is not printed twice" "order: ascending numbers is this same order"
TIPS="$(printf '%s\n' "$OUT" | grep -c '^tip ')"
if [ "$TIPS" -eq 1 ]; then ok "and there is one tip"; else bad "and there is one tip ($TIPS)"; fi

if [ "$(git for-each-ref | sort)" = "$BRANCHES_BEFORE" ]; then
    ok "the squash and plan runs add or move no refs"
else
    bad "the squash and plan runs add or move no refs"
fi

echo "== PR numbers"
BARE="$W/origin.git"
git clone --quiet --bare "$REPO" "$BARE"
git -C "$BARE" update-ref refs/pull/7/head bot-a
git -C "$BARE" update-ref refs/pull/8/head bot-c
git remote add origin "$BARE"
git fetch --quiet origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
REFS_FETCHED="$(git for-each-ref | sort)"
run 7 8
status "PR numbers come from refs/pull/N/head" 0
has "a number gets a # label" "1. #7       bot    clean"
has "the default base is origin's default branch" "base origin/main"
run 99
status "an unknown PR is an error" 2
has "says which" "cannot fetch PR 99"

echo "== the repository is left alone"
if [ "$(git rev-parse HEAD)" = "$HEAD_MAIN" ] && [ -z "$(git status --porcelain)" ]; then
    ok "HEAD and the working tree are as they were"
else
    bad "HEAD and the working tree are as they were"
fi
if [ "$(git for-each-ref | sort)" = "$REFS_FETCHED" ]; then
    ok "fetching PRs by number adds or moves no refs"
else
    bad "fetching PRs by number adds or moves no refs"
fi

TIP="$(bash "$SCRIPT" --base main --no-fetch a=bot-a c=bot-c | sed -n 's/^tip //p')"
if git cat-file -e "$TIP^{commit}" 2>/dev/null; then ok "the tip is a real commit"; else bad "the tip is a real commit"; fi
git worktree add --quiet --detach "$W/tip" "$TIP"
if grep -q '"a": "2"' "$W/tip/package.json" && grep -q 'checkout@v5' "$W/tip/.github/ci.yml"; then
    ok "the tip's tree holds both PRs"
else
    bad "the tip's tree holds both PRs"
fi
git worktree remove --force "$W/tip"

echo "== usage"
run
status "no PR is a usage error" 2
run --method rebase 1=main
status "an unknown method is an error" 2
has "names it" "--method is merge or squash"
run --base no-such-ref --no-fetch a=bot-a
status "an unknown base is an error" 2
run --base main --no-fetch nope
status "a spec that is neither a number nor LABEL=REV is an error" 2
run --base main --no-fetch a=no-such-rev
status "an unknown revision is an error" 2
run --base main --no-fetch "my fix=bot-a"
status "a label with a space is an error, not a shifted field" 2
has "says what a label can be" "a label is letters, digits"
run --base main --no-fetch "=bot-a"
status "an empty label is an error" 2

# git refuses unrelated histories (exit 128): that is an error, never a conflicting pair.
git checkout --quiet --orphan unrelated
human commit --quiet --allow-empty -m unrelated
git checkout --quiet main
run --plan --base main --no-fetch a=bot-a u=unrelated
status "a git error in the plan exits 2" 2
hasnt "and is not read as a conflict" "a x u"
run --help
status "--help exits 0" 0
has "--help shows the usage" "merge-sim.sh --plan"

(
    cd "$W" || exit 2
    mkdir not-git
    cd not-git || exit 2
    run --base main a=b
    status "outside a repository is an error" 2
)

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
