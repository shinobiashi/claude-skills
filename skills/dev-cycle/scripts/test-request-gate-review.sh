#!/usr/bin/env bash
# Scenario tests for request-gate-review.sh using a fake gh and a fake sleep
# (no network, no real PR, no real waiting).
# Usage: bash test-request-gate-review.sh [path/to/request-gate-review.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/request-gate-review.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
check() { # name, then the command that must succeed
	local name="$1"
	shift
	if "$@"; then ok "$name"; else bad "$name"; fi
}

HEAD=1111111111111111111111111111111111111111
OLD=2222222222222222222222222222222222222222
mkdir -p "$W/bin"
LOG="$W/calls.log"

# `sleep` is replaced so the confirmation windows and the wait loop pass
# instantly; every call is logged so a test can assert which waits happened.
cat > "$W/bin/sleep" <<'EOS'
#!/usr/bin/env bash
echo "sleep $*" >> "$FAKE_LOG"
exit 0
EOS

# Fake gh. State lives in $FAKE_STATE:
#   pending   Copilot is in the pending reviewer list (GraphQL and REST)
#   event     a review_requested event exists; content = its timestamp
#   reviews / comments   probe counters ("responds from the nth probe on")
# Knobs (env):
#   FAKE_HEAD              PR head sha
#   FAKE_EDIT_RC           exit status of `gh pr edit` (0)
#   FAKE_EDIT_REGISTERS    1: `gh pr edit` registers the request
#   FAKE_POST_RC           exit status of the REST POST (0)
#   FAKE_POST_REGISTERS    1: the REST POST registers the request
#   FAKE_COMMENT_RC        exit status of `gh pr comment` (0)
#   FAKE_COPILOT_AFTER     nth reviews probe from which a Copilot review of
#                          FAKE_HEAD exists
#   FAKE_COPILOT_STALE     sha: a Copilot review of that other commit exists
#                          from the start
#   FAKE_CODEX_AFTER       nth reviews probe from which a Codex review exists
#   FAKE_CODEX_COMMENT_AFTER  nth comments probe from which a Codex comment exists
#   FAKE_CODEX_SUMMARY     Running | Completed: Codex's "Codex Review Summary" comment
#                          exists from the start, in that state (the real table row)
#   FAKE_CODEX_SUMMARY_SHA commit in that row (default: the first 7 of FAKE_HEAD)
#   FAKE_CODEX_THUMBS      new | old: Codex's 👍 on the PR body, given now or in January
#   FAKE_CI                `gh pr checks` answer from the (FAKE_CI_PENDING+1)th call on:
#                          pass | fail | none (no checks: gh's error) | pending (forever)
#   FAKE_CI_PENDING        number of `gh pr checks` calls that report a check still running
#   FAKE_CI_EARLY_FAIL     1: while pending, another check has already failed
cat > "$W/bin/gh" <<'EOS'
#!/usr/bin/env bash
S="$FAKE_STATE"
log() { echo "gh $*" >> "$FAKE_LOG"; }
count() { local n; n="$(cat "$S/$1" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$S/$1"; echo "$n"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
register() { touch "$S/pending"; now > "$S/event"; }

case "$1 $2" in
	"repo view") echo "o/r"; exit 0 ;;
	"pr view") echo "$FAKE_HEAD"; exit 0 ;;
	"pr checks")
		log "$@"
		n="$(count checks)"
		mode="${FAKE_CI:-pass}"
		[ "$n" -le "${FAKE_CI_PENDING:-0}" ] && mode=pending
		case "$mode" in
			none) echo "no checks reported on the 'feat/x' branch" >&2; exit 1 ;;
			pass) echo '[{"name":"lint","bucket":"pass"},{"name":"test","bucket":"pass"},{"name":"docs","bucket":"skipping"}]'; exit 0 ;;
			fail) echo '[{"name":"lint","bucket":"pass"},{"name":"test","bucket":"fail"}]'; exit 1 ;;
			pending)
				if [ "${FAKE_CI_EARLY_FAIL:-0}" -eq 1 ]; then
					echo '[{"name":"lint","bucket":"fail"},{"name":"test","bucket":"pending"}]'
				else
					echo '[{"name":"lint","bucket":"pass"},{"name":"test","bucket":"pending"}]'
				fi
				exit 8 ;;
		esac ;;
	"pr edit")
		log "$@"
		if [ "${FAKE_EDIT_RC:-0}" -ne 0 ]; then echo "'' not found" >&2; exit "$FAKE_EDIT_RC"; fi
		[ "${FAKE_EDIT_REGISTERS:-0}" -eq 1 ] && register
		echo "https://github.com/o/r/pull/$3"
		exit 0 ;;
	"pr comment")
		cat > /dev/null
		log "$@"
		exit "${FAKE_COMMENT_RC:-0}" ;;
	"api graphql")
		if [ -f "$S/pending" ]; then
			echo '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}}]}}}}}'
		else
			echo '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","slug":"maintainers"}}]}}}}}'
		fi
		exit 0 ;;
	"api -X")
		log "$@"
		if [ "${FAKE_POST_RC:-0}" -ne 0 ]; then echo "HTTP 422" >&2; exit "$FAKE_POST_RC"; fi
		[ "${FAKE_POST_REGISTERS:-0}" -eq 1 ] && register
		if [ -f "$S/pending" ]; then echo '{"requested_reviewers":[{"login":"Copilot","type":"Bot"}]}'; else echo '{"requested_reviewers":[]}'; fi
		exit 0 ;;
	"api --paginate")
		case "$3" in
			*/requested_reviewers)
				if [ -f "$S/pending" ]; then echo '{"users":[{"login":"Copilot","type":"Bot"}],"teams":[]}'; else echo '{"users":[],"teams":[]}'; fi ;;
			*/timeline)
				if [ -f "$S/event" ]; then
					printf '[{"event":"committed"},{"event":"review_requested","requested_reviewer":{"login":"Copilot"},"created_at":"%s"}]\n' "$(cat "$S/event")"
				else
					echo '[{"event":"committed"}]'
				fi ;;
			*/reviews)
				n="$(count reviews)"
				items=""
				[ -n "${FAKE_COPILOT_STALE:-}" ] && items="{\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"commit_id\":\"$FAKE_COPILOT_STALE\",\"submitted_at\":\"$(now)\"}"
				if [ -n "${FAKE_COPILOT_AFTER:-}" ] && [ "$n" -ge "$FAKE_COPILOT_AFTER" ]; then
					items="${items:+$items,}{\"user\":{\"login\":\"copilot-pull-request-reviewer[bot]\"},\"commit_id\":\"$FAKE_HEAD\",\"submitted_at\":\"$(now)\"}"
				fi
				if [ -n "${FAKE_CODEX_AFTER:-}" ] && [ "$n" -ge "$FAKE_CODEX_AFTER" ]; then
					items="${items:+$items,}{\"user\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"commit_id\":\"$FAKE_HEAD\",\"submitted_at\":\"$(now)\"}"
				fi
				echo "[$items]" ;;
			*/comments)
				n="$(count comments)"
				items=""
				if [ -n "${FAKE_CODEX_SUMMARY:-}" ]; then
					items="$(jq -cn --arg st "$FAKE_CODEX_SUMMARY" --arg sha "${FAKE_CODEX_SUMMARY_SHA:-${FAKE_HEAD:0:7}}" --arg now "$(now)" '
						{user: {login: "chatgpt-codex-connector[bot]"}, created_at: $now, updated_at: $now,
						 body: ("<!-- codex-pull-request-review-summary -->\n\n## Codex Review Summary\n\n"
							+ "| Review | Status | Commit | Review trigger |\n| --- | --- | --- | --- |\n"
							+ "| 📝 **Code Review** | "
							+ (if $st == "Running" then "🔄 **Running** since" else "✅ **Completed**" end)
							+ " <relative-time datetime=\"2026-10-06T21:55:21.778548Z\">2026-10-06T21:55:21.778548Z</relative-time> | `"
							+ $sha + "` | Manual request |\n")}')"
				fi
				if [ -n "${FAKE_CODEX_COMMENT_AFTER:-}" ] && [ "$n" -ge "$FAKE_CODEX_COMMENT_AFTER" ]; then
					items="${items:+$items,}{\"user\":{\"login\":\"chatgpt-codex-connector[bot]\"},\"created_at\":\"$(now)\",\"body\":\"Codex Review: Didn't find any major issues.\"}"
				fi
				echo "[$items]" ;;
			*/reactions)
				case "${FAKE_CODEX_THUMBS:-}" in
					new) printf '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"%s"}]\n' "$(now)" ;;
					old) echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-05T00:00:00Z"}]' ;;
					*) echo '[]' ;;
				esac ;;
			*) echo "unexpected gh api call: $*" >&2; exit 99 ;;
		esac
		exit 0 ;;
esac
echo "unexpected gh call: $*" >&2
exit 99
EOS
chmod +x "$W/bin/gh" "$W/bin/sleep"
export PATH="$W/bin:$PATH" FAKE_LOG="$LOG" FAKE_STATE="$W/state" FAKE_HEAD="$HEAD"

# Runs the script with a fresh state. FAKE_PENDING_INITIAL=1 starts with
# Copilot already pending (a leftover request from an earlier round).
run() {
	rm -rf "$W/state"
	mkdir -p "$W/state"
	[ "${FAKE_PENDING_INITIAL:-0}" -eq 1 ] && touch "$W/state/pending"
	: > "$LOG"
	OUT="$("$SCRIPT" "$@" 2>&1)"
	RC=$?
}
calls() { cat "$LOG" 2>/dev/null; }
rc_is() { [ "$RC" -eq "$1" ]; }
has() { echo "$OUT" | grep -q -- "$1"; }
hasnt() { ! has "$1"; }
called() { calls | grep -q -- "$1"; }
not_called() { ! called "$1"; }
call_count() { [ "$(calls | grep -c -- "$1")" -eq "$2" ]; }
call_count_at_least() { [ "$(calls | grep -c -- "$1")" -ge "$2" ]; }
polled() { echo "$OUT" | grep -q '^[0-9:]* copilot='; }
not_polled() { ! polled; }
# $1 appears in the call log before $2 (both must appear).
called_before() {
	local a b
	a="$(calls | grep -n -- "$1" | head -1 | cut -d: -f1)"
	b="$(calls | grep -n -- "$2" | head -1 | cut -d: -f1)"
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

echo "== argument validation (nothing is asked)"
run abc
check "non-numeric PR rejected" rc_is 64
check "non-numeric PR: nothing asked" not_called "gh"
run 5 --copilot-only --codex-only
check "--copilot-only with --codex-only rejected" rc_is 64
run 5 --timeout abc
check "non-numeric --timeout rejected" rc_is 64
run 5 --bogus
check "unknown argument rejected" rc_is 64
run 5 --ci-timeout abc
check "non-numeric --ci-timeout rejected" rc_is 64

echo "== Copilot: gh pr edit registers (the documented CLI path)"
FAKE_EDIT_REGISTERS=1 FAKE_COPILOT_AFTER=2 run 5 --copilot-only --since 2026-09-20T00:00:00Z --timeout 5
check "exit 0 when Copilot reviews the head" rc_is 0
check "requests through gh pr edit --add-reviewer @copilot" called "gh pr edit 5 --add-reviewer @copilot"
check "confirmed by the pending list transition" has "confirmed (pending reviewer list (absent before the request))"
check "REST not tried after a confirmed gh pr edit" not_called "api -X POST"
check "Codex not asked on a Copilot-only turn" not_called "pr comment"
check "T is the --since value" has "^T=2026-09-20T00:00:00Z$"
check "COPILOT=responded" has "^COPILOT=responded$"
check "CODEX=not-waited" has "^CODEX=not-waited$"
check "DONE on success" has "^DONE$"

echo "== Copilot: gh pr edit fails (cli/cli#11245 style) -> REST fallback with the documented login"
FAKE_EDIT_RC=1 FAKE_POST_REGISTERS=1 FAKE_COPILOT_AFTER=1 run 5 --copilot-only --timeout 5
check "exit 0 via the REST fallback" rc_is 0
check "REST uses reviewers[]=copilot-pull-request-reviewer[bot]" called "requested_reviewers -f reviewers\[\]=copilot-pull-request-reviewer\[bot\]"
check "the undocumented login Copilot is never used" not_called "reviewers\[\]=Copilot$"
check "the gh pr edit failure is reported with its message" has "gh pr edit --add-reviewer @copilot failed (exit 1): '' not found"
check "REST request confirmed" has "confirmed (pending reviewer list"

echo "== Copilot: gh pr edit accepted but never registers -> REST registers"
FAKE_POST_REGISTERS=1 FAKE_COPILOT_AFTER=11 run 5 --copilot-only --timeout 5
check "exit 0 after the REST retry" rc_is 0
check "explains why REST was tried" has "nothing confirms the gh pr edit request after 90s"
check "waited the 90s window (9 x 10s) before falling back" call_count_at_least "sleep 10" 9
check "gh pr edit is tried before REST" called_before "pr edit" "api -X POST"

echo "== Copilot: registered, but the only evidence (a review) appears after both windows -> confirmed in the grace period"
FAKE_COPILOT_AFTER=21 run 5 --copilot-only --timeout 5
check "exit 0" rc_is 0
check "late evidence is accepted instead of declaring the request unregistered" has "confirmed late (review of $HEAD)"
check "COPILOT=responded" has "^COPILOT=responded$"

echo "== Copilot: neither method registers -> exit 2 after the 5-minute confirmation budget, no response wait"
run 5 --copilot-only --since 2026-09-20T00:00:00Z --timeout 5
check "exit 2 when nothing registers" rc_is 2
check "COPILOT=unregistered" has "^COPILOT=unregistered$"
check "no response wait with nothing registered" not_polled
check "no DONE on exit 2" hasnt "^DONE$"
check "announces the grace period" has "polling for evidence for another 120s"
check "tells how to wait after a manual request" has "request-gate-review.sh 5 --wait-only --since 2026-09-20T00:00:00Z --copilot-only"
check "waited 90s + 90s + 120s grace (30 x 10s)" call_count "sleep 10" 30
check "no other wait happened" not_called "sleep [^1]"

echo "== parallel: Copilot unregistered but Codex responds"
FAKE_CODEX_COMMENT_AFTER=1 run 5 --request-codex --timeout 5
check "exit 2 (a request did not register) after Codex responded" rc_is 2
check "CODEX=responded" has "^CODEX=responded$"
check "COPILOT=unregistered" has "^COPILOT=unregistered$"
check "no DONE when a request never registered" hasnt "^DONE$"
check "Codex is asked before Copilot's confirmation starts" called_before "pr comment" "pr edit"

echo "== --wait-only: nothing is requested"
FAKE_COPILOT_AFTER=1 FAKE_CODEX_AFTER=1 run 5 --wait-only --request-codex --since 2026-09-20T00:00:00Z --timeout 5
check "exit 0 when both respond" rc_is 0
check "--wait-only does not run gh pr edit" not_called "pr edit"
check "--wait-only does not POST" not_called "api -X"
check "--wait-only does not post @codex review" not_called "pr comment"
check "COPILOT=responded" has "^COPILOT=responded$"
check "CODEX=responded" has "^CODEX=responded$"
check "DONE" has "^DONE$"

echo "== stale review of another commit is not a response"
FAKE_EDIT_REGISTERS=1 FAKE_COPILOT_STALE="$OLD" run 5 --copilot-only --timeout 1
check "exit 1 (timeout) when only a stale review exists" rc_is 1
check "COPILOT=timeout" has "^COPILOT=timeout$"
check "timeout reported" has "timed out waiting for a response"

echo "== Codex: posting @codex review fails twice"
FAKE_COMMENT_RC=1 run 5 --codex-only --request-codex --timeout 5
check "exit 2 when the Codex request could not be posted" rc_is 2
check "CODEX=request-failed" has "^CODEX=request-failed$"
check "two attempts were made" call_count "pr comment" 2
check "no wait for an unasked Codex" not_polled

echo "== Codex: auto-review repository (no --request-codex)"
FAKE_CODEX_AFTER=1 run 5 --codex-only --timeout 5
check "exit 0 on Codex's review of the head" rc_is 0
check "no @codex review without --request-codex" not_called "pr comment"

echo "== Codex: the no-findings note (issue comment after T) counts"
FAKE_CODEX_COMMENT_AFTER=1 run 5 --codex-only --request-codex --timeout 5
check "exit 0" rc_is 0
check "CODEX=responded" has "^CODEX=responded$"

echo "== Codex: the Running summary comment is not a response (saai-pi4t PR #5 / #6 G1)"
FAKE_CODEX_SUMMARY=Running run 5 --codex-only --request-codex --timeout 1
check "exit 1 (timeout) while the summary only says Running" rc_is 1
check "CODEX=timeout" has "^CODEX=timeout$"
check "the poll line shows the summary state" has "codex=0 codex-summary=Running@${HEAD:0:7}"
check "the timeout says Codex is still reviewing the head" has "Codex is still reviewing ${HEAD:0:7}"

FAKE_CODEX_SUMMARY=Running FAKE_CODEX_AFTER=2 run 5 --codex-only --request-codex --timeout 120
check "Running summary, then a review of the head: exit 0" rc_is 0
check "CODEX=responded" has "^CODEX=responded$"
check "waited for the review (two polls)" call_count "sleep 60" 1

FAKE_CODEX_SUMMARY=Completed run 5 --codex-only --request-codex --timeout 1
check "a Completed summary alone is not a response (exit 1)" rc_is 1
check "the timeout points at the missing review, comment or thumbs-up" has "says Completed for ${HEAD:0:7}, but"

FAKE_CODEX_SUMMARY=Running FAKE_CODEX_SUMMARY_SHA="${OLD:0:7}" run 5 --codex-only --request-codex --timeout 1
check "a summary about another commit is not called a review of the head" hasnt "still reviewing"

echo "== Codex: a thumbs-up on the PR body after T counts (its no-findings sign)"
FAKE_CODEX_THUMBS=new run 5 --codex-only --request-codex --timeout 5
check "exit 0" rc_is 0
check "CODEX=responded" has "^CODEX=responded$"

FAKE_CODEX_THUMBS=old run 5 --codex-only --request-codex --since 2026-09-20T00:00:00Z --timeout 1
check "a thumbs-up from before T is an earlier round (exit 1)" rc_is 1

echo "== Copilot already pending before the run (leftover request)"
FAKE_PENDING_INITIAL=1 FAKE_EDIT_REGISTERS=1 FAKE_COPILOT_AFTER=30 run 5 --copilot-only --timeout 5
check "exit 0 once the review arrives" rc_is 0
check "warns that presence cannot confirm" has "already listed as pending"
check "confirmed by the post-request timeline event, not by presence" has "confirmed (timeline event)"

FAKE_PENDING_INITIAL=1 FAKE_EDIT_RC=1 FAKE_COPILOT_AFTER=40 run 5 --copilot-only --timeout 5
check "leftover pending + accepted REST re-request: exit 0 on the review" rc_is 0
check "explains why the unconfirmed re-request is waited on" has "already pending before this run and the re-request was accepted"
check "COPILOT=responded" has "^COPILOT=responded$"

echo "== --wait-ci: checks finish green, then the request goes out"
FAKE_CI_PENDING=2 FAKE_EDIT_REGISTERS=1 FAKE_COPILOT_AFTER=2 run 5 --copilot-only --wait-ci --timeout 5
check "exit 0" rc_is 0
check "CI=passed" has "^CI=passed$"
check "polled the checks until none was pending (3 calls)" call_count "pr checks" 3
check "waited 20s between CI polls" call_count "sleep 20" 2
check "the checks are waited on before Copilot is asked" called_before "pr checks" "pr edit"
check "a skipped check does not hold the wait" has "CI passed (3 checks)"
check "DONE" has "^DONE$"

echo "== --wait-ci: a failed check stops the run before any request"
FAKE_CI=fail FAKE_CI_PENDING=1 run 5 --request-codex --wait-ci --timeout 5
check "exit 3" rc_is 3
check "CI=failed" has "^CI=failed$"
check "names the failed check" has "test (fail)"
check "Copilot is not asked" not_called "pr edit"
check "Codex is not asked" not_called "pr comment"
check "no response wait" not_polled
check "no DONE" hasnt "^DONE$"

echo "== --wait-ci: a failure while other checks still run stops at once"
FAKE_CI=pending FAKE_CI_EARLY_FAIL=1 run 5 --copilot-only --wait-ci
check "exit 3" rc_is 3
check "CI=failed" has "^CI=failed$"
check "one poll, no wait for the pending check" call_count "pr checks" 1
check "no CI sleep" not_called "sleep 20"

echo "== --wait-ci: no check ever appears -> exit 3 (not reported as passed)"
FAKE_CI=none run 5 --copilot-only --wait-ci
check "exit 3" rc_is 3
check "CI=none" has "^CI=none$"
check "gh's own message is shown" has "no checks reported"
check "gave up after the 180s appear budget (9 x 20s)" call_count "sleep 20" 9
check "Copilot is not asked" not_called "pr edit"

echo "== --ci-timeout: checks still running -> exit 3"
FAKE_CI=pending run 5 --copilot-only --ci-timeout 40
check "exit 3" rc_is 3
check "CI=timeout" has "^CI=timeout$"
check "--ci-timeout implies --wait-ci and bounds the wait (2 x 20s)" call_count "sleep 20" 2
check "Copilot is not asked" not_called "pr edit"

echo "== without --wait-ci the checks are not looked at"
FAKE_EDIT_REGISTERS=1 FAKE_COPILOT_AFTER=1 run 5 --copilot-only --timeout 5
check "gh pr checks is not called" not_called "pr checks"
check "CI=not-waited" has "^CI=not-waited$"

echo "== T defaults to now when --since is absent"
FAKE_EDIT_REGISTERS=1 FAKE_COPILOT_AFTER=1 run 5 --copilot-only --timeout 5
iso_t() { echo "$OUT" | grep -Eq '^T=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; }
check "T printed in ISO 8601 UTC" iso_t

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
