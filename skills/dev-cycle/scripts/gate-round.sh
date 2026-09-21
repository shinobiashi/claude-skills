#!/usr/bin/env bash
#
# Helper for dev-cycle's gate-round bookkeeping: the push that ends a round
# (Step 7-6) and the "reflect on GitHub" step that follows it (Step 7-7).
#
# A gate round used to be a hand-typed sequence of ~8 commands (capture T,
# push, one `gate-threads.sh done|reply` per thread, `gh pr comment`, check
# the unresolved count). Done five times in a row on one PR, the same slips
# are easy to make, so the rules are baked in:
#
#   1. T is the UTC time captured *immediately before* the push. The next
#      bot's `--since` and `gate-threads.sh list` filter on it, so a T taken
#      after the push (or reused from an earlier round) drops or duplicates
#      threads. `push` prints it only when the push succeeded, so a stale T
#      is never printed for a failed push.
#   2. Replies say "fixed in <sha>". They must only go out after that commit
#      is on the PR head, or the bot and the reader are pointed at a sha
#      GitHub does not have. `publish` refuses when the local HEAD is not the
#      PR head (override: --allow-unpushed).
#   3. A half-published round is worse than an unpublished one. `publish`
#      validates every input file before it posts anything, and on a failure
#      midway it names what was already posted so the rerun can leave those
#      out (a rerun of the full list would reply twice).
#   4. Never push the default branch from here.
#
# Usage:
#   gate-round.sh push [<branch>] [--remote <name>]
#       Capture T, `git push -u <remote> <branch>` (default: the current
#       branch, origin), then print `HEAD=<short sha>` and `T=<ISO8601 UTC>`.
#       Refuses main / master / the remote's default branch. Uncommitted
#       changes are not part of the push; they are reported on stderr.
#
#   gate-round.sh publish <PR> --summary <FILE>
#                         [--done <THREAD_ID>=<REPLY_FILE>]...
#                         [--hold <THREAD_ID>=<REPLY_FILE>]...
#                         [--since <T>] [--allow-unpushed]
#       In this order: for each --done, reply and Resolve the thread; for each
#       --hold, reply and leave it open; then post FILE as a PR comment (the
#       round summary); then, with --since, print the unresolved-thread
#       status so the round ends on a visible 0.
#       --done  a finding you fixed  (gate-threads.sh done)
#       --hold  a finding you left open (gate-threads.sh reply; never resolved)
#
#   --dry-run (anywhere) prints what would be done instead of doing it.
#
# Environment:
#   GATE_THREADS  path to gate-threads.sh (default: the fix-copilot-review
#                 skill next to this one)
#
# Reply / summary text is only ever read from files, never from the command
# line, for the same quoting reasons as gate-threads.sh.
set -euo pipefail

DRY_RUN=0
ARGS=()
for arg in "$@"; do
	if [ "$arg" = "--dry-run" ]; then
		DRY_RUN=1
	else
		ARGS+=( "$arg" )
	fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

usage() {
	sed -n '3,51p' "$0" | sed 's/^# \{0,1\}//'
	exit 64
}

die() {
	echo "gate-round: $*" >&2
	exit 1
}

# Print a command in dry-run mode, run it otherwise.
run() {
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '+'
		printf ' %q' "$@"
		printf '\n'
	else
		"$@"
	fi
}

gate_threads_path() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	echo "${GATE_THREADS:-${here}/../../fix-copilot-review/scripts/gate-threads.sh}"
}

default_branch() {
	local ref
	ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
	echo "${ref#origin/}"
}

cmd_push() {
	local remote="origin" branch=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--remote) [ $# -ge 2 ] || die "--remote needs a name"; remote="$2"; shift 2 ;;
			-*) die "unknown option for push: $1" ;;
			*) [ -z "$branch" ] || die "push takes at most one branch"; branch="$1"; shift ;;
		esac
	done

	[ -n "$branch" ] || branch="$(git branch --show-current)"
	[ -n "$branch" ] || die "detached HEAD: pass a branch name"

	local dflt
	dflt="$(default_branch)"
	if [ "$branch" = "main" ] || [ "$branch" = "master" ] || { [ -n "$dflt" ] && [ "$branch" = "$dflt" ]; }; then
		die "refusing to push the default branch ($branch) from a gate round"
	fi

	if [ -n "$(git status --porcelain)" ]; then
		echo "gate-round: warning: uncommitted changes are not part of this push:" >&2
		git status --short >&2
	fi

	# T is taken right before the push; it is printed only if the push worked.
	local t
	t="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	run git push -u "$remote" "$branch"

	if [ "$DRY_RUN" -eq 1 ]; then
		echo "HEAD=$(git rev-parse --short HEAD) (not pushed: dry run)"
	else
		echo "HEAD=$(git rev-parse --short HEAD)"
	fi
	echo "T=$t"
}

# Split "ID=file" into $ENTRY_ID / $ENTRY_FILE.
split_entry() {
	local flag="$1" value="$2"
	case "$value" in
		*=*) ;;
		*) die "$flag expects THREAD_ID=REPLY_FILE, got: $value" ;;
	esac
	ENTRY_ID="${value%%=*}"
	ENTRY_FILE="${value#*=}"
	[ -n "$ENTRY_ID" ] || die "$flag: empty thread id in: $value"
	[ -n "$ENTRY_FILE" ] || die "$flag: empty file in: $value"
	case "$ENTRY_ID" in
		*[!A-Za-z0-9_-]*) die "$flag: thread id has unexpected characters: $ENTRY_ID" ;;
	esac
}

require_file() {
	local what="$1" file="$2"
	[ -f "$file" ] || die "$what not found: $file"
	[ -s "$file" ] || die "$what is empty: $file"
}

cmd_publish() {
	[ $# -ge 1 ] || usage
	local pr="$1"
	shift
	case "$pr" in
		''|*[!0-9]*) die "PR must be a number, got: $pr" ;;
	esac

	local summary="" since="" allow_unpushed=0
	local kinds=() ids=() files=()
	while [ $# -gt 0 ]; do
		case "$1" in
			--summary) [ $# -ge 2 ] || die "--summary needs a file"; summary="$2"; shift 2 ;;
			--since) [ $# -ge 2 ] || die "--since needs a timestamp"; since="$2"; shift 2 ;;
			--allow-unpushed) allow_unpushed=1; shift ;;
			--done|--hold)
				[ $# -ge 2 ] || die "$1 needs THREAD_ID=REPLY_FILE"
				split_entry "$1" "$2"
				kinds+=( "${1#--}" )
				ids+=( "$ENTRY_ID" )
				files+=( "$ENTRY_FILE" )
				shift 2
				;;
			*) die "unknown option for publish: $1" ;;
		esac
	done

	[ -n "$summary" ] || die "--summary is required (the round summary comment)"

	# Validate everything before posting anything. (Loops run over a count,
	# not "${!ids[@]}": an empty array trips `set -u` on macOS's bash 3.2.)
	require_file "summary file" "$summary"
	local i j count="${#ids[@]}"
	for (( i = 0; i < count; i++ )); do
		require_file "reply file for ${ids[$i]}" "${files[$i]}"
		for (( j = i + 1; j < count; j++ )); do
			if [ "${ids[$i]}" = "${ids[$j]}" ]; then
				die "thread listed twice: ${ids[$i]}"
			fi
		done
	done

	local gt
	gt="$(gate_threads_path)"
	if [ "$count" -gt 0 ] || [ -n "$since" ]; then
		[ -x "$gt" ] || die "gate-threads.sh not found or not executable: $gt (set GATE_THREADS)"
	fi
	command -v gh >/dev/null 2>&1 || die "gh is required"

	if [ "$allow_unpushed" -eq 0 ]; then
		local local_head pr_head
		local_head="$(git rev-parse HEAD)"
		pr_head="$(gh pr view "$pr" --json headRefOid --jq .headRefOid)"
		if [ "$local_head" != "$pr_head" ]; then
			die "local HEAD ${local_head:0:7} is not the PR head ${pr_head:0:7}: push first (replies must point at commits GitHub has), or pass --allow-unpushed"
		fi
	fi

	local posted=() n
	for (( i = 0; i < count; i++ )); do
		if [ "${kinds[$i]}" = "done" ]; then
			n="done"
		else
			n="reply"
		fi
		if ! run "$gt" "$n" "$pr" "${ids[$i]}" "${files[$i]}"; then
			{
				echo "gate-round: stopped at ${kinds[$i]} ${ids[$i]}."
				if [ "${#posted[@]}" -gt 0 ]; then
					echo "gate-round: already posted: ${posted[*]}"
				else
					echo "gate-round: nothing was posted yet."
				fi
				echo "gate-round: rerun with the remaining entries only (and the summary), or those threads get a second reply."
			} >&2
			exit 1
		fi
		posted+=( "${kinds[$i]}:${ids[$i]}" )
	done

	if ! run gh pr comment "$pr" --body-file "$summary"; then
		{
			echo "gate-round: the summary comment failed."
			if [ "${#posted[@]}" -gt 0 ]; then
				echo "gate-round: already posted: ${posted[*]}"
			else
				echo "gate-round: already posted: none"
			fi
			echo "gate-round: post the summary by hand: gh pr comment $pr --body-file $summary"
		} >&2
		exit 1
	fi

	if [ -n "$since" ]; then
		run "$gt" status "$pr" "$since"
	fi
}

sub="${1:-}"
[ -n "$sub" ] || usage
shift || true

case "$sub" in
	push) cmd_push "$@" ;;
	publish) cmd_publish "$@" ;;
	-h|--help|help) usage ;;
	*) echo "gate-round: unknown command: $sub" >&2; usage ;;
esac
