#!/usr/bin/env bash
# Scenario tests for inventory.py with a fake gh (no network). The fixtures keep the shapes that
# `gh pr view --json` and the Actions REST API returned for saai-inventory's PRs #43-#55.
# Usage: bash test-inventory.sh [path/to/inventory.py]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/inventory.py}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; printf '%s\n' "${OUT:-}" | sed 's/^/         | /'; }
run() { OUT="$(python3 "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; fi; }
hasnt() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then bad "$1 (unexpected line: $2)"; else ok "$1"; fi; }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; fi; }

FX="$W/fx"
mkdir -p "$W/bin" "$FX"

# Answers from $FX/<key>, where the key is the arguments with every odd character made a dash.
cat >"$W/bin/gh" <<'EOF'
#!/bin/sh
[ -z "${GH_FAIL:-}" ] || { echo "gh: authentication required" >&2; exit 1; }
key="$(printf '%s' "$*" | tr -c 'A-Za-z0-9._-' '-')"
if [ -f "$FX/$key" ]; then
    cat "$FX/$key"
    exit 0
fi
echo "no fixture: $key ($*)" >>"$FX/.misses"
exit 1
EOF
chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH" FX

fx() { # fx "gh args" < content
    local key
    key="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')"
    cat >"$FX/$key"
}

python3 - "$FX" <<'PY'
import json, re, sys
fx = sys.argv[1]
BOT = [{"login": "dependabot[bot]", "name": "dependabot[bot]"}]
HUMAN = [{"login": "maintainer", "name": "A Maintainer"}]
FIELDS = "number,title,author,state,headRefName,headRefOid,mergeable,mergeStateStatus,additions,deletions,files,commits,body,createdAt,reviews"

def key(args):
    return re.sub(r"[^A-Za-z0-9._-]", "-", args)

def put(args, value):
    with open(f"{fx}/{key(args)}", "w") as handle:
        handle.write(value if isinstance(value, str) else json.dumps(value))

def meta(*deps):
    lines = ["Bump", "", "---", "updated-dependencies:"]
    for name, version, kind, update, *group in deps:
        lines += [f"- dependency-name: {json.dumps(name)}", f"  dependency-version: {version}",
                  f"  dependency-type: direct:{kind}", f"  update-type: version-update:semver-{update}"]
        if group:
            lines.append(f"  dependency-group: {group[0]}")
    return "\n".join(lines + ["...", "", "Signed-off-by: dependabot[bot] <support@github.com>"])

def pr(n, title, branch, commits, files=("package.json",), body="", head=None, created="2999-01-01T00:00:00Z", reviews=()):
    head = head or f"{n:040d}"
    put(f"pr view {n} --json {FIELDS}", {
        "number": n, "title": title, "author": {"login": "app/dependabot"}, "state": "OPEN", "headRefName": branch,
        "headRefOid": head, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "additions": 1, "deletions": 1,
        "createdAt": created, "reviews": [{"author": {"login": who}} for who in reviews],
        "files": [{"path": f} for f in files], "commits": commits, "body": body,
    })
    return head

def bot(message, oid="b" * 40, headline="bump"):
    return {"oid": oid, "authors": BOT, "messageHeadline": headline, "messageBody": message}

def run(rid, branch, head, conclusion="success", attempt=1, path=".github/workflows/ci.yml", status="completed", created="2026-11-05T00:00:00Z"):
    return {"id": rid, "path": path, "head_sha": head, "conclusion": conclusion, "run_attempt": attempt, "status": status, "created_at": created}

def runs(branch, *items):
    put(f"api repos/o/r/actions/runs?branch={branch}&per_page=50", {"workflow_runs": list(items)})

def steps(*items):
    return [{"name": name, "conclusion": conclusion} for name, conclusion in items]

def jobs(rid, *items, attempt=None):
    path = f"api repos/o/r/actions/runs/{rid}/" + (f"attempts/{attempt}/jobs?per_page=100" if attempt else "jobs?filter=latest&per_page=100")
    put(path, {"jobs": [{"name": name, "conclusion": conclusion, "steps": stps} for name, conclusion, stps in items]})

GREEN_E2E = steps(("Set up job", "success"), ("Run E2E tests", "success"), ("Upload Playwright report", "skipped"), ("Notify on failure", "skipped"), ("Post Checkout", "success"), ("Complete job", "success"))
GREEN_JS = steps(("ESLint", "success"), ("Jest (unit)", "success"), ("Build", "success"))
FLAKE_LOG = (
    "JS\tJest (unit)\t2026-11-05T00:47:36.8753707Z   \x1b[1m● PoList › shows an error notice\x1b[22m\n"
    "JS\tJest (unit)\t2026-11-05T00:47:37.8796830Z ##[error]Error: Found multiple elements with the text: Nope\n"
    "JS\tJest (unit)\t2026-11-05T00:47:37.8796999Z ##[error]Process completed with exit code 1.\n"
    "JS\tJest (unit)\t2026-11-05T00:47:37.8908937Z Tests:       1 failed, 238 passed, 239 total\n"
)

put("repo view --json nameWithOwner", {"nameWithOwner": "o/r"})
put("api repos/o/r/actions/workflows?per_page=100", {"workflows": [
    {"path": ".github/workflows/ci.yml", "state": "active"},
    {"path": ".github/workflows/release.yml", "state": "active"},
    {"path": ".github/workflows/old.yml", "state": "disabled_manually"},
    {"path": "dynamic/dependabot/dependabot-updates", "state": "active"},
]})
put("pr list --state open --author app/dependabot --limit 100 --json number", [{"number": n} for n in (7, 1, 2, 3, 4, 5, 6)])

# #1: an action that only a failure-only step uses. CI cannot have run it.
b1 = "dependabot/github_actions/actions/upload-artifact-7"
h1 = pr(1, "ci: bump actions/upload-artifact from 4 to 7", b1,
        [bot(meta(("actions/upload-artifact", "'7'", "production", "major")))], files=(".github/workflows/ci.yml",))
runs(b1, run(11, b1, h1))
jobs(11, ("JS", "success", GREEN_JS), ("E2E", "success", GREEN_E2E))
workflow = """name: CI
jobs:
  e2e:
    steps:
      - name: Run E2E tests
        run: npm run test:e2e

      - name: Upload Playwright report
        uses: actions/upload-artifact@v7
        if: failure()
        with:
          name: playwright-report
          path: playwright-report/
"""
put(f"api -H Accept: application/vnd.github.raw repos/o/r/contents/.github/workflows/ci.yml?ref={h1}", workflow)

# #2: runtime major, green only on the second attempt.
b2 = "dependabot/npm_and_yarn/wordpress/url-5.0.0"
h2 = pr(2, "chore(deps): bump @wordpress/url from 4.53.0 to 5.0.0", b2,
        [bot(meta(("@wordpress/url", "5.0.0", "production", "major")))],
        body="Bumps [@wordpress/url](https://github.com/WordPress/gutenberg) from 4.53.0 to 5.0.0.")
runs(b2, run(21, b2, h2, attempt=2))
jobs(21, ("JS", "success", GREEN_JS))
jobs(21, ("JS", "failure", steps(("ESLint", "success"), ("Jest (unit)", "failure"), ("Build", "skipped"), ("Post Set up Node", "skipped"))), attempt=1)
put("run view 21 --attempt 1 --log-failed", FLAKE_LOG)

# #3: tool major that is red now, with steps it never reached, and the same failure as #2.
b3 = "dependabot/npm_and_yarn/wordpress/scripts-37.0.0"
h3 = pr(3, "chore(deps-dev): bump @wordpress/scripts from 30.27.0 to 37.0.0", b3,
        [bot(meta(("@wordpress/scripts", "37.0.0", "development", "major")))])
runs(b3, run(31, b3, h3, conclusion="failure"))
jobs(31, ("JS", "failure", steps(("ESLint", "failure"), ("Stylelint", "skipped"), ("Jest (unit)", "skipped"), ("Post Set up Node", "skipped"))))
put("run view 31 --attempt 1 --log-failed", FLAKE_LOG + "JS\tESLint\t2026-11-05T00:51:09.3168208Z ##[error]  172:6  error  Replace `··` with `↹`  prettier/prettier\n")

# #4: edited by a person, stacked on another Dependabot commit, red on its older head.
b4 = "dependabot/npm_and_yarn/wordpress/i18n-7.0.0"
h4 = pr(4, "chore(deps): bump @wordpress/i18n from 5.26.0 to 7.0.0", b4, [
    bot(meta(("@wordpress/date", "6.0.0", "production", "major")), oid="c" * 40),
    bot(meta(("@wordpress/i18n", "7.0.0", "production", "major")), oid="d" * 40),
    {"oid": "e" * 40, "authors": HUMAN, "messageHeadline": "fix: typed sprintf", "messageBody": ""},
    {"oid": "f" * 40, "authors": HUMAN + BOT[:0], "messageHeadline": "Merge main", "messageBody": ""},
])
runs(b4, run(41, b4, h4, created="2026-11-07T00:00:00Z"), run(42, b4, "9" * 40, conclusion="failure", created="2026-11-05T00:00:00Z"))
jobs(41, ("JS", "success", GREEN_JS))
jobs(42, ("JS", "failure", steps(("TypeScript", "failure"), ("Jest (unit)", "skipped"), ("Build", "skipped"))))

# #5: a group of minors, with no run at all on its head and logs that have expired.
b5 = "dependabot/composer/composer-dev-c8c4aeca27"
h5 = pr(5, "chore(deps-dev): bump the composer-dev group with 2 updates", b5, [bot(meta(
    ("phpunit/phpunit", "9.6.38", "development", "patch", "composer-dev"),
    ("smalot/pdfparser", "2.13.1", "development", "minor", "composer-dev")))],
    body="Updates `phpunit/phpunit` from 9.6.36 to 9.6.38\nUpdates `smalot/pdfparser` from 2.12.5 to 2.13.1\n",
    created="2020-01-01T00:00:00Z")
runs(b5)

# #6: a major of something that runs the suites, not a linter.
b6 = "dependabot/npm_and_yarn/wordpress/e2e-test-utils-playwright-3.2.0"
h6 = pr(6, "chore(deps-dev): bump @wordpress/e2e-test-utils-playwright from 1.53.0 to 3.2.0", b6,
        [bot(meta(("@wordpress/e2e-test-utils-playwright", "3.2.0", "development", "major")))])
runs(b6, run(61, b6, h6))
jobs(61, ("JS", "success", GREEN_JS))

# #7: a person's own PR in the batch, and a run still going.
b7 = "fix/flaky-test"
h7 = pr(7, "test: stop the live region from failing queries", b7,
        [{"oid": "a" * 40, "authors": HUMAN, "messageHeadline": "test: fix", "messageBody": ""}],
        reviews=("copilot-pull-request-reviewer",))
runs(b7, run(71, b7, h7, conclusion=None, status="in_progress"))
jobs(71, ("JS", None, steps(("ESLint", None))))

# #8: an action that a tag-only job uses (the job is skipped as a whole, with no steps), and a
# matrix step whose name the run shows with the value filled in.
b8 = "dependabot/github_actions/softprops/action-gh-release-3"
h8 = pr(8, "ci: bump softprops/action-gh-release from 2 to 3", b8,
        [bot(meta(("softprops/action-gh-release", "'3'", "production", "major")))], files=(".github/workflows/ci.yml",))
runs(b8, run(81, b8, h8))
jobs(81, ("php (8.3)", "success", steps(("Notes on 8.3", "success"))),
     ("release", "skipped", []))
put(f"api -H Accept: application/vnd.github.raw repos/o/r/contents/.github/workflows/ci.yml?ref={h8}", """name: CI
jobs:
  php:
    strategy:
      matrix:
        php: ['8.3']
    steps:
      - name: Notes on ${{ matrix.php }}
        uses: softprops/action-gh-release@v3
  release:
    if: startsWith(github.ref, 'refs/tags/')
    steps:
      - name: Publish the release
        uses: softprops/action-gh-release@v3
""")

# #9: jobs that `needs:` a failed job never start, so they have no steps at all.
b9 = "dependabot/npm_and_yarn/lodash-5.0.0"
h9 = pr(9, "chore(deps): bump lodash from 4.17.21 to 5.0.0", b9, [bot(meta(("lodash", "5.0.0", "production", "major")))])
runs(b9, run(91, b9, h9, conclusion="failure"))
jobs(91, ("lint", "failure", steps(("ESLint", "failure"))), ("test", "skipped", []), ("build", "skipped", []))
put("run view 91 --attempt 1 --log-failed", "")

# #10: `on: [push, pull_request]` runs the workflow twice on one head; the red one counts.
b10 = "dependabot/npm_and_yarn/foo-2.0.0"
h10 = pr(10, "chore(deps-dev): bump foo from 1.0.0 to 2.0.0", b10, [bot(meta(("foo", "2.0.0", "development", "major")))])
runs(b10, dict(run(101, b10, h10, conclusion="failure"), event="push"),
     dict(run(102, b10, h10, created="2026-11-05T00:01:00Z"), event="pull_request"))
jobs(101, ("JS", "failure", steps(("ESLint", "failure"), ("Build", "skipped"))))
jobs(102, ("JS", "success", GREEN_JS))
put("run view 101 --attempt 1 --log-failed", "")
PY

echo "inventory.py"

run 1 2 3 4 5 6 7
status "reads the batch" 0
if [ -f "$FX/.misses" ]; then echo "  (unexpected gh calls)"; sed 's/^/    /' "$FX/.misses"; fi

echo "== the table"
has "an action bump" "| #1 | actions | ci | actions/upload-artifact 4 -> 7 | major | pass | - | CLEAN |"
has "a retried run does not read as plain green" "pass (after a retry)"
has "old versions come from the PR text" "@wordpress/url 4.53.0 -> 5.0.0"
has "a tool major is marked" "major (tool)"
has "a red PR reads as failed" "| fail |"
has "a group reads as a group" "2 updates (composer-dev)"
has "a group takes its highest update" "| minor | none |"
has "no run reads as none" "| none |"
has "a run in progress reads as pending" "| pending |"
has "one person's commit reads singular" "| 1 commit |"
has "two people's commits read plural" "| 2 commits |"
has "a stacked PR shows its own update only" "| #4 | npm | runtime | @wordpress/i18n 5.26.0 -> 7.0.0 |"
has "a person's PR has no ecosystem" "| #7 | - | - |"

echo "== failures"
has "the failed attempt behind a green run" "#2 attempt 1 failed, a retry passed: JS / Jest (unit)"
has "the failing test from the log, without colour codes" "● PoList › shows an error notice"
has "the error line" "Error: Found multiple elements with the text: Nope"
hasnt "the exit code line is noise" "Process completed"
has "a red PR with what CI never reached" "#3 failed: JS / ESLint -> never reached: Stylelint, Jest (unit)"
hasnt "Post steps are not steps anyone wrote" "Post Set up Node"
has "the older head's failure" "#4 failed on the older head 9999999: JS / TypeScript -> never reached: Jest (unit), Build"
has "an ESLint error line" "172:6  error  Replace"

echo "== the same failure elsewhere"
has "a shared failure is pointed out" "#2 #3: ● PoList › shows an error notice"

echo "== what CI did not prove"
has "a conditional step no bumped action uses is only for information" "for information, conditional steps that use none of the bumped actions: Notify on failure"
hasnt "setup steps are not reported" "Set up job"
if printf '%s\n' "$OUT" | grep -F 'for information' | grep -qF 'Upload Playwright report'; then
    bad "a step an update touches is not repeated as information"
else
    ok "a step an update touches is not repeated as information"
fi
has "a workflow with no run" "workflow with no run on the head: .github/workflows/release.yml"
hasnt "a disabled workflow is not reported" "old.yml"
hasnt "a dynamic workflow is not reported" "dependabot-updates"
has "a bumped action that never ran" '#1 actions/upload-artifact: step "Upload Playwright report" in .github/workflows/ci.yml: skipped'

echo "== what comes next"
has "tool majors" "tool majors, check the effective rules: #3"
has "a test environment major is not sent to the rule diff" "test environment majors, check the suites they run: #6"
has "and reads so in the table" "major (test env)"
has "reviews are pointed out" "reviews to read: #7 (copilot-pull-request-reviewer)"
has "runtime majors" "runtime majors, check what ships: #2 #4"
has "a build tool major is sent to the shipped files too" "build tool majors, check what ships too: #3"
has "PRs that Dependabot leaves alone" "PRs Dependabot will not rebase: #4 #7"
has "an old PR that Dependabot stopped rebasing" "older than 30 days, no automatic rebase (ask with \`@dependabot rebase\`): #5"

echo "== what a skipped job hides"
run 8 9 10
status "reads the second batch" 0
if [ -f "$FX/.misses" ]; then echo "  (unexpected gh calls)"; sed 's/^/    /' "$FX/.misses"; fi
has "an action in a job skipped as a whole is not proved" \
    '#8 softprops/action-gh-release: step "Publish the release" in .github/workflows/ci.yml: not seen in the run'
# shellcheck disable=SC2016  # the literal ${{ }} of a workflow file
hasnt "a matrix step matches the name the run shows" 'step "Notes on ${{ matrix.php }}"'
has "a job a condition skipped is listed" "jobs a condition skipped as a whole: release (.github/workflows/ci.yml)"
has "jobs a failure kept from starting are never reached" "#9 jobs never reached after the failure: test, build"
hasnt "and are not read as skipped by a condition" "test (.github/workflows/ci.yml)"
has "a red push run is not hidden by a green pull_request run" "| #10 | npm | dev | foo 1.0.0 -> 2.0.0 | major | fail |"
has "and its failure shows" "#10 failed: JS / ESLint -> never reached: Build"

echo "== default selection"
run
status "no argument means the open Dependabot PRs" 0
has "says how many" "o/r · 7 PRs"

echo "== json"
run --json 2
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); p=d["prs"][0]; sys.exit(0 if p["ci"]["retried"][0]["attempt"]==1 and p["updates"][0]["kind"]=="major" else 1)'; then
    ok "--json holds the same facts"
else
    bad "--json holds the same facts"
fi

echo "== expired logs"
rm -f "$FX/run-view-21---attempt-1---log-failed"
run 2
status "a log that is gone does not stop the run" 0
has "the failed step still shows" "#2 attempt 1 failed, a retry passed: JS / Jest (unit)"

echo "== errors"
OUT="$(GH_FAIL=1 python3 "$SCRIPT" 2>&1)"
RC=$?
status "a gh failure exits 2" 2
has "and says why" "authentication required"

printf '[]' >"$FX/pr-list---state-open---author-app-dependabot---limit-100---json-number"
run
status "no open PRs is not an error" 0
has "says so" "no open Dependabot PRs"

run --help
status "--help exits 0" 0
has "--help shows the usage" "inventory.py [PR ...]"

echo "== helpers"
if python3 - "$(dirname "$SCRIPT")" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
sys.dont_write_bytecode = True
from inventory import enclosing_step_name, parse_metadata, semver_of, versions_from_text

fail = []
def check(label, got, want):
    if got != want:
        fail.append(f"{label}: {got!r} != {want!r}")

doc = """      - name: Named
        uses: a/b@v1
        with:
          name: not-the-step
      - uses: c/d@v1
        with:
          name: not-the-step-either
      - uses: e/f@v1
        name: Named after
        if: failure()
      - name: 'Quoted'   # comment
        uses: g/h@v1
""".splitlines()
check("named step", enclosing_step_name(doc, 1), "Named")
check("with: name is not the step", enclosing_step_name(doc, 4), None)
check("name after uses", enclosing_step_name(doc, 7), "Named after")
check("quoted name and comment", enclosing_step_name(doc, 11), "Quoted")

check("major", semver_of("4", "7"), "major")
check("minor", semver_of("1.2.0", "1.3.0"), "minor")
check("patch", semver_of("1.2.0", "1.2.1"), "patch")
check("0.x minor counts as major", semver_of("0.2.0", "0.3.0"), "major")
check("0.x patch", semver_of("0.2.0", "0.2.1"), "patch")
check("no digits", semver_of("abc", "def"), "unknown")

meta = parse_metadata('x\n---\nupdated-dependencies:\n- dependency-name: "@a/b"\n  dependency-version: 1.0.0\n  dependency-type: direct:production\n  update-type: version-update:semver-major\n- dependency-name: c\n  dependency-group: g\n...\n')
check("two entries", [m["name"] for m in meta], ["@a/b", "c"])
check("a quoted name", meta[0]["update-type"], "version-update:semver-major")
check("the group", meta[1]["dependency-group"], "g")

check("Updates line", versions_from_text("Updates `a/b` from 1.0 to 2.0"), {"a/b": "1.0"})
check("Bumps line", versions_from_text("Bumps [a](http://x) from 1.0 to 2.0."), {"a": "1.0"})
check("title", versions_from_text("chore: bump a from 3 to 4"), {"a": "3"})
print("\n".join(fail))
sys.exit(1 if fail else 0)
PY
then ok "the parsing helpers"; else bad "the parsing helpers"; fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
