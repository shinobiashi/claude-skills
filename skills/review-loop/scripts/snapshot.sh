#!/usr/bin/env bash
#
# Record what a review round looks at - the working tree, including
# uncommitted changes and untracked (non-ignored) files - as a commit object,
# without touching HEAD, the index, the branch or any file.
#
# Why: review-loop's R2 reviews "only the R1 fix diff" and used to take it as
# `git diff <R1 HEAD>...HEAD`. That breaks when R1 starts on uncommitted work
# or when the user does not allow a commit between rounds: R1's target and
# R1's fixes then sit in the same working tree, HEAD cannot tell them apart,
# and untracked files are not in any diff. (paidy-wc PR #40, 2026-10-09: R1
# reviewed uncommitted changes plus a new untracked script; R2 had to rebuild
# the pre-fix tree from a saved patch, and `git archive` silently dropped
# `.claude/` and `docs/` because of export-ignore.)
#
# A snapshot is a commit whose tree is the working tree and whose parent is
# HEAD, kept alive by the ref refs/review-loop/<branch>/<round>. A clean
# working tree is recorded as HEAD itself. The refs are local only: a normal
# `git push` does not send them.
#
# Usage:
#   snapshot.sh save <round>                 record the working tree as <round>
#                                            (R1, R2, ...); prints the sha
#   snapshot.sh diff <from> [<to>] [<git-diff options>...]
#                                            git diff between two snapshots;
#                                            <to> defaults to the current
#                                            working tree. <from>/<to> are round
#                                            names or any commit-ish
#   snapshot.sh list                         this branch's snapshots
#   snapshot.sh clean                        delete this branch's snapshot refs
#
# Exit status: 0 success, 2 usage error or nothing to work on (detached HEAD,
# unknown round, invalid round name). `diff` passes git diff's own status
# through (0 also when there is no difference unless --exit-code is given).

set -euo pipefail

die() {
	echo "snapshot.sh: $*" >&2
	exit 2
}

usage() {
	sed -n 's/^# \{0,1\}//; /^Usage:/,/^Exit status/p' "$0" | sed '$d'
}

top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git work tree"
cd "$top"

branch=$(git branch --show-current)
[ -n "$branch" ] || die "HEAD is detached; review-loop snapshots are kept per branch"
prefix="refs/review-loop/$branch"

valid_round() {
	case "$1" in
		'' | *[!A-Za-z0-9._-]* | .* | *..*) return 1 ;;
	esac
	return 0
}

# Print a commit whose tree is the current working tree.
take_snapshot() {
	if [ -z "$(git status --porcelain --untracked-files=all)" ]; then
		git rev-parse HEAD
		return
	fi
	local tmp tree
	tmp=$(mktemp -d)
	# A copy of the real index keeps the stat cache (fast) and leaves the
	# real index - and what the user has staged - untouched.
	if [ -f "$(git rev-parse --git-path index)" ]; then
		cp "$(git rev-parse --git-path index)" "$tmp/index"
	fi
	GIT_INDEX_FILE="$tmp/index" git add -A -- . >/dev/null
	tree=$(GIT_INDEX_FILE="$tmp/index" git write-tree)
	rm -rf "$tmp"
	if git rev-parse --verify -q HEAD >/dev/null; then
		git commit-tree "$tree" -p HEAD -m "review-loop snapshot of the working tree"
	else
		git commit-tree "$tree" -m "review-loop snapshot of the working tree"
	fi
}

# Resolve a round name or a commit-ish to a commit sha.
resolve() {
	if valid_round "$1" && git rev-parse --verify -q "$prefix/$1^{commit}" >/dev/null; then
		git rev-parse "$prefix/$1^{commit}"
	elif git rev-parse --verify -q "$1^{commit}" >/dev/null; then
		git rev-parse "$1^{commit}"
	else
		die "no snapshot '$1' on branch $branch (snapshot.sh list shows the saved rounds)"
	fi
}

cmd=${1:-}
[ $# -gt 0 ] && shift

case "$cmd" in
	save)
		[ $# -eq 1 ] || die "usage: snapshot.sh save <round>"
		valid_round "$1" || die "invalid round name '$1' (letters, digits, '.', '_', '-')"
		old=$(git rev-parse --verify -q "$prefix/$1" || true)
		sha=$(take_snapshot)
		git update-ref "$prefix/$1" "$sha"
		[ -z "$old" ] || [ "$old" = "$sha" ] || echo "snapshot.sh: replaced $1 (was $old)" >&2
		echo "$sha"
		;;
	diff)
		[ $# -ge 1 ] || die "usage: snapshot.sh diff <from> [<to>] [<git-diff options>...]"
		from=$(resolve "$1")
		shift
		if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
			to=$(resolve "$1")
			shift
		else
			to=$(take_snapshot)
		fi
		git diff "$@" "$from" "$to"
		;;
	list)
		[ $# -eq 0 ] || die "usage: snapshot.sh list"
		git for-each-ref --format='%(refname) %(objectname:short)' "$prefix/" |
			sed "s#^$prefix/##"
		;;
	clean)
		[ $# -eq 0 ] || die "usage: snapshot.sh clean"
		git for-each-ref --format='%(refname)' "$prefix/" | while read -r ref; do
			git update-ref -d "$ref"
			echo "deleted ${ref#"$prefix"/}"
		done
		;;
	-h | --help | help)
		usage
		;;
	*)
		usage >&2
		exit 2
		;;
esac
