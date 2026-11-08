#!/usr/bin/env bash
# merge-sim.sh — Simulate merging a batch of PRs, one after the other, with no working tree.
#
# Usage:
#   merge-sim.sh [options] PR...          simulate the order given
#   merge-sim.sh --plan [options] PR...   conflict pairs, then the recommended order, then the
#                                         ascending-number order when it is a different one
#
#   PR                a PR number (fetched from refs/pull/N/head), or LABEL=REV for any revision
#   --base REF        where the merges start (default: origin's default branch, freshly fetched)
#   --method M        merge (default) or squash. Squash matters for stacked PRs.
#   --no-fetch        do not fetch the base
#   -h, --help        this text
#
# Every merge is `git merge-tree` plus `git commit-tree`, so no branch, index or working tree
# changes; the commits made are dangling objects that git gc drops by itself. Fetching the
# default base moves origin's remote-tracking branch, as any fetch does (--no-fetch skips it).
# Each order ends with its tip. `git worktree add --detach DIR <tip>` makes that state real, so
# the CI steps can run on it.
#
# A clean text merge says nothing about the lock files: npm ci and composer validate on the tip do.
#
# Exit status: 0 no conflict; 1 a conflict; 2 a usage or git error.
# With --plan, the status is that of the recommended order.

set -uo pipefail

BASE=""
METHOD="merge"
PLAN=0
FETCH=1
SPECS=()

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "merge-sim: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --base) [ $# -ge 2 ] || die "--base needs a value"; BASE="$2"; shift 2 ;;
        --method) [ $# -ge 2 ] || die "--method needs a value"; METHOD="$2"; shift 2 ;;
        --plan) PLAN=1; shift ;;
        --no-fetch) FETCH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do SPECS+=("$1"); shift; done ;;
        -*) die "unknown option: $1" ;;
        *) SPECS+=("$1"); shift ;;
    esac
done

case "$METHOD" in merge|squash) ;; *) die "--method is merge or squash, not: $METHOD" ;; esac
[ "${#SPECS[@]}" -gt 0 ] || { usage >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

# merge-tree --write-tree arrived in git 2.38.
ver="$(git version | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/')"
read -r major minor _ <<<"$ver"
{ [ "${major:-0}" -gt 2 ] || { [ "${major:-0}" -eq 2 ] && [ "${minor:-0}" -ge 38 ]; }; } \
    || die "git 2.38 or later is needed (found $(git version))"

if [ -z "$BASE" ]; then
    branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    [ -n "$branch" ] || branch="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)"
    [ -n "$branch" ] || die "cannot tell the default branch; pass --base"
    if [ "$FETCH" -eq 1 ]; then
        git fetch --quiet origin "$branch" || die "cannot fetch origin $branch"
    fi
    BASE="origin/$branch"
fi
BASE_SHA="$(git rev-parse --verify --quiet "${BASE}^{commit}")" || die "no such base: $BASE"

export GIT_AUTHOR_NAME=merge-sim GIT_AUTHOR_EMAIL=merge-sim@example.invalid
export GIT_COMMITTER_NAME=merge-sim GIT_COMMITTER_EMAIL=merge-sim@example.invalid

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# Resolve every spec up front: W/<index> holds "label sha kind count".
N=${#SPECS[@]}
i=0
for spec in "${SPECS[@]}"; do
    case "$spec" in
        *=*) label="${spec%%=*}"
             # The label is a field in W/<index>, so a space or an empty label would shift the rest.
             case "$label" in
                 '' | *[!A-Za-z0-9._/#-]*) die "a label is letters, digits and . _ / # - only: $spec" ;;
             esac
             sha="$(git rev-parse --verify --quiet "${spec#*=}^{commit}")" || die "no such revision: ${spec#*=}" ;;
        *[!0-9]*) die "not a PR number or LABEL=REV: $spec" ;;
        *) label="#$spec"
           git fetch --quiet origin "refs/pull/$spec/head" 2>/dev/null || die "cannot fetch PR $spec"
           sha="$(git rev-parse --verify --quiet FETCH_HEAD)" || die "cannot resolve PR $spec" ;;
    esac
    # A commit by anyone but Dependabot stops its automatic rebase, and such a PR needs a person.
    # The authors go through a variable: grep -q in a pipe kills git log, which pipefail reports.
    authors="$(git log --format='%an' "$BASE_SHA..$sha")"
    if [ -n "$authors" ] && grep -qv '^dependabot\[bot\]$' <<<"$authors"; then kind=edited; else kind=bot; fi
    count="$(git rev-list --count "$BASE_SHA..$sha")"
    printf '%s %s %s %s\n' "$label" "$sha" "$kind" "$count" >"$W/$i"
    i=$((i + 1))
done

field() { # field INDEX N
    awk -v n="$2" '{ print $n }' "$W/$1"
}

# step TIP SHA: sets STEP_TREE and STEP_FILES; returns 0 clean, 1 conflict, 2 error.
step() {
    local out rc
    out="$(git merge-tree --write-tree --name-only --no-messages "$1" "$2" 2>"$W/err")"
    rc=$?
    STEP_TREE="$(printf '%s\n' "$out" | sed -n 1p)"
    STEP_FILES="$(printf '%s\n' "$out" | sed -n '2,$p' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    # merge-tree exits 1 for "not something we can merge" too; only a conflict prints a tree.
    if [ "$rc" -le 1 ] && ! [[ "$STEP_TREE" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
        rc=2
    fi
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) sed 's/^/merge-sim: /' "$W/err" >&2; return 2 ;;
    esac
}

commit() { # commit TREE TIP SHA
    if [ "$METHOD" = squash ]; then
        git commit-tree "$1" -p "$2" -m sim
    else
        git commit-tree "$1" -p "$2" -p "$3" -m sim
    fi
}

# Conflicts between two PRs: one merged on the base, then the other. One direction is enough, as
# a three-way conflict does not depend on which side comes first. A PR that conflicts with the
# base by itself is listed apart and left out of the pairs: every pair with it would conflict.
pairs() {
    local a b rc tip found=0 alone=" "
    a=0
    while [ "$a" -lt "$N" ]; do
        step "$BASE_SHA" "$(field "$a" 2)"
        rc=$?
        [ "$rc" -le 1 ] || exit 2
        if [ "$rc" -eq 1 ]; then
            [ "$alone" != " " ] || echo "conflicting with the base by itself (left out of the pairs):"
            printf '  %s  %s\n' "$(field "$a" 1)" "$STEP_FILES"
            alone="$alone$a "
        fi
        a=$((a + 1))
    done
    echo "conflicting pairs (one merged on the base, then the other):"
    a=0
    while [ "$a" -lt "$N" ]; do
        case "$alone" in *" $a "*) a=$((a + 1)); continue ;; esac
        step "$BASE_SHA" "$(field "$a" 2)" || exit 2
        tip="$(commit "$STEP_TREE" "$BASE_SHA" "$(field "$a" 2)")"
        b=$((a + 1))
        while [ "$b" -lt "$N" ]; do
            case "$alone" in *" $b "*) b=$((b + 1)); continue ;; esac
            step "$tip" "$(field "$b" 2)"
            rc=$?
            [ "$rc" -le 1 ] || exit 2
            if [ "$rc" -eq 1 ]; then
                printf '  %s x %s  %s\n' "$(field "$a" 1)" "$(field "$b" 1)" "$STEP_FILES"
                found=1
            fi
            b=$((b + 1))
        done
        a=$((a + 1))
    done
    [ "$found" -eq 1 ] || echo "  none"
}

# simulate TITLE INDEX...: prints the order, returns 1 when anything conflicted.
simulate() {
    local title="$1" tip="$BASE_SHA" pos=0 clean=0 rebase=0 manual=0 noop=0 idx label sha kind
    shift
    echo "order: $title"
    for idx in "$@"; do
        pos=$((pos + 1))
        label="$(field "$idx" 1)"
        sha="$(field "$idx" 2)"
        kind="$(field "$idx" 3)"
        if git merge-base --is-ancestor "$sha" "$tip"; then
            noop=$((noop + 1))
            printf '  %2d. %-8s %-6s already in the tip\n' "$pos" "$label" "$kind"
            continue
        fi
        step "$tip" "$sha"
        case $? in
            0)
                tip="$(commit "$STEP_TREE" "$tip" "$sha")"
                clean=$((clean + 1))
                printf '  %2d. %-8s %-6s clean\n' "$pos" "$label" "$kind"
                ;;
            1)
                if [ "$kind" = bot ]; then
                    rebase=$((rebase + 1))
                    printf '  %2d. %-8s %-6s conflict: %s -> Dependabot rebases it; wait for its CI\n' \
                        "$pos" "$label" "$kind" "$STEP_FILES"
                else
                    manual=$((manual + 1))
                    printf '  %2d. %-8s %-6s conflict: %s -> MANUAL: Dependabot will not rebase this PR\n' \
                        "$pos" "$label" "$kind" "$STEP_FILES"
                fi
                ;;
            *) exit 2 ;;
        esac
    done
    echo "  summary: clean=$clean already-in=$noop dependabot-rebase=$rebase manual=$manual"
    [ $((rebase + manual)) -eq 0 ] || echo "  note: a PR that conflicted is not in the tip"
    echo "tip $tip"
    [ $((rebase + manual)) -eq 0 ]
}

echo "base $BASE $(git rev-parse --short "$BASE_SHA") · method $METHOD · $N PRs"

if [ "$PLAN" -eq 0 ]; then
    ORDER=()
    i=0
    while [ "$i" -lt "$N" ]; do ORDER+=("$i"); i=$((i + 1)); done
    simulate "as given" "${ORDER[@]}"
    exit $?
fi

# Stacked PRs: an ancestor has fewer commits above the base, so sorting on that count keeps a
# stack in order. A number sort only applies to PR numbers, so labels sort after them, as text.
sort_key() { # sort_key INDEX
    local label
    label="$(field "$1" 1)"
    case "$label" in
        \#*) printf '%010d' "${label#\#}" ;;
        *) printf 'z%s' "$label" ;;
    esac
}

RECOMMENDED=()
NUMERIC=()
i=0
while [ "$i" -lt "$N" ]; do
    printf '%s %s %s %s\n' "$(field "$i" 3)" "$(field "$i" 4)" "$(sort_key "$i")" "$i"
    i=$((i + 1))
done >"$W/keys"

while read -r _ _ _ idx; do
    RECOMMENDED+=("$idx")
done < <(awk '$1 == "edited"' "$W/keys" | sort -k2,2n -k3,3)
while read -r _ _ _ idx; do
    RECOMMENDED+=("$idx")
done < <(awk '$1 == "bot"' "$W/keys" | sort -k3,3)
while read -r _ _ _ idx; do
    NUMERIC+=("$idx")
done < <(sort -k3,3 "$W/keys")

pairs
echo
simulate "recommended (PRs Dependabot will not rebase go first)" "${RECOMMENDED[@]}"
STATUS=$?
echo
if [ "${RECOMMENDED[*]}" = "${NUMERIC[*]}" ]; then
    echo "order: ascending numbers is this same order"
    exit "$STATUS"
fi
simulate "ascending numbers (what tends to happen when PRs are merged down the list)" "${NUMERIC[@]}"
exit "$STATUS"
