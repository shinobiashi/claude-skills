#!/usr/bin/env bash
#
# Helper for dev-cycle's bot gate (requesting and waiting for the Copilot /
# Codex review of the current commit). Requests Copilot, confirms the request
# actually registered, optionally posts "@codex review", and waits for each
# bot's response to the current head.
#
# Lessons baked in from real gate rounds:
#
# - `gh api ... requested_reviewers` for Copilot can return success without
#   ever creating a `review_requested` timeline event or review — the
#   request silently never happened, and a 15-minute wait ran out for
#   nothing. So the request is confirmed before it is waited on.
# - The opposite also happens: the request *did* register (the timeline
#   event carried the POST's own timestamp and Copilot reviewed within
#   minutes), but the issue timeline endpoint listed the event several
#   minutes later, so a short poll of the timeline alone reported "did not
#   register" round after round. Registration is therefore accepted on any
#   of three pieces of evidence, polled for up to five minutes per attempt:
#   Copilot listed by `pulls/<pr>/requested_reviewers` (immediate, the
#   authoritative pending-reviewer list — accepted only when Copilot was
#   *not* already pending before the POST, since a request left over from
#   an earlier round looks the same), the timeline event, or a Copilot
#   review of the current head submitted after the request (the request can
#   be fulfilled — and the reviewer dropped from the pending list — before
#   this even looks).
# - Both bots have taken well over an hour to respond at times, so the
#   wait matches a response to the current commit by the review's
#   `commit_id`, not by submission time — a delayed review of an *older*
#   push landing inside this round's wait window would otherwise pass as a
#   fresh response. Codex additionally counts as responded when it posts an
#   issue comment after T (its "Didn't find any major issues" note has no
#   review object).
# - Codex is only asked for when `--request-codex` is given: on
#   repositories where Codex auto-reviews every push, posting "@codex
#   review" just yields a "connect a Codex account" reply, and the
#   auto-review of the current head is what gets waited on.
#
# Usage:
#   request-gate-review.sh <PR> [--copilot-only|--codex-only] [--request-codex]
#                          [--timeout SECONDS] [--since TIMESTAMP]
#
# Prints `T=<UTC timestamp>` once Copilot is requested — record it, it is
# what `gate-threads.sh list/status/bodies` needs to identify this round's
# new findings. Pass `--since` with the time of the push that started this
# round (captured once, right before `git push`) instead of letting this
# default to "now": Codex reviews automatically on push and this script
# only runs after the CI wait, so its review of the current commit can
# already exist, with a comment timestamp earlier than "now" — and
# `gate-threads.sh list <PR> <T>` would then filter those findings out as
# not being new. A cutoff from before the push has no such gap, since
# nothing either bot does in response to it can predate the push itself.
#
# Exit status:
#   0  every bot being waited on responded
#   1  a bot did not respond within the wait timeout (default 900s)
#   2  Copilot's review request never registered (see stderr) — this needs
#      a human look, not a longer wait. Still waits for Codex if requested.
#      Before re-requesting, check `gh pr view <pr> --json reviews` and the
#      issue timeline yourself: a "did not register" can still be a lag.
#
# Worst-case running time is the registration phase (2 attempts x 300s poll
# + 15s) plus the response wait: about 1,530s at the default timeout. The
# caller's own timeout (dev-cycle SKILL.md Step 6: 1,800,000 ms) must cover
# that, or the script is killed before it prints DONE / its exit status in
# exactly the delayed-registration case this exists for. Requires `jq`.
set -euo pipefail

pr="${1:?PR number required}"
shift

want_copilot=1
want_codex=1
request_codex=0
timeout=900
since=""

while [ $# -gt 0 ]; do
	case "$1" in
		--copilot-only) want_codex=0 ;;
		--codex-only) want_copilot=0 ;;
		--request-codex) request_codex=1 ;;
		--timeout)
			shift
			timeout="${1:?--timeout requires a value}"
			case "$timeout" in
				''|*[!0-9]*) echo "request-gate-review: --timeout wants a positive integer, got: $timeout" >&2; exit 64 ;;
			esac
			;;
		--since) shift; since="${1:?--since requires a UTC timestamp}" ;;
		*) echo "request-gate-review: unknown argument: $1" >&2; exit 64 ;;
	esac
	shift
done

if [ "$want_copilot" -eq 0 ] && [ "$want_codex" -eq 0 ]; then
	echo "request-gate-review: --copilot-only and --codex-only together wait for nothing" >&2
	exit 64
fi

# Every probe below pipes through jq; without it each probe would quietly
# count as 0 and the script would burn both registration attempts before
# reporting a false exit 2. Fail before posting anything.
command -v jq >/dev/null 2>&1 || {
	echo "request-gate-review: jq is required but was not found on PATH" >&2
	exit 69
}

slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
# request_time is for confirming Copilot's own registration (must be right
# before the POST, or an older still-pending request could be mistaken for
# this one); T is only what gets printed for gate-threads.sh and is the
# push time when given via --since. They're deliberately not the same
# variable — see the --since usage note above for why T can't just be
# "now" here.
request_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T="${since:-$request_time}"
head_sha="$(gh pr view "$pr" --json headRefOid --jq '.headRefOid')"

copilot_registered=0

# One paginated `gh api` probe reduced to a single number. `--paginate`
# emits one JSON document per page (gh documents that pages stay separate
# unless --slurp), so the pages are combined with `jq -s` before the
# caller's expression runs — otherwise `--jq` could print one count per
# page ("0\n1") and the numeric test below would reject valid evidence.
# Array pages (timeline, reviews, comments) are flattened into one list of
# items; object pages (`requested_reviewers` returns `{users, teams}`) are
# kept whole, so the expression sees `.[]` as either one item or one page
# object. Prints 0 after reporting a transient failure, so a single bad
# request never aborts the poll.
probe_count() {
	local out rc=0
	out="$(gh api --paginate "$1" 2>&1 | jq -s "[.[] | if type == \"array\" then .[] else . end] | $2" 2>&1)" || rc=$?
	case "$out" in
		''|*[!0-9]*)
			echo "request-gate-review: probe failed (exit $rc): $out" >&2
			echo 0
			return 0
			;;
	esac
	printf '%s' "$out"
}

# 1 while Copilot is listed as a pending reviewer of the PR, else 0.
copilot_pending() {
	probe_count "repos/$slug/pulls/$pr/requested_reviewers" '[.[].users[] | select(.login=="Copilot")] | length'
}

# Prints the evidence source that shows Copilot's request registered, or
# nothing. Three sources, cheapest and most immediate first (see the header
# comment for why the timeline alone is not enough). $1 is whether Copilot
# was already pending *before* this attempt's POST: the pending list only
# reports the current state, so it proves this POST registered only on an
# absent-to-present transition — a request left over from an earlier round
# would otherwise pass as fresh evidence. When Copilot was already pending,
# only the post-time timeline event or a review of the current head counts.
copilot_registration_evidence() {
	local was_pending="${1:?pending state before the POST required}" n
	if [ "$was_pending" -eq 0 ]; then
		n="$(copilot_pending)"
		[ "$n" -ge 1 ] 2>/dev/null && { echo "requested_reviewers (absent before the POST)"; return 0; }
	fi

	# `created_at >= $request_time`, not `>`: the POST runs within the
	# same second often enough that a strict `>` throws out a request that
	# did register. This must be request_time, not T — T can be well
	# before the POST (--since), and an older already-pending request
	# would then satisfy `>= T` too.
	n="$(probe_count "repos/$slug/issues/$pr/timeline" "[.[] | select(.event==\"review_requested\" and .requested_reviewer.login==\"Copilot\" and .created_at >= \"$request_time\")] | length")"
	[ "$n" -ge 1 ] 2>/dev/null && { echo "timeline event"; return 0; }

	n="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(.user.login==\"copilot-pull-request-reviewer[bot]\" and .commit_id==\"$head_sha\" and .submitted_at >= \"$request_time\")] | length")"
	[ "$n" -ge 1 ] 2>/dev/null && { echo "review of $head_sha"; return 0; }

	return 1
}

# Copilot: confirm through any of the three evidence sources, polling up to
# five minutes, and POST once more if nothing showed up.
request_copilot() {
	local attempt post_rc was_pending
	for attempt in 1 2; do
		# Snapshot the pending list before the POST so the registration
		# check can tell a fresh request from one left over from an
		# earlier round (see copilot_registration_evidence()).
		was_pending="$(copilot_pending)"
		[ "$was_pending" -ge 1 ] 2>/dev/null && echo "request-gate-review: Copilot is already listed as pending before attempt $attempt — only a post-time timeline event or a review of $head_sha will count as registration" >&2

		post_rc=0
		gh api -X POST "repos/$slug/pulls/$pr/requested_reviewers" -f 'reviewers[]=Copilot' >/dev/null || post_rc=$?
		if [ "$post_rc" -ne 0 ]; then
			echo "request-gate-review: requesting Copilot failed (exit $post_rc, attempt $attempt/2)" >&2
			sleep 15
			continue
		fi

		local waited=0 evidence
		while [ "$waited" -lt 300 ]; do
			if evidence="$(copilot_registration_evidence "$was_pending")"; then
				echo "request-gate-review: Copilot request registered ($evidence, ${waited}s after the POST)"
				copilot_registered=1
				return 0
			fi
			sleep 15
			waited=$((waited + 15))
		done

		echo "request-gate-review: Copilot review request did not register within 300s (attempt $attempt/2)" >&2
	done
	return 1
}

if [ "$want_copilot" -eq 1 ]; then
	request_copilot || true
fi

if [ "$want_codex" -eq 1 ] && [ "$request_codex" -eq 1 ]; then
	# The body is passed via stdin/file on purpose: `--body "..."` breaks on
	# shell parsing for anything less trivial than this, and keeping one
	# habit avoids the accident elsewhere.
	printf '@codex review\n' | gh pr comment "$pr" --body-file - >/dev/null \
		&& echo "request-gate-review: posted @codex review" \
		|| echo "request-gate-review: posting @codex review failed" >&2
fi

echo "T=$T"

copilot_registration_failed=0
if [ "$want_copilot" -eq 1 ] && [ "$copilot_registered" -eq 0 ]; then
	echo "request-gate-review: giving up on Copilot for this round — the request never registered" >&2
	copilot_registration_failed=1
fi

wait_copilot=$copilot_registered
wait_codex=$want_codex

if [ "$wait_copilot" -eq 0 ] && [ "$wait_codex" -eq 0 ]; then
	echo "request-gate-review: nothing registered to wait for" >&2
	exit 2
fi

deadline=$((SECONDS + timeout))
while :; do
	c=0
	x=0
	xc=0
	# Match by commit_id, not by submission time: a bot's review of an
	# *older* push can land inside this round's wait window (Copilot and
	# Codex have both taken well over an hour to respond at times), and a
	# time-only check would mistake that stale review for a response to
	# the current commit. Codex's no-findings note is an issue comment with
	# no commit, so it is matched by time (T, inclusive) instead.
	[ "$wait_copilot" -eq 1 ] && c="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(.user.login==\"copilot-pull-request-reviewer[bot]\" and .commit_id==\"$head_sha\")] | length")"
	if [ "$wait_codex" -eq 1 ]; then
		x="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(.user.login==\"chatgpt-codex-connector[bot]\" and .commit_id==\"$head_sha\")] | length")"
		xc="$(probe_count "repos/$slug/issues/$pr/comments" "[.[] | select(.user.login==\"chatgpt-codex-connector[bot]\" and .created_at >= \"$T\")] | length")"
	fi
	echo "$(date -u +%H:%M:%S) copilot=$c codex=$((x + xc))"

	{ [ "$wait_copilot" -eq 0 ] || [ "$c" -ge 1 ]; } && { [ "$wait_codex" -eq 0 ] || [ $((x + xc)) -ge 1 ]; } && {
		echo DONE
		[ "$copilot_registration_failed" -eq 1 ] && exit 2
		exit 0
	}

	[ "$SECONDS" -ge "$deadline" ] && break
	remaining=$((deadline - SECONDS))
	sleep "$((remaining < 60 ? remaining : 60))"
done

echo "request-gate-review: timed out waiting for a response" >&2
[ "$copilot_registration_failed" -eq 1 ] && exit 2
exit 1
