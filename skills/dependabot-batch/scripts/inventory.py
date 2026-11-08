#!/usr/bin/env python3
"""inventory.py — Take stock of a batch of Dependabot PRs, and of what their CI did not prove.

`gh pr checks` shows the last attempt on the last head, which hides most of what matters here:
a run that went green on a retry, the steps a failed job never reached, a step that only runs
on failure, a workflow that does not run on PRs. This prints those next to each PR.

Usage:
  inventory.py [PR ...]     the PRs given (any author), or every open Dependabot PR
  inventory.py --json       the same data as JSON

Run it from the repository. It only reads: gh pr view, gh api, gh run view.

Exit status: 0 always when the data could be read; 2 a usage or gh error.
"""

import argparse
import concurrent.futures
import datetime
import json
import re
import subprocess
import sys

BOT = "dependabot[bot]"
REBASE_DAYS = 30  # After this long unmerged, Dependabot stops rebasing a PR by itself.
PR_FIELDS = (
    "number,title,author,state,headRefName,headRefOid,mergeable,mergeStateStatus,"
    "additions,deletions,files,commits,body,createdAt,reviews"
)
ECOSYSTEM = {"npm_and_yarn": "npm", "composer": "composer", "github_actions": "actions", "pip": "pip", "bundler": "bundler"}
UPDATE_RANK = {"unknown": 0, "patch": 1, "minor": 2, "major": 3}
# Tools can stop checking without a red run, so their majors get an effective-rules check.
TOOL = re.compile(
    r"""^(eslint|prettier|stylelint|typescript|jest|babel-jest|vitest|webpack|playwright|
    @babel/|@typescript-eslint/|@types/jest|@playwright/|
    @wordpress/(scripts|eslint-plugin|prettier-config|stylelint-config|jest-|babel-preset|e2e-test-utils|env)|
    squizlabs/php_codesniffer|phpcsstandards/|wp-coding-standards/|phpcompatibility/|
    woocommerce/woocommerce-sniffs|sirbrillig/|dealerdirect/|
    phpstan/|szepeviktor/phpstan|php-stubs/|phpunit/|yoast/phpunit|wp-phpunit/)""",
    re.X,
)
# These run the suites instead of defining them, so comparing lint rules says nothing about them.
TEST_ENV = re.compile(r"^(playwright|@playwright/|@wordpress/(env|e2e-test-utils))")
# These write what ships: the bundles and the *.asset.php dependency lists.
BUILD = re.compile(
    r"^(?:@babel/|(?:webpack|webpack-cli|babel-loader|esbuild|rollup|vite|terser|postcss|sass|"
    r"@wordpress/(?:scripts|babel-preset-default|dependency-extraction-webpack-plugin))$)"
)
LOG_PREFIX = re.compile(r"^[^\t]*\t[^\t]*\t\S+Z\s?")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
SIGNATURE = re.compile(r"●|##\[error\]|^\s*FAIL\b|^\d+\) |error TS\d+|^\s+\d+:\d+\s+error\b")
NOISE = re.compile(r"Process completed with exit code|^\s*$")


class GhError(Exception):
    pass


def gh(*args):
    try:
        done = subprocess.run(["gh", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except FileNotFoundError as error:
        raise GhError("gh is not installed") from error
    if done.returncode != 0:
        raise GhError(f"gh {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def gh_json(*args):
    return json.loads(gh(*args))


def gh_quiet(*args):
    """For data that may be gone, such as an expired log."""
    try:
        return gh(*args)
    except GhError:
        return ""


# ---- what the PR updates ----------------------------------------------------------------------


def parse_metadata(message):
    """The updated-dependencies block that Dependabot writes into its commit messages."""
    entries = []
    for line in message.splitlines():
        found = re.match(r"\s*(-\s+)?([a-z-]+):\s*(.*)$", line)
        if not found:
            continue
        key, value = found.group(2), found.group(3).strip().strip("\"'")
        if found.group(1) and key == "dependency-name":
            entries.append({"name": value})
        elif entries and key in ("dependency-version", "dependency-type", "update-type", "dependency-group"):
            entries[-1][key] = value
    return entries


def versions_from_text(text):
    """name -> old version, from `Updates `x` from a to b` and `Bumps [x](url) from a to b.`"""
    found = {}
    for name, old in re.findall(r"Updates `([^`]+)` from (\S+) to \S+", text):
        found[name] = old
    for name, old in re.findall(r"Bumps \[([^\]]+)\]\([^)]*\) from (\S+) to \S+", text):
        found.setdefault(name, old)
    for name, old in re.findall(r"[Bb]ump (\S+) from (\S+) to \S+", text):
        found.setdefault(name, old)
    return found


def semver_of(old, new):
    parts = [re.findall(r"\d+", str(v))[:3] for v in (old, new)]
    if not parts[0] or not parts[1]:
        return "unknown"
    if parts[0][0] != parts[1][0]:
        return "major"
    if parts[0][0] == "0":  # 0.x: a minor can break, so it counts as a major.
        return "major" if parts[0][1:2] != parts[1][1:2] else "patch"
    return "minor" if parts[0][1:2] != parts[1][1:2] else "patch"


def is_bot(commit):
    return any(a.get("login") == BOT or a.get("name") == BOT for a in commit.get("authors", []))


def updates_of(pr):
    entries = {}
    bot_text = ""
    for commit in pr["commits"]:
        if not is_bot(commit):
            continue
        bot_text += f"{commit.get('messageHeadline', '')}\n{commit.get('messageBody', '')}\n"
        for entry in parse_metadata(commit.get("messageBody", "")):
            entries.setdefault(entry["name"], entry)
    old_versions = versions_from_text(f"{pr['title']}\n{pr['body']}\n{bot_text}")
    # A stacked PR also carries the commits of the PR below it; the title says which one this is.
    named = re.search(r"[Bb]ump (\S+) from", pr["title"])
    if named and named.group(1) in entries:
        entries = {named.group(1): entries[named.group(1)]}
    updates = []
    for name, entry in entries.items():
        kind = entry.get("update-type", "").replace("version-update:semver-", "") or None
        new = entry.get("dependency-version", "?")
        old = old_versions.get(name, "?")
        updates.append({
            "name": name,
            "from": old,
            "to": new,
            "kind": kind or semver_of(old, new),
            "type": entry.get("dependency-type", "").replace("direct:", "") or "unknown",
            "group": entry.get("dependency-group"),
            "tool": bool(TOOL.match(name)),
        })
    return updates


def ecosystem_of(pr):
    parts = pr["headRefName"].split("/")
    if parts[0] != "dependabot" or len(parts) < 2:
        return "-"
    return ECOSYSTEM.get(parts[1], parts[1])


def summarize_update(pr):
    updates = pr["updates"]
    if not updates:
        return pr["title"][:60]
    if len(updates) == 1:
        one = updates[0]
        return f"{one['name']} {one['from']} -> {one['to']}"
    group = next((u["group"] for u in updates if u.get("group")), None)
    return f"{len(updates)} updates" + (f" ({group})" if group else "")


# ---- what the CI did ------------------------------------------------------------------------------


def step_view(job):
    """A job's steps as ran / failed / never reached / skipped by a condition. Post steps are noise."""
    ran, failed, unreached, conditional = [], [], [], []
    for step in job.get("steps", []):
        name, conclusion = step.get("name", ""), step.get("conclusion")
        if name.startswith("Post ") or name in ("Set up job", "Complete job"):
            continue
        if conclusion in ("failure", "timed_out", "cancelled"):
            failed.append(name)
        elif conclusion == "skipped":
            (unreached if failed else conditional).append(name)
        elif conclusion in ("success", "neutral"):
            ran.append(name)
    return {"job": job.get("name"), "conclusion": job.get("conclusion"), "ran": ran, "failed": failed,
            "unreached": unreached, "conditional": conditional}


def mark_skipped_jobs(views):
    """A job skipped as a whole has no steps, and the API does not say why. With no failure in the
    run, a condition kept it out (`if:` on the job, such as a tag-only release). After a failure it
    may have waited on the failed job (`needs:`) or had a condition of its own: both are possible."""
    run_failed = any(v["failed"] or v["conclusion"] in ("failure", "timed_out", "cancelled") for v in views)
    for view in views:
        if view["conclusion"] == "skipped" and not (view["ran"] or view["failed"] or view["unreached"] or view["conditional"]):
            view["skipped_job"] = "unreached" if run_failed else "conditional"
    return views


def signatures(run_id, attempt):
    """The lines that say what failed, so the same failure can be told apart across PRs."""
    log = gh_quiet("run", "view", str(run_id), "--attempt", str(attempt), "--log-failed")
    lines = []
    for raw in log.splitlines():
        line = ANSI.sub("", LOG_PREFIX.sub("", raw)).strip()
        if SIGNATURE.search(line) and not NOISE.search(line):
            line = line.replace("##[error]", "").strip()
            if line not in lines:
                lines.append(line)
    return lines[:6]


def jobs_of(repo, run, attempt=None):
    path = f"repos/{repo}/actions/runs/{run['id']}"
    path += f"/attempts/{attempt}/jobs" if attempt else "/jobs?filter=latest"
    separator = "&" if "?" in path else "?"
    return gh_json("api", f"{path}{separator}per_page=100").get("jobs", [])


def inspect_ci(repo, pr, workflows):
    head = pr["headRefOid"]
    runs = gh_json("api", f"repos/{repo}/actions/runs?branch={pr['headRefName']}&per_page=50").get("workflow_runs", [])
    runs = [r for r in runs if str(r.get("path", "")).startswith(".github/")]
    # One run per workflow and event: `on: [push, pull_request]` runs a workflow twice on the
    # same head, and a red push run must not hide behind a green pull_request run.
    latest = {}
    for run in sorted(runs, key=lambda r: r.get("created_at", "")):
        if run.get("head_sha") == head:
            latest[(run["path"], run.get("event"))] = run
    # A concurrency group shared by both events cancels one of the two runs: that is no failure
    # while the same workflow has a run on this head that was not cancelled.
    alive = {path for (path, _), run in latest.items() if run.get("conclusion") != "cancelled"}
    latest = {key: run for key, run in latest.items() if run.get("conclusion") != "cancelled" or key[0] not in alive}

    ci = {"state": "none", "jobs": [], "retried": [], "older_failures": [], "not_triggered": []}
    states = []
    for (path, _), run in latest.items():
        if run.get("status") != "completed":
            states.append("pending")
        else:
            states.append({"success": "pass", "failure": "fail"}.get(run.get("conclusion"), run.get("conclusion")))
        for view in mark_skipped_jobs([step_view(job) for job in jobs_of(repo, run)]):
            view["workflow"] = path
            if view["failed"]:
                view["signature"] = signatures(run["id"], run.get("run_attempt", 1))
            ci["jobs"].append(view)
        # A retry leaves the earlier attempts out of gh pr checks.
        for attempt in range(1, int(run.get("run_attempt", 1))):
            for job in jobs_of(repo, run, attempt):
                view = step_view(job)
                if view["failed"]:
                    view["attempt"] = attempt
                    view["run"] = run["id"]
                    view["signature"] = signatures(run["id"], attempt)
                    ci["retried"].append(view)

    for run in runs:
        if run.get("head_sha") != head and run.get("conclusion") == "failure":
            for job in jobs_of(repo, run):
                view = step_view(job)
                if view["failed"]:
                    view["head"] = run["head_sha"][:7]
                    ci["older_failures"].append(view)

    if states:
        for state in ("fail", "pending", "cancelled"):
            if state in states:
                ci["state"] = state
                break
        else:
            ci["state"] = "pass" if all(s == "pass" for s in states) else "/".join(sorted(set(states)))
    ran_paths = {path for path, _ in latest}
    ci["not_triggered"] = sorted(path for path in workflows if path not in ran_paths)
    return ci


def step_opening(lines, index):
    while index >= 0 and not re.match(r"\s*-\s", lines[index]):
        index -= 1
    return index


def enclosing_step_name(lines, index):
    """The name of the step around a `uses:` line. `with: name:` belongs to the action, not the step."""
    start = step_opening(lines, index)
    if start < 0:
        return None
    indent = len(lines[start]) - len(lines[start].lstrip())
    found = re.match(r"\s*-\s+name:\s*(.+)$", lines[start])
    if found:
        return found.group(1).split(" #")[0].strip().strip("\"'")
    for line in lines[start + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        found = re.match(rf"\s{{{indent + 2}}}name:\s*(.+)$", line)
        if found:
            return found.group(1).split(" #")[0].strip().strip("\"'")
    return None


def enclosing_job(lines, index):
    """The job around a line: what the run calls it (its `name:`, else its id), or None. Job keys
    are the first indented level under `jobs:`."""
    jobs_at = next((i for i in range(index, -1, -1) if re.match(r"jobs:\s*(#.*)?$", lines[i])), None)
    if jobs_at is None:
        return None
    child = next((line for line in lines[jobs_at + 1:index + 1] if line.strip() and not line.lstrip().startswith("#")), None)
    if child is None:
        return None
    key_indent = len(child) - len(child.lstrip())
    key_at = next((i for i in range(index, jobs_at, -1)
                   if lines[i].strip() and len(lines[i]) - len(lines[i].lstrip()) == key_indent), None)
    if key_at is None:
        return None
    job_id = lines[key_at].strip().rstrip(":").strip("\"'")
    body = [line for line in lines[key_at + 1:] if line.strip() and not line.lstrip().startswith("#")]
    child_indent = len(body[0]) - len(body[0].lstrip()) if body else None
    for line in body:
        indent = len(line) - len(line.lstrip())
        if indent <= key_indent:
            break
        found = re.match(r"\s*name:\s*(.+)$", line)
        if found and indent == child_indent:
            return found.group(1).split(" #")[0].strip().strip("\"'")
    return job_id


def action_coverage(repo, pr):
    """For an action bump: did the step that uses it run at all on this head?"""
    if pr["ecosystem"] != "actions":
        return []
    coverage = []
    paths = [f["path"] for f in pr["files"] if f["path"].startswith(".github/")]
    for update in pr["updates"]:
        pattern = re.compile(rf"""uses:\s*['"]?{re.escape(update['name'])}@(\S+)""")
        for path in paths:
            text = gh_quiet("api", "-H", "Accept: application/vnd.github.raw", f"repos/{repo}/contents/{path}?ref={pr['headRefOid']}")
            lines = text.splitlines()
            for index, line in enumerate(lines):
                used = pattern.search(line)
                if not used:
                    continue
                name = enclosing_step_name(lines, index) or f"Run {update['name']}@{used.group(1).strip(chr(39) + chr(34))}"
                job = enclosing_job(lines, index)
                coverage.append({"action": update["name"], "path": path, "step": name, "job": job,
                                 "state": step_state(pr["ci"], path, name, job)})
    return coverage


def step_matcher(name):
    """A step name as the run shows it: `${{ matrix.x }}` in the workflow is a value in the run."""
    parts = re.split(r"\$\{\{.*?\}\}", name)
    if len(parts) == 1:
        return lambda shown: shown == name
    if not any(part.strip() for part in parts):
        return lambda shown: False  # a name that is only an expression matches every step
    pattern = re.compile("^" + ".+".join(re.escape(part) for part in parts) + "$")
    return lambda shown: bool(pattern.match(shown))


def job_matcher(name):
    """A job as the run names it: a matrix adds " (values)", and an expression is a value."""
    same = step_matcher(name)
    return lambda shown: same(shown) or same(re.sub(r" \(.*\)$", "", shown))


def step_state(ci, path, name, job=None):
    """The step counts as run only when the run shows it running, in its own job: another job
    may have a step of the same name. A step in a job skipped as a whole, in a job this cannot
    match, or under a name this cannot match, is not proved by CI."""
    jobs = [j for j in ci["jobs"] if j.get("workflow") == path]
    if not jobs:
        return "workflow did not run"
    if job:
        owned = job_matcher(job)
        jobs = [j for j in jobs if owned(j.get("job") or "")]
        if not jobs:
            return f"not seen in the run (no job named {job!r} in it)"
    matches = step_matcher(name)
    if any(matches(step) for j in jobs for step in j["ran"] + j["failed"]):
        return "ran"
    if any(matches(step) for j in jobs for step in j["conditional"] + j["unreached"]):
        return "skipped"
    return "not seen in the run (its job was skipped, or the run names the step differently)"


# ---- the batch --------------------------------------------------------------------------------------


def age_in_days(timestamp):
    if not timestamp:
        return 0
    created = datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    return (datetime.datetime.now(datetime.timezone.utc) - created).days


def load_pr(repo, number, workflows):
    pr = gh_json("pr", "view", str(number), "--json", PR_FIELDS)
    pr["ecosystem"] = ecosystem_of(pr)
    pr["updates"] = updates_of(pr)
    pr["edited"] = [c["oid"][:7] for c in pr["commits"] if not is_bot(c)]
    pr["stale"] = age_in_days(pr.get("createdAt")) > REBASE_DAYS and not pr["edited"]
    pr["kind"] = max((u["kind"] for u in pr["updates"]), key=UPDATE_RANK.get, default="unknown")
    pr["scope"] = "runtime" if any(u["type"] == "production" for u in pr["updates"]) else "dev"
    if pr["ecosystem"] == "actions":
        pr["scope"] = "ci"
    elif not pr["updates"]:
        pr["scope"] = "-"
    majors = [u for u in pr["updates"] if u["tool"] and u["kind"] == "major"]
    pr["test_env_major"] = any(TEST_ENV.match(u["name"]) for u in majors)
    pr["tool_major"] = any(not TEST_ENV.match(u["name"]) for u in majors)
    pr["build_major"] = any(BUILD.match(u["name"]) for u in pr["updates"] if u["kind"] == "major")
    pr["reviewers"] = sorted({(r.get("author") or {}).get("login", "?") for r in pr.get("reviews", [])})
    pr["ci"] = inspect_ci(repo, pr, workflows)
    pr["coverage"] = action_coverage(repo, pr)
    for key in ("files", "commits", "body", "author", "reviews"):
        pr.pop(key, None)
    return pr


def shared_failures(prs):
    """The same failure on several PRs points at the base or a flaky test, not at the updates."""
    seen = {}
    for pr in prs:
        ci = pr["ci"]
        for view in ci["retried"] + [j for j in ci["jobs"] if j["failed"]]:
            for line in view.get("signature", []):
                seen.setdefault(line, set()).add(pr["number"])
    return {line: sorted(numbers) for line, numbers in seen.items() if len(numbers) > 1}


def print_report(repo, prs):
    print(f"{repo} · {len(prs)} PRs\n")
    print("| PR | eco | scope | update | kind | CI | edited | merge state |")
    print("|---|---|---|---|---|---|---|---|")
    for pr in prs:
        kind = pr["kind"] + (" (tool)" if pr["tool_major"] else " (test env)" if pr["test_env_major"] else "")
        ci = pr["ci"]["state"] + (" (after a retry)" if pr["ci"]["retried"] else "")
        count = len(pr["edited"])
        edited = f"{count} commit{'' if count == 1 else 's'}" if count else "-"
        print(f"| #{pr['number']} | {pr['ecosystem']} | {pr['scope']} | {summarize_update(pr)} | {kind} | {ci} | {edited} | {pr['mergeStateStatus']} |")

    print("\n## Failed, or green only after a retry")
    quiet = True
    for pr in prs:
        ci = pr["ci"]
        for view in ci["retried"]:
            quiet = False
            print(f"- #{pr['number']} attempt {view['attempt']} failed, a retry passed: {view['job']} / {', '.join(view['failed'])}")
            for line in view.get("signature", []):
                print(f"    {line}")
        for view in ci["jobs"]:
            if view["failed"]:
                quiet = False
                unreached = f" -> never reached: {', '.join(view['unreached'])}" if view["unreached"] else ""
                print(f"- #{pr['number']} failed: {view['job']} / {', '.join(view['failed'])}{unreached}")
                for line in view.get("signature", []):
                    print(f"    {line}")
        blocked = [v["job"] for v in ci["jobs"] if v.get("skipped_job") == "unreached"]
        if blocked:
            quiet = False
            print(f"- #{pr['number']} jobs skipped after the failure (`needs:` on the failed job, or a condition "
                  f"of their own): {', '.join(blocked)}")
        for view in ci["older_failures"]:
            quiet = False
            unreached = f" -> never reached: {', '.join(view['unreached'])}" if view["unreached"] else ""
            print(f"- #{pr['number']} failed on the older head {view['head']}: {view['job']} / {', '.join(view['failed'])}{unreached}")
    if quiet:
        print("- none")

    shared = shared_failures(prs)
    if shared:
        print("\n## The same failure on several PRs")
        for line, numbers in shared.items():
            print(f"- {' '.join(f'#{n}' for n in numbers)}: {line}")

    print("\n## Not proved by CI")
    conditional = set()
    conditional_jobs = set()
    not_triggered = {}
    updated_steps = set()
    found = False
    for pr in prs:
        for view in pr["ci"]["jobs"]:
            conditional.update(view["conditional"])
            if view.get("skipped_job") == "conditional":
                conditional_jobs.add(f"{view['job']} ({view['workflow']})")
        for path in pr["ci"]["not_triggered"]:
            not_triggered.setdefault(path, []).append(pr["number"])
        for item in pr["coverage"]:
            updated_steps.add(item["step"])
            if item["state"] != "ran":
                found = True
                print(f"- #{pr['number']} {item['action']}: step \"{item['step']}\" in {item['path']}: {item['state']}")
    for path, numbers in sorted(not_triggered.items()):
        found = True
        print(f"- workflow with no run on the head: {path} ({' '.join(f'#{n}' for n in sorted(numbers))})")
    # Only an action bump can be matched to the steps that use it. An npm or Composer update can
    # still reach these steps through a script, so they are listed, not cleared.
    matchers = [step_matcher(step) for step in updated_steps]
    unrelated = sorted(step for step in conditional if not any(matches(step) for matches in matchers))
    if not found:
        # The lines below are still unproved; "nothing found" above them would read as all clear.
        print("- nothing tied to a bumped action or a workflow with no run" if unrelated or conditional_jobs else "- nothing found")
    if unrelated:
        print(f"- for information, conditional steps that use none of the bumped actions: {', '.join(unrelated)}")
    if conditional_jobs:
        print(f"- for information, jobs a condition skipped as a whole: {', '.join(sorted(conditional_jobs))}")

    tools = [f"#{p['number']}" for p in prs if p["tool_major"]]
    runtime = [f"#{p['number']}" for p in prs if p["scope"] == "runtime" and p["kind"] in ("major", "unknown")]
    edited = [f"#{p['number']}" for p in prs if p["edited"]]
    print("\n## Next")
    test_env = [f"#{p['number']}" for p in prs if p["test_env_major"]]
    print(f"- tool majors, check the effective rules: {' '.join(tools) or 'none'}")
    print(f"- test environment majors, check the suites they run: {' '.join(test_env) or 'none'}")
    print(f"- runtime majors, check what ships: {' '.join(runtime) or 'none'}")
    build = [f"#{p['number']}" for p in prs if p["build_major"]]
    print(f"- build tool majors, check what ships too: {' '.join(build) or 'none'}")
    print(f"- PRs Dependabot will not rebase: {' '.join(edited) or 'none'}")
    reviewed = [f"#{p['number']} ({', '.join(p['reviewers'])})" for p in prs if p["reviewers"]]
    if reviewed:
        print(f"- reviews to read: {' '.join(reviewed)}")
    stale = [f"#{p['number']}" for p in prs if p["stale"]]
    if stale:
        print(f"- older than {REBASE_DAYS} days, no automatic rebase (ask with `@dependabot rebase`): {' '.join(stale)}")


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("numbers", nargs="*", type=int)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args()
    if args.help:
        print(__doc__)
        return 0

    try:
        repo = gh_json("repo", "view", "--json", "nameWithOwner")["nameWithOwner"]
        numbers = args.numbers
        if not numbers:
            listed = gh_json("pr", "list", "--state", "open", "--author", "app/dependabot", "--limit", "100", "--json", "number")
            numbers = sorted(item["number"] for item in listed)
        workflows = gh_json("api", f"repos/{repo}/actions/workflows?per_page=100").get("workflows", [])
        active = [w["path"] for w in workflows if w.get("state") == "active" and w["path"].startswith(".github/")]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            prs = list(pool.map(lambda n: load_pr(repo, n, active), numbers))
    except (GhError, ValueError) as error:
        print(f"inventory: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps({"repo": repo, "prs": prs, "shared_failures": shared_failures(prs)}, indent=2, ensure_ascii=False))
    elif prs:
        print_report(repo, prs)
    else:
        print(f"{repo}: no open Dependabot PRs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
