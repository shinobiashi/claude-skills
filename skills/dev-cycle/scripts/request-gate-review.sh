#!/usr/bin/env bash
#
# Helper for dev-cycle's bot gate: request the Copilot / Codex review of the
# PR's current head and wait for each bot's ACTUAL response to that head.
#
# Lessons baked in from real gate rounds (jp4wc-rakusync PR #4-#11 and
# omotegae-project, 2026-09-18..24):
#
# - Requesting Copilot through the REST reviewers endpoint with the login
#   `Copilot` returns 201 but, from about 2026-09-21 on, registered the
#   request only about one time in six: no `review_requested` timeline
#   event, no pending reviewer, and no review ever came — while the same
#   request made from the web UI registered every single time. `Copilot` is
#   not an identifier GitHub documents. The documented ones are
#   `gh pr edit <pr> --add-reviewer @copilot` (gh >= 2.88; the same GraphQL
#   mutation the web UI uses) and, for REST, the login
#   `copilot-pull-request-reviewer[bot]`. This script tries them in that
#   order and confirms each attempt before trusting it.
# - Registration is confirmed, never assumed. A request that silently never
#   registered used to cost a full --timeout (15 minutes) before anyone
#   noticed. Evidence that an attempt registered is any of: Copilot in the
#   PR's pending reviewers (GraphQL `reviewRequests` or REST
#   `requested_reviewers`; counted only when Copilot was absent before the
#   attempt, since a leftover request from an earlier round looks the same),
#   a `review_requested` timeline event stamped at or after the attempt (the
#   timeline endpoint can lag several minutes, so it is never the only
#   source), or a Copilot review of the current head submitted after the
#   attempt. Each method gets 90s to confirm; after both, evidence is
#   polled for a further grace period (5 minutes from the first attempt in
#   total: the timeline can lag that long, and a real review usually lands
#   within it). Still nothing → exit 2, with the manual fallback (request
#   in the UI, then rerun with --wait-only) spelled out on stderr.
# - Both bots have taken well over an hour to respond at times, so the wait
#   matches a response to the current commit by the review's `commit_id`,
#   not by submission time — a delayed review of an *older* push landing
#   inside this round's wait window would otherwise pass as a fresh
#   response. Codex additionally counts as responded when it posts an issue
#   comment after T (its "Didn't find any major issues" note has no review
#   object).
# - Codex is only asked for when `--request-codex` is given: on
#   repositories where Codex auto-reviews every push, posting "@codex
#   review" just yields a "connect a Codex account" reply, and the
#   auto-review of the current head is what gets waited on. When the post
#   itself fails twice, Codex is not waited for — nothing was asked.
# - Requests go out before any waiting, Codex first (its request is one
#   comment; Copilot's confirmation can take up to 90s per method).
#
# Usage:
#   request-gate-review.sh <PR> [--copilot-only|--codex-only] [--request-codex]
#                          [--wait-only] [--timeout SECONDS] [--since TIMESTAMP]
#
#   --wait-only   request nothing; only wait for the responses. For after a
#                 manual request in the UI (exit 2), or to resume a wait that
#                 timed out (exit 1). Pass the original run's --since.
#
# Prints `T=<UTC timestamp>` once the requests are out — record it, it is
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
# Ends with one status line per bot, then `DONE` only on success:
#   COPILOT=responded|timeout|unregistered|not-waited
#   CODEX=responded|timeout|request-failed|not-waited
#
# Exit status:
#   0  every bot being waited on responded to the current head
#   1  the request was made and confirmed, but a bot did not respond within
#      --timeout (default 900s). Not "no findings": rerun with --wait-only
#      later, or proceed and re-check with fix-copilot-review afterwards
#   2  a request could not be made or never registered: Copilot confirmed
#      through neither method (request it in the UI, then --wait-only), or
#      the "@codex review" comment could not be posted. Returned within a
#      few minutes when nothing else is waited on; when the other bot is
#      waited on, that wait runs first and the status lines say which bot
#      responded
#
# Worst case: about 5 minutes of requesting/confirming plus --timeout.
# Requires `jq` (not bundled with `gh`) and gh 2.88+ (for `@copilot`).
set -euo pipefail

pr="${1:?PR number required}"
shift
case "$pr" in
	''|*[!0-9]*) echo "request-gate-review: PR must be a number, got: $pr" >&2; exit 64 ;;
esac

want_copilot=1
want_codex=1
request_codex=0
wait_only=0
timeout=900
since=""

while [ $# -gt 0 ]; do
	case "$1" in
		--copilot-only) want_codex=0 ;;
		--codex-only) want_copilot=0 ;;
		--request-codex) request_codex=1 ;;
		--wait-only) wait_only=1 ;;
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
# count as 0 and both request methods would look unregistered. Fail before
# asking anything.
command -v jq >/dev/null 2>&1 || {
	echo "request-gate-review: jq is required but was not found on PATH" >&2
	exit 69
}

slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
owner="${slug%%/*}"
repo="${slug#*/}"
# request_time is for confirming Copilot's own registration (taken right
# before the requests, or an older still-pending request could be mistaken
# for this one); T is only what gets printed for gate-threads.sh and is the
# push time when given via --since. See the --since note above for why T
# can't just be "now" here.
request_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T="${since:-$request_time}"
head_sha="$(gh pr view "$pr" --json headRefOid --jq '.headRefOid')"

# Seconds to look for confirmation evidence after each request method, the
# interval between looks, and the total budget from the first attempt
# before an unconfirmed request is declared unregistered (what is left of
# it after both methods is the grace period).
CONFIRM_WINDOW=90
CONFIRM_STEP=10
CONFIRM_TOTAL=300

# Copilot's login differs by endpoint: `Copilot` in REST user objects and
# timeline events, `copilot-pull-request-reviewer[bot]` as a review author,
# `copilot-pull-request-reviewer` as a GraphQL Bot. All are one account
# (id 175728472), so every probe matches any of them. A jq boolean over an
# object that may or may not carry `login`.
COPILOT='((.login // "") | ascii_downcase | . == "copilot" or startswith("copilot-pull-request-reviewer"))'
CODEX_LOGIN='chatgpt-codex-connector[bot]'

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

# 1 while the GraphQL `reviewRequests` (what the web UI shows as pending
# reviewers) lists Copilot, else 0. Same failure handling as probe_count.
copilot_pending_graphql() {
	local out rc=0
	out="$(gh api graphql \
		-f query='query($o: String!, $r: String!, $n: Int!) { repository(owner: $o, name: $r) { pullRequest(number: $n) { reviewRequests(first: 100) { nodes { requestedReviewer { __typename ... on Bot { login } ... on User { login } ... on Team { slug } } } } } } }' \
		-f o="$owner" -f r="$repo" -F n="$pr" 2>&1 \
		| jq "[.data.repository.pullRequest.reviewRequests.nodes[]?.requestedReviewer // {} | select($COPILOT)] | length" 2>&1)" || rc=$?
	case "$out" in
		''|*[!0-9]*)
			echo "request-gate-review: GraphQL probe failed (exit $rc): $out" >&2
			echo 0
			return 0
			;;
	esac
	printf '%s' "$out"
}

# 1 while Copilot is a pending reviewer of the PR, else 0. Asked of both
# the GraphQL and the REST pending list, so a lag or a bot-shaped gap in
# one of them does not hide a registration.
copilot_pending() {
	local g r
	g="$(copilot_pending_graphql)"
	r="$(probe_count "repos/$slug/pulls/$pr/requested_reviewers" "[.[].users[]? | select($COPILOT)] | length")"
	if [ "$g" -ge 1 ] || [ "$r" -ge 1 ]; then
		echo 1
	else
		echo 0
	fi
}

# Prints the evidence source showing Copilot's request registered, or
# nothing (return 1). $1 is whether Copilot was already pending before this
# run's attempts: the pending list only reports the current state, so it
# proves a registration only on an absent-to-present transition — a request
# left over from an earlier round would otherwise pass as fresh evidence.
copilot_registration_evidence() {
	local was_pending="${1:?pending state before the request required}" n
	if [ "$was_pending" -eq 0 ]; then
		n="$(copilot_pending)"
		[ "$n" -ge 1 ] && { echo "pending reviewer list (absent before the request)"; return 0; }
	fi

	# `created_at >= $request_time`, not `>`: the request lands within the
	# same second often enough that a strict `>` throws out a request that
	# did register. request_time, not T: T can be well before the request
	# (--since), and an older leftover request would then satisfy `>= T`.
	n="$(probe_count "repos/$slug/issues/$pr/timeline" "[.[] | select(.event == \"review_requested\" and ((.requested_reviewer // {}) | $COPILOT) and .created_at >= \"$request_time\")] | length")"
	[ "$n" -ge 1 ] && { echo "timeline event"; return 0; }

	n="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(((.user // {}) | $COPILOT) and .commit_id == \"$head_sha\" and .submitted_at >= \"$request_time\")] | length")"
	[ "$n" -ge 1 ] && { echo "review of $head_sha"; return 0; }

	return 1
}

# Polls copilot_registration_evidence for up to $2 seconds (counted in
# sleeps, so the budget is the same whatever the probes' own latency).
# Prints the evidence and returns 0 as soon as any shows up.
confirm_copilot() {
	local was_pending="$1" window="$2" waited=0 evidence
	while :; do
		if evidence="$(copilot_registration_evidence "$was_pending")"; then
			printf '%s' "$evidence"
			return 0
		fi
		[ "$waited" -ge "$window" ] && return 1
		sleep "$CONFIRM_STEP"
		waited=$((waited + CONFIRM_STEP))
	done
}

# Method 1: the documented CLI path (GraphQL requestReviews, the same
# mutation as the web UI). gh < 2.88 rejects @copilot, and gh can fail with
# "'' not found" while a Bot reviewer is already pending (cli/cli#11245);
# either way the REST method is tried next.
request_copilot_cli() {
	local out rc=0
	out="$(gh pr edit "$pr" --add-reviewer @copilot 2>&1)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "request-gate-review: gh pr edit --add-reviewer @copilot failed (exit $rc): $out" >&2
		return 1
	fi
	echo "request-gate-review: requested Copilot via gh pr edit --add-reviewer @copilot"
	return 0
}

# Method 2: the documented REST login. The response is the PR object; how
# many Copilot entries its pending list carries is reported for the log,
# but the confirmation poll still decides (a leftover request looks the
# same in that list).
request_copilot_rest() {
	local out rc=0 n
	out="$(gh api -X POST "repos/$slug/pulls/$pr/requested_reviewers" -f 'reviewers[]=copilot-pull-request-reviewer[bot]' 2>&1)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "request-gate-review: POST requested_reviewers (copilot-pull-request-reviewer[bot]) failed (exit $rc): $out" >&2
		return 1
	fi
	n="$(printf '%s' "$out" | jq "[.requested_reviewers[]? | select($COPILOT)] | length" 2>/dev/null || echo 0)"
	echo "request-gate-review: requested Copilot via REST (copilot-pull-request-reviewer[bot]); the response lists Copilot as pending: $n"
	return 0
}

# Returns 0 when a request is registered (or was accepted while Copilot
# was already pending, which presence cannot confirm), 2 when nothing
# registered — the caller then has nothing to wait for on Copilot's side.
request_copilot() {
	local was_pending accepted=0 spent=0 grace evidence rerun
	was_pending="$(copilot_pending)"
	[ "$was_pending" -ge 1 ] && echo "request-gate-review: Copilot is already listed as pending — only a post-request timeline event or a review of $head_sha will count as confirmation" >&2

	if request_copilot_cli; then
		accepted=1
		if evidence="$(confirm_copilot "$was_pending" "$CONFIRM_WINDOW")"; then
			echo "request-gate-review: Copilot request confirmed ($evidence)"
			return 0
		fi
		spent=$((spent + CONFIRM_WINDOW))
		echo "request-gate-review: nothing confirms the gh pr edit request after ${CONFIRM_WINDOW}s — trying the REST endpoint" >&2
	fi

	if request_copilot_rest; then
		accepted=1
		if evidence="$(confirm_copilot "$was_pending" "$CONFIRM_WINDOW")"; then
			echo "request-gate-review: Copilot request confirmed ($evidence)"
			return 0
		fi
		spent=$((spent + CONFIRM_WINDOW))
		echo "request-gate-review: nothing confirms the REST request after ${CONFIRM_WINDOW}s" >&2
	fi

	# Grace period: a registered request whose only trace so far is a lagging
	# timeline event (or a review still being written) shows up here rather
	# than being declared unregistered — and re-requested — by mistake.
	grace=$((CONFIRM_TOTAL - spent))
	if [ "$accepted" -eq 1 ] && [ "$grace" -gt 0 ]; then
		echo "request-gate-review: polling for evidence for another ${grace}s before giving up (the timeline endpoint can lag)" >&2
		if evidence="$(confirm_copilot "$was_pending" "$grace")"; then
			echo "request-gate-review: Copilot request confirmed late ($evidence)"
			return 0
		fi
	fi

	if [ "$accepted" -eq 1 ] && [ "$was_pending" -ge 1 ]; then
		echo "request-gate-review: Copilot was already pending before this run and the re-request was accepted; waiting for a review of $head_sha (the pending list cannot confirm a re-request)" >&2
		return 0
	fi

	rerun="$(basename "$0") $pr --wait-only --since $T"
	[ "$want_codex" -eq 0 ] && rerun="$rerun --copilot-only"
	cat >&2 <<EOM
request-gate-review: Copilot's review request did not register through either method (gh pr edit --add-reviewer @copilot, REST copilot-pull-request-reviewer[bot]).
request-gate-review: request it by hand — open the PR (gh pr view $pr --web), Reviewers → Copilot — then wait for it with:
request-gate-review:   $rerun
EOM
	return 2
}

# Posts "@codex review". The body goes through stdin on purpose: `--body
# "..."` breaks on shell parsing for anything less trivial than this, and
# keeping one habit avoids the accident elsewhere. Two attempts.
post_codex_request() {
	local attempt
	for attempt in 1 2; do
		if printf '@codex review\n' | gh pr comment "$pr" --body-file - >/dev/null 2>&1; then
			echo "request-gate-review: posted @codex review"
			return 0
		fi
		echo "request-gate-review: posting @codex review failed (attempt $attempt/2)" >&2
		[ "$attempt" -eq 1 ] && sleep 10
	done
	return 1
}

copilot_status=not-waited
codex_status=not-waited

# Requests first, Codex before Copilot — see header.
if [ "$want_codex" -eq 1 ] && [ "$request_codex" -eq 1 ] && [ "$wait_only" -eq 0 ]; then
	if ! post_codex_request; then
		echo "request-gate-review: Codex was not asked, so it will not be waited for" >&2
		want_codex=0
		codex_status=request-failed
	fi
fi

if [ "$want_copilot" -eq 1 ] && [ "$wait_only" -eq 0 ]; then
	rc=0
	request_copilot || rc=$?
	if [ "$rc" -ne 0 ]; then
		want_copilot=0
		copilot_status=unregistered
	fi
fi

echo "T=$T"

# Prints the status lines and exits. DONE marks success only.
finish() {
	echo "COPILOT=$copilot_status"
	echo "CODEX=$codex_status"
	[ "$1" -eq 0 ] && echo DONE
	exit "$1"
}

# 2 when a request failed or never registered, else $1.
exit_code_for() {
	if [ "$copilot_status" = unregistered ] || [ "$codex_status" = request-failed ]; then
		echo 2
	else
		echo "$1"
	fi
}

if [ "$want_copilot" -eq 0 ] && [ "$want_codex" -eq 0 ]; then
	echo "request-gate-review: nothing to wait for" >&2
	finish "$(exit_code_for 1)"
fi

deadline=$((SECONDS + timeout))
while :; do
	c=-
	x=-
	# Match by commit_id, not by submission time: a bot's review of an
	# *older* push can land inside this round's wait window (Copilot and
	# Codex have both taken well over an hour to respond at times), and a
	# time-only check would mistake that stale review for a response to
	# the current commit. Codex's no-findings note is an issue comment with
	# no commit, so it is matched by time (T, inclusive) instead.
	if [ "$want_copilot" -eq 1 ]; then
		c="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(((.user // {}) | $COPILOT) and .commit_id == \"$head_sha\")] | length")"
	fi
	if [ "$want_codex" -eq 1 ]; then
		xr="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(.user.login == \"$CODEX_LOGIN\" and .commit_id == \"$head_sha\")] | length")"
		xc="$(probe_count "repos/$slug/issues/$pr/comments" "[.[] | select(.user.login == \"$CODEX_LOGIN\" and .created_at >= \"$T\")] | length")"
		x=$((xr + xc))
	fi
	echo "$(date -u +%H:%M:%S) copilot=$c codex=$x"

	all=1
	if [ "$want_copilot" -eq 1 ]; then
		if [ "$c" -ge 1 ]; then copilot_status=responded; else all=0; fi
	fi
	if [ "$want_codex" -eq 1 ]; then
		if [ "$x" -ge 1 ]; then codex_status=responded; else all=0; fi
	fi
	[ "$all" -eq 1 ] && finish "$(exit_code_for 0)"

	[ "$SECONDS" -ge "$deadline" ] && break
	remaining=$((deadline - SECONDS))
	sleep "$((remaining < 60 ? remaining : 60))"
done

[ "$want_copilot" -eq 1 ] && [ "$copilot_status" != responded ] && copilot_status=timeout
[ "$want_codex" -eq 1 ] && [ "$codex_status" != responded ] && codex_status=timeout
echo "request-gate-review: timed out waiting for a response" >&2
finish "$(exit_code_for 1)"
