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
#   object) or puts 👍 on the PR body after T (its documented no-findings
#   sign).
# - Codex's "Codex Review Summary" comment (marked
#   `<!-- codex-pull-request-review-summary -->`) is a status board, not a
#   response: it appears as "🔄 Running" the moment Codex starts, and is
#   edited to "✅ Completed" a few seconds after the real response
#   lands. It used to count as a response, so on a PR's first request the
#   wait ended while Codex was still running (saai-pi4t PR #5 and #6,
#   2026-10-06). It is excluded from the count; its state is shown in each
#   poll line and explained on a timeout.
# - Codex is only asked for when `--request-codex` is given: on
#   repositories where Codex auto-reviews every push, posting "@codex
#   review" just yields a "connect a Codex account" reply, and the
#   auto-review of the current head is what gets waited on. When the post
#   itself fails twice, Codex is not waited for — nothing was asked.
# - Requests go out before any waiting, Codex first (its request is one
#   comment; Copilot's confirmation can take up to 90s per method).
# - `--wait-ci` waits for the CI of the current head before asking anything,
#   so a turn no longer needs a hand-written wait loop in front of this
#   script (jp4wc-rakusync PR #14 wrote the same loop five times;
#   saai-signal-mail PR #8 six). It follows the GitHub Actions workflow runs
#   of the head sha, which exist from the moment the push registers, even
#   while they wait for a runner — `gh pr checks` says "no checks" until a
#   job starts, which once read a 20-minute runner backlog as "CI did not
#   start". A repository without Actions falls back to `gh pr checks`. A red
#   run stops the wait before any request: a bot asked to review a commit
#   whose CI failed reviews code that is about to change. "No run and no
#   check ever appeared" is reported as its own failure, never as "passed".
# - `--ci-only` is the same CI wait with nothing requested and no bot waited
#   on: for the push after the last gate round, and for the record commits
#   (Step 5, Step 8). A hand-written loop there passed a short sha to
#   `gh run list --commit`, which matches only the full sha, and kept
#   waiting for a CI that had long been green (wcpdf-jp-v1 PR #33,
#   2026-10-18).
# - Copilot can review the same head twice, the second review a few minutes
#   after the first (Japanized-for-WooCommerce PR #281 and #282, 2026-10-23:
#   3 and 4 minutes later, with a new finding). The wait used to end on the
#   first one, and the second was caught only because the thread count was
#   read again before triage. Once every bot has responded, the wait goes on
#   until --copilot-settle seconds (default 300) have passed since the last
#   Copilot review of the head was seen; another review restarts that
#   window and is announced. Time spent waiting for Codex counts towards
#   it, so the window adds nothing when Codex answers later anyway.
# - Codex has stayed "Running" for well over an hour (1h46m for one review
#   on Japanized-for-WooCommerce PR #282, 2026-10-23). A timeout now says for
#   how long its summary comment has said Running, and past
#   CODEX_LONG_RUN minutes suggests going on without it, re-reading the
#   threads right before the next push so that a late review is not missed.
#
# Usage:
#   request-gate-review.sh <PR> [--copilot-only|--codex-only] [--request-codex]
#                          [--wait-only] [--timeout SECONDS] [--since TIMESTAMP]
#                          [--wait-ci] [--ci-timeout SECONDS]
#                          [--copilot-settle SECONDS]
#   request-gate-review.sh <PR> --ci-only [--ci-timeout SECONDS]
#
#   --wait-only   request nothing; only wait for the responses. For after a
#                 manual request in the UI (exit 2), or to resume a wait that
#                 timed out (exit 1). Pass the original run's --since.
#   --wait-ci     first wait until the CI of the PR's head has finished;
#                 request only when it passed. Polled every 20s through the
#                 workflow runs of the head sha (`gh api
#                 repos/{owner}/{repo}/actions/runs?head_sha=…`), with
#                 `gh pr checks` as the fallback when the repository has no
#                 Actions run for that sha. A failed or cancelled run stops
#                 the wait at once and lists the run's failed jobs with the
#                 `gh run rerun <id> --failed` to use when a job died in
#                 setup (runner, network, image build) rather than in the
#                 code. Exit 3 when CI failed, when no run and no check
#                 appeared within 180s, when the PR head changed during the
#                 wait, or when CI was still running after --ci-timeout
#                 (default 2700s = 45 min: a 15-minute pipeline plus a runner
#                 backlog; giving --ci-timeout implies --wait-ci). Size the
#                 outer background timeout to --ci-timeout + 5 min + --timeout.
#   --copilot-settle
#                 once every bot has responded, keep waiting until this many
#                 seconds have passed since the last Copilot review of the head
#                 was seen (default 300; 0 = stop at the first response). A
#                 further review restarts the window. Counted in sleeps, and
#                 the time spent waiting for Codex counts towards it.
#   --ci-only     only the --wait-ci wait: request nothing, wait for no bot.
#                 Exit 0 with CI=passed and DONE when the CI of the head
#                 passed, 3 otherwise (as --wait-ci). Not combined with
#                 --copilot-only, --codex-only, --request-codex or
#                 --wait-only (exit 64). Size the outer background timeout
#                 to --ci-timeout + 1 min.
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
# Ends with one status line per bot and one for CI, then `DONE` only on success:
#   COPILOT=responded|timeout|unregistered|not-waited
#   CODEX=responded|timeout|request-failed|not-waited
#   CI=passed|failed|none|timeout|head-moved|not-waited
#
# Exit status:
#   0  every bot being waited on responded to the current head (--ci-only:
#      the CI of the head passed)
#   1  the request was made and confirmed, but a bot did not respond within
#      --timeout (default 900s). Not "no findings": rerun with --wait-only
#      later, or proceed and re-check with fix-copilot-review afterwards
#   2  a request could not be made or never registered: Copilot confirmed
#      through neither method (request it in the UI, then --wait-only), or
#      the "@codex review" comment could not be posted. Returned within a
#      few minutes when nothing else is waited on; when the other bot is
#      waited on, that wait runs first and the status lines say which bot
#      responded
#   3  --wait-ci: CI did not pass (a run or check failed or was cancelled,
#      no run and no check appeared, the PR head moved during the wait, or
#      CI was still running at --ci-timeout). Nothing was requested; the CI
#      line says which
#
# Worst case: --ci-timeout (with --wait-ci), then about 5 minutes of
# requesting/confirming plus --timeout, plus --copilot-settle for each
# Copilot review of the head that arrives after the others have responded.
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
wait_ci=0
ci_timeout=2700
ci_only=0
copilot_settle=300
bot_flags=""

while [ $# -gt 0 ]; do
	case "$1" in
		--copilot-only) want_codex=0; bot_flags="$bot_flags $1" ;;
		--codex-only) want_copilot=0; bot_flags="$bot_flags $1" ;;
		--request-codex) request_codex=1; bot_flags="$bot_flags $1" ;;
		--wait-only) wait_only=1; bot_flags="$bot_flags $1" ;;
		--ci-only) ci_only=1; wait_ci=1 ;;
		--timeout)
			shift
			timeout="${1:?--timeout requires a value}"
			case "$timeout" in
				''|*[!0-9]*) echo "request-gate-review: --timeout wants a positive integer, got: $timeout" >&2; exit 64 ;;
			esac
			;;
		--since) shift; since="${1:?--since requires a UTC timestamp}" ;;
		--copilot-settle)
			shift
			copilot_settle="${1:?--copilot-settle requires a value}"
			case "$copilot_settle" in
				''|*[!0-9]*) echo "request-gate-review: --copilot-settle wants a non-negative integer, got: $copilot_settle" >&2; exit 64 ;;
			esac
			;;
		--wait-ci) wait_ci=1 ;;
		--ci-timeout)
			shift
			ci_timeout="${1:?--ci-timeout requires a value}"
			case "$ci_timeout" in
				''|*[!0-9]*) echo "request-gate-review: --ci-timeout wants a positive integer, got: $ci_timeout" >&2; exit 64 ;;
			esac
			wait_ci=1
			;;
		*) echo "request-gate-review: unknown argument: $1" >&2; exit 64 ;;
	esac
	shift
done

if [ "$ci_only" -eq 1 ] && [ -n "$bot_flags" ]; then
	echo "request-gate-review: --ci-only requests nothing and waits for no bot; drop$bot_flags" >&2
	exit 64
fi

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

copilot_status=not-waited
codex_status=not-waited
ci_status=not-waited

# Prints the status lines and exits. DONE marks success only.
finish() {
	echo "COPILOT=$copilot_status"
	echo "CODEX=$codex_status"
	echo "CI=$ci_status"
	[ "$1" -eq 0 ] && echo DONE
	exit "$1"
}

slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
owner="${slug%%/*}"
repo="${slug#*/}"
head_sha="$(gh pr view "$pr" --json headRefOid --jq '.headRefOid')"

# CI wait: poll interval, and how long a PR may show neither a workflow run
# nor a check before that counts as "CI did not start" (a push takes a few
# seconds to register its runs).
CI_STEP=20
CI_APPEAR=180

# A run's conclusion that is not one of these is a failure (failure,
# cancelled, timed_out, action_required, startup_failure, stale).
CI_OK='($c == "success" or $c == "skipped" or $c == "neutral")'

# The workflow runs of the head sha as a JSON array of {id, name, status,
# conclusion}; `[]` when there are none or gh cannot answer.
ci_runs() {
	gh api "repos/$slug/actions/runs?head_sha=$head_sha&per_page=50" 2>/dev/null \
		| jq -c '[.workflow_runs[]? | {id, name, status, conclusion}]' 2>/dev/null || echo '[]'
}

# Lists the failed runs and their failed jobs, with the rerun to use when a
# job died in setup rather than in the code.
report_failed_runs() {
	local id name conclusion jobs
	while IFS=$'\t' read -r id name conclusion; do
		[ -n "$id" ] || continue
		echo "request-gate-review:   $name ($conclusion, run $id)" >&2
		jobs="$(gh run view "$id" --json jobs 2>/dev/null | jq -r --arg ok "$CI_OK" '.jobs[]? | (.conclusion // "") as $c | select($c != "" and ($c == "success" or $c == "skipped" or $c == "neutral" | not)) | "request-gate-review:     \(.name): \(.conclusion)"' 2>/dev/null || true)"
		[ -n "$jobs" ] && echo "$jobs" >&2
		echo "request-gate-review:   if a job died in setup (runner, network, image build) rather than in the code: gh run rerun $id --failed, then run this again" >&2
	done < <(printf '%s' "$1" | jq -r ".[] | select(.status == \"completed\" and ((.conclusion // \"\") as \$c | $CI_OK | not)) | [(.id | tostring), .name, (.conclusion // \"unknown\")] | @tsv" 2>/dev/null || true)
}

# The PR head is re-read when CI passes: a push during the wait means the
# green CI belongs to a commit that is no longer the head.
head_moved() {
	local now_sha
	now_sha="$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "$head_sha")"
	if [ -n "$now_sha" ] && [ "$now_sha" != "$head_sha" ]; then
		ci_status=head-moved
		echo "request-gate-review: the PR head moved from ${head_sha:0:7} to ${now_sha:0:7} during the CI wait — nothing is requested; run again for the new head" >&2
		return 0
	fi
	return 1
}

# Waits until the CI of the PR's head has finished. Sets ci_status and
# returns 0 only when it passed. The workflow runs of the head sha decide
# while any exists (queued ones included); without any, the PR's checks
# (`gh pr checks`, bucket = pass, fail, pending, skipping, cancel) do, for
# repositories whose CI is not GitHub Actions. The budget is counted in
# sleeps, like the confirmation polls.
wait_for_ci() {
	local waited=0 seen=0 runs counts total pending failed out rc=0
	echo "request-gate-review: waiting for the CI of PR #$pr (head ${head_sha:0:7}) to finish (up to ${ci_timeout}s)"
	while :; do
		runs="$(ci_runs)"
		counts="$(printf '%s' "$runs" | jq -r "if type == \"array\" and length > 0 then \"\(length) \([.[] | select(.status != \"completed\")] | length) \([.[] | select(.status == \"completed\" and ((.conclusion // \"\") as \$c | $CI_OK | not))] | length)\" else empty end" 2>/dev/null || true)"
		if [ -n "$counts" ]; then
			set -- $counts
			total="$1" pending="$2" failed="$3"
			seen=1
			if [ "$failed" -gt 0 ]; then
				ci_status=failed
				echo "request-gate-review: CI failed — nothing is requested:" >&2
				report_failed_runs "$runs"
				return 1
			fi
			if [ "$pending" -eq 0 ]; then
				head_moved && return 1
				ci_status=passed
				echo "request-gate-review: CI passed ($total workflow run(s) on ${head_sha:0:7})"
				return 0
			fi
		else
			rc=0
			out="$(gh pr checks "$pr" --json name,bucket 2>&1)" || rc=$?
			# gh exits non-zero while checks are pending or failing, so the exit
			# status says nothing here; only parsable JSON counts.
			counts="$(printf '%s' "$out" | jq -r 'if type == "array" then "\(length) \([.[] | select(.bucket == "pending")] | length) \([.[] | select(.bucket == "fail" or .bucket == "cancel")] | length)" else empty end' 2>/dev/null || true)"
			if [ -n "$counts" ]; then
				set -- $counts
				total="$1" pending="$2" failed="$3"
				[ "$total" -gt 0 ] && seen=1
				if [ "$failed" -gt 0 ]; then
					ci_status=failed
					echo "request-gate-review: CI failed — nothing is requested:" >&2
					printf '%s' "$out" | jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | "request-gate-review:   \(.name) (\(.bucket))"' >&2 2>/dev/null || true
					return 1
				fi
				if [ "$total" -gt 0 ] && [ "$pending" -eq 0 ]; then
					head_moved && return 1
					ci_status=passed
					echo "request-gate-review: CI passed ($total checks)"
					return 0
				fi
			fi
		fi
		if [ "$seen" -eq 0 ] && [ "$waited" -ge "$CI_APPEAR" ]; then
			ci_status=none
			echo "request-gate-review: no workflow run and no check appeared on PR #$pr within ${CI_APPEAR}s (last gh pr checks output, exit $rc: $out) — nothing is requested" >&2
			return 1
		fi
		if [ "$waited" -ge "$ci_timeout" ]; then
			ci_status=timeout
			echo "request-gate-review: CI was still running after ${ci_timeout}s — nothing is requested" >&2
			return 1
		fi
		sleep "$CI_STEP"
		waited=$((waited + CI_STEP))
	done
}

if [ "$wait_ci" -eq 1 ]; then
	wait_for_ci || finish 3
fi

# --ci-only: the CI wait was all that was asked for.
[ "$ci_only" -eq 1 ] && finish 0

# request_time is for confirming Copilot's own registration (taken right
# before the requests, or an older still-pending request could be mistaken
# for this one); T is only what gets printed for gate-threads.sh and is the
# push time when given via --since. See the --since note above for why T
# can't just be "now" here.
request_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T="${since:-$request_time}"

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
CODEX_SUMMARY_MARK='<!-- codex-pull-request-review-summary -->'

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

# `<status>@<commit>` from Codex's summary comment, read off its table row
# ("| 📝 **Code Review** | 🔄 **Running** since … | `a70dda6` | …", or
# "✅ **Completed** …"); `none` without such a comment, `unknown` when it
# cannot be read or parsed. For the log and the timeout message only — it
# never decides whether Codex responded.
codex_summary_state() {
	local out
	out="$(gh api --paginate "repos/$slug/issues/$pr/comments" 2>/dev/null | jq -rs --arg l "$CODEX_LOGIN" --arg m "$CODEX_SUMMARY_MARK" '
		[.[] | if type == "array" then .[] else . end
		 | select(.user.login == $l and ((.body // "") | contains($m)))] | last
		| if . == null then "none"
		  else [.body | scan("\\*\\*([A-Za-z][A-Za-z ]*)\\*\\*[^|\\n]*\\|\\s*`([0-9a-f]{7,40})`")] | .[0]
		       | if . == null then "unknown" else "\(.[0] | gsub(" "; "-"))@\(.[1])" end
		  end' 2>/dev/null)" || out=""
	case "$out" in
		''|*[[:space:]]*) echo unknown ;;
		*) printf '%s' "$out" ;;
	esac
}

# Whole minutes since the "Running since" time in Codex's summary comment;
# nothing when it is not running or the time cannot be read. For the
# timeout message only.
CODEX_LONG_RUN=60
codex_running_minutes() {
	gh api --paginate "repos/$slug/issues/$pr/comments" 2>/dev/null | jq -rs --arg l "$CODEX_LOGIN" --arg m "$CODEX_SUMMARY_MARK" '
		[.[] | if type == "array" then .[] else . end
		 | select(.user.login == $l and ((.body // "") | contains($m)))] | last
		| select(. != null)
		| (.body | capture("\\*\\*Running\\*\\* since <relative-time datetime=\"(?<t>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})")? | .t)
		| (now - ((. + "Z") | fromdateiso8601)) / 60 | floor' 2>/dev/null || true
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

codex_summary=none
# Copilot reviews of the head seen so far, and what is left of the settle
# window that follows the last one (see --copilot-settle), in slept seconds.
copilot_seen=0
settle_left=0
settle_said=0
deadline=$((SECONDS + timeout))
while :; do
	c=-
	x=-
	# Match by commit_id, not by submission time: a bot's review of an
	# *older* push can land inside this round's wait window (Copilot and
	# Codex have both taken well over an hour to respond at times), and a
	# time-only check would mistake that stale review for a response to
	# the current commit. Codex's no-findings note is an issue comment with
	# no commit, and its 👍 a reaction, so both are matched by time (T,
	# inclusive) instead. The summary comment is left out (see header).
	if [ "$want_copilot" -eq 1 ]; then
		c="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(((.user // {}) | $COPILOT) and .commit_id == \"$head_sha\")] | length")"
	fi
	summary_note=""
	if [ "$want_codex" -eq 1 ]; then
		xr="$(probe_count "repos/$slug/pulls/$pr/reviews" "[.[] | select(.user.login == \"$CODEX_LOGIN\" and .commit_id == \"$head_sha\")] | length")"
		xc="$(probe_count "repos/$slug/issues/$pr/comments" "[.[] | select(.user.login == \"$CODEX_LOGIN\" and .created_at >= \"$T\" and ((.body // \"\") | contains(\"$CODEX_SUMMARY_MARK\") | not))] | length")"
		xt="$(probe_count "repos/$slug/issues/$pr/reactions" "[.[] | select(.user.login == \"$CODEX_LOGIN\" and .content == \"+1\" and .created_at >= \"$T\")] | length")"
		x=$((xr + xc + xt))
		codex_summary="$(codex_summary_state)"
		summary_note=" codex-summary=$codex_summary"
	fi
	echo "$(date -u +%H:%M:%S) copilot=$c codex=$x$summary_note"

	if [ "$want_copilot" -eq 1 ] && [ "$c" -gt "$copilot_seen" ]; then
		[ "$copilot_seen" -ge 1 ] && echo "request-gate-review: another Copilot review of ${head_sha:0:7} arrived ($c in all) — read every one of them (gate-threads.sh status / bodies)"
		copilot_seen="$c"
		settle_left="$copilot_settle"
	fi

	all=1
	if [ "$want_copilot" -eq 1 ]; then
		if [ "$c" -ge 1 ]; then copilot_status=responded; else all=0; fi
	fi
	if [ "$want_codex" -eq 1 ]; then
		if [ "$x" -ge 1 ]; then codex_status=responded; else all=0; fi
	fi

	if [ "$all" -eq 1 ]; then
		[ "$settle_left" -le 0 ] && finish "$(exit_code_for 0)"
		if [ "$settle_said" -eq 0 ]; then
			echo "request-gate-review: every bot has responded; waiting ${settle_left}s more in case Copilot reviews ${head_sha:0:7} again (--copilot-settle)"
			settle_said=1
		fi
		step=$((settle_left < 60 ? settle_left : 60))
	else
		[ "$SECONDS" -ge "$deadline" ] && break
		remaining=$((deadline - SECONDS))
		step=$((remaining < 60 ? remaining : 60))
	fi
	sleep "$step"
	settle_left=$((settle_left > step ? settle_left - step : 0))
done

[ "$want_copilot" -eq 1 ] && [ "$copilot_status" != responded ] && copilot_status=timeout
[ "$want_codex" -eq 1 ] && [ "$codex_status" != responded ] && codex_status=timeout
echo "request-gate-review: timed out waiting for a response" >&2
# What Codex's summary comment says about the current head, when it says
# anything: the cheapest hint at what to do next.
if [ "$codex_status" = timeout ]; then
	summary_sha="${codex_summary#*@}"
	case "$codex_summary" in
		*@*) case "$head_sha" in "$summary_sha"*) ;; *) summary_sha="" ;; esac ;;
		*) summary_sha="" ;;
	esac
	if [ -n "$summary_sha" ]; then
		case "${codex_summary%%@*}" in
			Completed)
				echo "request-gate-review: Codex's summary comment says Completed for $summary_sha, but no review, comment or 👍 of this round was found — look at the PR before asking again" >&2 ;;
			*)
				running_min="$(codex_running_minutes)"
				case "$running_min" in ''|*[!0-9]*) running_min="" ;; esac
				echo "request-gate-review: Codex is still reviewing $summary_sha (its summary comment says ${codex_summary%%@*}${running_min:+, for $running_min min}) — wait again with --wait-only --since $T" >&2
				if [ -n "$running_min" ] && [ "$running_min" -ge "$CODEX_LONG_RUN" ]; then
					echo "request-gate-review: that is over $CODEX_LONG_RUN min. Going on without Codex is reasonable: record it as unconfirmed, and right before the next push run gate-threads.sh status $pr $T again, so that a review landing in between is not missed" >&2
				fi
				;;
		esac
	fi
fi
finish "$(exit_code_for 1)"
