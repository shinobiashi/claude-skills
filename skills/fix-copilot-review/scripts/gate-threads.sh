#!/usr/bin/env bash
#
# Helper for the fix-copilot-review skill (and any other workflow that needs
# to fetch, reply to, and resolve GitHub PR review threads — dev-cycle's gate
# rounds use it too).
#
# Bundles fetching, replying to, and resolving unresolved review threads.
# Hand-written GraphQL + `gh` glue for this tends to trip on the same three
# things every time:
#
#   1. `gh pr comment --body "...(...)..."` breaks on zsh/bash parsing
#      -> the body is only ever read from a file (or stdin)
#   2. reply and resolve used to take independently-supplied IDs, and mixing
#      up threads silently replied to one and closed another
#      -> reply/done now take a single thread ID and derive everything else
#   3. more than 50 threads need pagination
#      -> list walks every page
#
# Usage:
#   gate-threads.sh list <PR> [SINCE_ISO8601]           print unresolved threads as TSV
#   gate-threads.sh show <THREAD_ID>                    print one thread's full body
#   gate-threads.sh status <PR> [SINCE_ISO8601]         count unresolved threads per bot,
#                                                       plus Copilot review bodies to read
#   gate-threads.sh bodies <PR> [SINCE_ISO8601]         print Copilot review bodies of the current
#                                                       head (URL, verdict headline, Suppressed
#                                                       comments, and any File summaries table
#                                                       cell with a bold severity marker)
#   gate-threads.sh reply <PR> <THREAD_ID> <BODY_FILE|-> reply to a thread
#   gate-threads.sh done <PR> <THREAD_ID> <BODY_FILE|->  reply, then resolve
#
#   --dry-run prints what a write command would do instead of doing it.
#
# Use `done` for findings you fixed, `reply` for findings you left open.
# `done` will not resolve if the reply fails, so a thread is never closed
# without an explanation. There is no standalone resolve command, because
# that would let a thread be closed without a reply.
#
# Copilot does not always open a thread per finding: a "Needs a closer look"
# or "Changes recommended" review can carry its findings only in the review
# body (the headline sentence and a "Suppressed comments" section) with
# zero inline threads (seen repeatedly in real PRs). A finding can also live
# inside a "File summaries" table cell as a bold severity marker
# (`**Moderate (1 vote):** ...`) with nothing in Suppressed comments at all
# (PR #60's G1 round) — `bodies` keeps those cells instead of stripping the
# whole table as noise. `bodies` prints all of this so a round can judge it
# like threads; `status` counts how many such reviews arrived since SINCE so
# a "0 new threads" round is not mistaken for convergence.
#
# `list` / `status` / `bodies` depend on `jq` (not bundled with `gh`).
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
	sed -n '3,44p' "$0" | sed 's/^# \{0,1\}//'
	exit 64
}

[ $# -ge 1 ] || usage

repo_slug() {
	gh repo view --json nameWithOwner --jq '.nameWithOwner'
}

require_jq() {
	command -v jq >/dev/null 2>&1 || {
		echo "gate-threads: jq is required but was not found on PATH" >&2
		exit 69
	}
}

# Prints unresolved threads as TSV. SINCE, if given, restricts the output to
# threads whose first comment came at or after it (this round's new
# findings) — always pass it, since threads left open from a previous round
# are already judged. The cutoff is inclusive: SINCE is the push time at
# second precision, and a bot comment in that same second still belongs to
# this round. Does not include the comment body (use `show` for that).
cmd_list() {
	local pr="${1:?PR number required}" since="${2:-}"
	local slug owner repo cursor="null" page rc

	require_jq
	slug="$(repo_slug)"
	owner="${slug%%/*}"
	repo="${slug##*/}"

	printf 'thread_id\tauthor\tpath\tline\turl\n'

	while :; do
		# A failing `gh` here would otherwise go unnoticed: this function runs
		# inside `cmd_status`'s `rows="$(cmd_list ...)"`, and bash does not
		# apply -e to a command substitution assigned to a variable, so a
		# failure here would silently fall through to the next line instead
		# of aborting. Check the exit status by hand instead.
		page="$(gh api graphql -f query='
			query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
			  repository(owner: $owner, name: $repo) {
			    pullRequest(number: $pr) {
			      reviewThreads(first: 50, after: $cursor) {
			        pageInfo { hasNextPage endCursor }
			        nodes {
			          id isResolved path line
			          comments(first: 1) {
			            nodes { author { login } createdAt url }
			          }
			        }
			      }
			    }
			  }
			}' -F owner="$owner" -F repo="$repo" -F pr="$pr" -F cursor="$cursor" --jq '.data.repository.pullRequest.reviewThreads')"
		rc=$?
		[ "$rc" -eq 0 ] || { echo "gate-threads: gh api graphql failed (exit $rc)" >&2; return "$rc"; }

		jq -r --arg since "$since" '
			.nodes[]
			| select(.isResolved == false)
			| .c = .comments.nodes[0]
			| select($since == "" or .c.createdAt >= $since)
			| [ .id, .c.author.login, (.path // "-"), (.line // "-" | tostring), .c.url ]
			| @tsv
		' <<<"$page"

		[ "$(jq -r '.pageInfo.hasNextPage' <<<"$page")" = "true" ] || break
		cursor="$(jq -r '.pageInfo.endCursor' <<<"$page")"
	done
}

cmd_show() {
	local thread_id="${1:?thread node id required}"

	gh api graphql -f query='
		query($id: ID!) {
		  node(id: $id) {
		    ... on PullRequestReviewThread {
		      isResolved path line
		      comments(first: 10) {
		        nodes { databaseId author { login } createdAt url body }
		      }
		    }
		  }
		}' -F id="$thread_id" --jq '.data.node'
}

# Copilot reviews of the PR's current head submitted after SINCE, as JSON
# lines ({id, url, submitted_at, commit, headline, has_findings, body}).
# Filtered by commit_id as well as time, for the same reason the gate wait matches
# responses by commit: a delayed review of an *older* push can land after
# SINCE and would otherwise count as this round's findings.
# `headline` is the verdict line ("### 🟡 Changes recommended");
# `has_findings` is true when the body carries a Suppressed comments section,
# a "Previously missed (N)" section, a non-approving verdict, or a bold severity
# marker inside a File summaries table cell (`**Moderate (1 vote):**`,
# `**Critical:**`, ...) — the last two can appear even on a review whose only
# verdict text reads as neutral, i.e. when there is something a round must read
# even with zero threads. "Previously missed" is a top-level section of the v2
# layout (`<!-- ccr-overview-v2 -->`, next to "Open (N)" / "Resolved since last
# review" / "What changed in this PR"): findings in code that has not changed
# since the last review, with no inline thread, and it can sit under an approving
# headline ("🟢 Approval recommended") that the verdict test alone would miss.
# `--paginate` pages are flattened with `jq -s`.
# A review with no summary body has `body: null`; it is normalized to ""
# so the parsing never aborts the whole listing.
copilot_reviews() {
	local pr="${1:?PR number required}" since="${2:-}" slug head_sha

	require_jq
	slug="$(repo_slug)"
	head_sha="$(gh pr view "$pr" --json headRefOid --jq '.headRefOid')"

	gh api --paginate "repos/$slug/pulls/$pr/reviews" | jq -c -s --arg since "$since" --arg head "$head_sha" '
		[.[][]]
		| .[]
		| select(.user.login == "copilot-pull-request-reviewer[bot]")
		| select(.commit_id == $head)
		| select($since == "" or .submitted_at >= $since)
		| .body = (.body // "")
		| {
			id,
			url: .html_url,
			submitted_at,
			commit: .commit_id[0:7],
			headline: ((.body | [match("###[^\n]*")] | .[0].string) // "(no headline)"),
			has_findings: ((.body | test("Suppressed comments \\(")) or (.body | test("Previously missed \\(")) or (.body | test("Changes recommended|Needs a closer look")) or (.body | test("\\*\\*(Critical|High|Moderate|Medium|Minor|Low)( \\(\\d+ votes?\\))?:\\*\\*"))),
			body
		}'
}

# Prints each Copilot review body (current head, since SINCE) with the HTML
# and the merely-cosmetic file summary table rows stripped, so the verdict,
# its sentence and the Suppressed comments read like a thread. A table row
# that itself carries a finding as a bold severity marker
# (`**Moderate (1 vote):** ...`) is kept — PR #60's G1 round had real
# findings living only there, with nothing in Suppressed comments, and a
# blanket `grep -v '^|'` silently discarded them. The review URL is printed
# so a body-only finding can be cited in G<n>.md, where a thread URL would go.
# Zero-width spaces (U+200B) that Copilot inserts into file paths are removed
# so a finding's `path:line` can be matched against a thread's path.
cmd_bodies() {
	local pr="${1:?PR number required}" since="${2:-}" line

	copilot_reviews "$pr" "$since" | while IFS= read -r line; do
		jq -r '"=== review \(.id) \(.submitted_at) \(.commit) has_findings=\(.has_findings) ===\n\(.url)"' <<<"$line"
		jq -r '.body' <<<"$line" \
			| sed -e 's/<[^>]*>//g' -e $'s/\xe2\x80\x8b//g' \
			| grep -v -e 'Get a fresh assessment' -e '^💡' -e '^[[:space:]]*$' \
			| awk '!/^\|/ || /\*\*(Critical|High|Moderate|Medium|Minor|Low)( \([0-9]+ votes?\))?:\*\*/' \
			|| true
		echo
	done
}

cmd_status() {
	local pr="${1:?PR number required}" since="${2:-}"
	local rows bodies

	rows="$(cmd_list "$pr" "$since")" || { echo "gate-threads: failed to list threads" >&2; return 1; }

	printf '%s\n' "$rows" | tail -n +2 | awk -F'\t' '
		{ n[$2]++; total++ }
		END {
			for ( a in n ) printf "%-34s %d\n", a, n[a]
			printf "%-34s %d\n", "(unresolved total)", total + 0
		}
	'

	bodies="$(copilot_reviews "$pr" "$since" | jq -s '{ reviews: length, with_findings: (map(select(.has_findings)) | length) }')" || { echo "gate-threads: failed to read Copilot reviews" >&2; return 1; }
	printf '%-34s %s\n' "copilot review bodies (head, since)" "$(jq -r '"\(.reviews) reviews, \(.with_findings) with findings to read — see: bodies"' <<<"$bodies")"
}

read_body() {
	local source="${1:?body file or - required}"

	if [ "$source" = "-" ]; then
		cat
	else
		[ -f "$source" ] || { echo "gate-threads: no such body file: $source" >&2; exit 66; }
		cat "$source"
	fi
}

# The REST replies endpoint targets a specific review comment, so this looks
# up the thread's first comment and replies to that — the caller only ever
# has to name the thread, which is what `done` resolves too.
thread_first_comment_id() {
	local thread_id="${1:?thread node id required}"

	gh api graphql -f query='
		query($id: ID!) {
		  node(id: $id) {
		    ... on PullRequestReviewThread {
		      comments(first: 1) { nodes { databaseId } }
		    }
		  }
		}' -F id="$thread_id" --jq '.data.node.comments.nodes[0].databaseId'
}

cmd_reply() {
	local pr="${1:?PR number required}" thread_id="${2:?thread node id required}" source="${3:?body file or - required}"
	local body slug comment_id

	body="$(read_body "$source")"
	[ -n "${body//[[:space:]]/}" ] || { echo "gate-threads: refusing to post an empty reply" >&2; exit 65; }

	if [ "$DRY_RUN" = "1" ]; then
		printf 'would reply to thread %s on PR #%s:\n%s\n' "$thread_id" "$pr" "$body"
		return 0
	fi

	slug="$(repo_slug)"
	comment_id="$(thread_first_comment_id "$thread_id")"

	gh api "repos/$slug/pulls/$pr/comments/$comment_id/replies" -f body="$body" --jq '.html_url'
}

# Not exposed as a top-level command: always called from `cmd_done`, so a
# thread can never be resolved without a reply having gone out first.
cmd_resolve() {
	local thread_id="${1:?thread node id required}" resolved

	if [ "$DRY_RUN" = "1" ]; then
		printf 'would resolve thread %s\n' "$thread_id"
		return 0
	fi

	resolved="$(gh api graphql -f query='
		mutation($id: ID!) {
		  resolveReviewThread(input: { threadId: $id }) { thread { isResolved } }
		}' -F id="$thread_id" --jq '.data.resolveReviewThread.thread.isResolved')"

	[ "$resolved" = "true" ] || { echo "gate-threads: thread $thread_id is still unresolved" >&2; exit 70; }

	printf 'resolved %s\n' "$thread_id"
}

# For findings you fixed. Does not resolve if the reply fails, so a thread is
# never closed without an explanation.
cmd_done() {
	local pr="${1:?PR number required}" thread_id="${2:?thread node id required}" source="${3:?body file or - required}"
	local body

	body="$(read_body "$source")"

	cmd_reply "$pr" "$thread_id" - <<<"$body"
	cmd_resolve "$thread_id"
}

case "$1" in
	list) shift; cmd_list "$@" ;;
	show) shift; cmd_show "$@" ;;
	status) shift; cmd_status "$@" ;;
	bodies) shift; cmd_bodies "$@" ;;
	reply) shift; cmd_reply "$@" ;;
	done) shift; cmd_done "$@" ;;
	*) usage ;;
esac
