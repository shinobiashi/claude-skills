#!/usr/bin/env python3
"""rules-diff.py — Compare what the lint, type and test tools really check in two trees.

A tool major can keep CI green while it stops checking: wp-scripts 37 stopped reading
.eslintrc.js, so a wrong text domain passed with exit 0 (saai-inventory #54). A green run cannot
show that, so this asks each tool for its effective configuration in both trees and compares.

Usage:
  rules-diff.py --base DIR --head DIR [options]

  --base DIR, --head DIR   two trees with their dependencies installed (npm ci, composer install)
  --sample FILE            a file to ask ESLint or Stylelint about; repeat for more
                           (default: one per file kind, source and test files apart)
  --only TOOLS             comma list of eslint,stylelint,tsc,jest,playwright,phpcs,phpstan,
                           phpunit,assets. Pass the side that changed: an npm-only update does
                           not need composer install, if the PHP tools are left out.
  --jest-config FILE       default: the --config a package.json script passes, jest-unit.config.*
                           or jest.config.*, the jest key, then wp-scripts' bundled config
  --playwright-config FILE default: the --config a package.json script passes,
                           playwright.config.*, then wp-scripts' bundled config
  --phpunit-config FILE    default: phpunit.xml(.dist)
  --build-dir DIR          where *.asset.php lie (default: build, assets/build, dist)
  --full                   list every name instead of the first 40 in a group
  --json                   print the results as JSON

Run it with the Node that CI uses (nvm use): the tools refuse or change behaviour on another one.

A probe that fails on one side is a finding, never "no difference": a tool that cannot print its
configuration may be a tool that cannot run. The same goes for a tool with a config in the tree
but no binary (a skipped install), and for a tool package.json runs with no config this can find.
SKIPPED only means the project shows no sign of using the tool.
PHPCS and the test runners are compared by what they list, so a sniff removed upstream shows up
too: LOST means "look at this", not "this is broken". Jest lists files, not tests, and the counts
compare the two trees; they are not the totals CI prints.

SAME only speaks for what was compared: a helper the tools do not read leaves everything SAME.

Exit status: 0 nothing lost; 1 something was lost, weakened, or could not be compared;
2 a usage error.
"""

import argparse
import json
import os
import re
import subprocess
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
GENERATED = re.compile(r"(^|/)(node_modules|vendor|vendor-prefixed|build|dist)(/|$)|\.min\.")
TEST_FILE = re.compile(r"\.(test|spec)\.|(^|/)__tests__/")
CONFIG_FILE = re.compile(r"(^|/)\.[^/]*$|\.config\.[^/]*$")
SNIFF = re.compile(r"^\s+([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\s*$")
LEGACY_ESLINT = (".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yml", ".eslintrc.yaml")
WP_CONFIG = "node_modules/@wordpress/scripts/config"
ALL_TOOLS = ("eslint", "stylelint", "tsc", "jest", "playwright", "phpcs", "phpstan", "phpunit", "assets")
PLAYWRIGHT_CONFIGS = ("playwright.config.ts", "playwright.config.js", "playwright.config.mjs", "playwright.config.cjs")
JEST_CONFIGS = ("jest-unit.config.js", "jest-unit.config.cjs", "jest-unit.config.mjs", "jest.config.js",
                "jest.config.cjs", "jest.config.mjs", "jest.config.ts", "jest.config.json")
# TypeScript checks that `strict` turns on unless they are set; turning any of them off weakens tsc.
STRICT_FAMILY = ("noImplicitAny", "noImplicitThis", "alwaysStrict", "strictNullChecks", "strictFunctionTypes",
                 "strictBindCallApply", "strictPropertyInitialization", "useUnknownInCatchVariables",
                 "strictBuiltinIteratorReturn")
TSC_CHECKS = ("strict",) + STRICT_FAMILY + (
    "noUnusedLocals", "noUnusedParameters", "noImplicitReturns", "noFallthroughCasesInSwitch",
    "noUncheckedIndexedAccess", "exactOptionalPropertyTypes", "noImplicitOverride",
    "noPropertyAccessFromIndexSignature", "checkJs")
SEVERITY = {0: "off", 1: "warn", 2: "error", "0": "off", "1": "warn", "2": "error"}
LIMIT = 40


def run(cmd, cwd):
    try:
        done = subprocess.run(
            cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=600, stdin=subprocess.DEVNULL
        )
    except FileNotFoundError:
        return 127, "", f"{cmd[0]}: not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timed out"
    return done.returncode, ANSI.sub("", done.stdout), ANSI.sub("", done.stderr)


def tool_path(tree, relative):
    path = os.path.join(tree, relative)
    return path if os.path.exists(path) else None


def first_error(*texts):
    for text in texts:
        for line in text.splitlines():
            line = line.strip()
            if line and not line.startswith(("(node:", "(Use `node", "Note: ")):
                return line[:200]
    return "no output"


def tracked(tree):
    code, out, _ = run(["git", "ls-files"], tree)
    if code == 0 and out:
        return out.splitlines()
    found = []
    for folder, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in ("node_modules", "vendor", ".git")]
        found += [os.path.relpath(os.path.join(folder, name), tree) for name in files]
    return found


def package_json(tree):
    try:
        with open(os.path.join(tree, "package.json"), encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def scripts_use(tree, *words):
    scripts = package_json(tree).get("scripts", {})
    return any(word in str(value) for value in scripts.values() for word in words)


def wp_scripts_runs(tree, command):
    return scripts_use(tree, f"wp-scripts {command}")


JEST_COMMANDS = (r"wp-scripts test-unit-js", r"(?<![\w@/.-])jest(?![\w.-])")
PLAYWRIGHT_COMMANDS = (r"wp-scripts test-playwright", r"(?<![\w@/.-])playwright test")


def script_configs(tree, commands):
    """What package.json scripts hand to one of these commands: the path after --config / -c,
    or None for a script that runs it without one. Only flags after the command count, so the
    -c of a wrapper (concurrently, dotenv) is not taken for the tool's."""
    found = []
    for value in package_json(tree).get("scripts", {}).values():
        for segment in re.split(r"&&|\|\||;", str(value)):
            starts = [m.start() for m in (re.search(c, segment) for c in commands) if m]
            if not starts:
                continue
            match = re.search(r"(?:--config[=\s]|\s-c\s)\s*(['\"]?)([^\s'\"]+)\1", segment[min(starts):])
            config = match.group(2) if match else None
            if config not in found:
                found.append(config)
    return found


def script_config(tree, subject, commands, option):
    """(config or None, failure or None). With a --config in a script, wp-scripts runs it instead
    of its bundled config, so that is what to compare. Two suites with other configs (a unit and an
    e2e script) cannot be told apart here: comparing the wrong one would read as SAME."""
    found = script_configs(tree, commands)
    passed = [config for config in found if config]
    if len(found) > 1 and passed:
        listed = ", ".join(config or "its default config" for config in found)
        return None, result(subject, "failed", [f"package.json runs it with several configs ({listed}): pass {option}"])
    return (passed[0] if passed else None), None


def missing_tool(subject, base, head, binary, configs):
    """The result for an absent tool, or None. A config without its tool is a skipped install."""
    old, new = tool_path(base, binary), tool_path(head, binary)
    if old and new:
        return None
    found = next((name for name in configs if tool_path(base, name) or tool_path(head, name)), None)
    if found or old or new:
        reason = f"{found} is here" if found else "only one tree has it"
        return [result(subject, "failed", [f"{reason}, but {binary} is missing: install the dependencies, or leave the tool out with --only"])]
    return [result(subject, "skipped", ["not installed"])]


def pick_samples(base, head, explicit, kinds):
    """One real source file per kind, in both trees: a config file says nothing about the code."""
    if explicit:
        return [s for s in explicit if s.endswith(tuple(ext for ext, _ in kinds))]
    common = set(tracked(base)) & set(tracked(head))
    names = sorted(n for n in common if not GENERATED.search(n) and not CONFIG_FILE.search(n))
    picked = []
    for ext, is_test in kinds:
        for name in names:
            if name.endswith(ext) and bool(TEST_FILE.search(name)) == is_test:
                picked.append(name)
                break
    return picked


# ---- comparing rule maps ------------------------------------------------------------------------


def normalize_rule(value):
    """A rule as (severity, options): "error", 2, ["error", {...}] and [2, {...}] all occur."""
    items = value if isinstance(value, list) else [value]
    severity = SEVERITY.get(items[0], items[0]) if items else "off"
    return severity, json.dumps(items[1:], sort_keys=True)


def normalize_stylelint_rule(value, default="error"):
    """Stylelint: null is off, and the severity sits in the secondary options. A rule that names
    none takes the config's defaultSeverity, so a shared config can turn every rule into a warning."""
    items = value if isinstance(value, list) else [value]
    if not items or items[0] is None:
        return "off", "[]"
    secondary = items[1] if len(items) > 1 and isinstance(items[1], dict) else {}
    severity = {"warning": "warn", "error": "error"}.get(secondary.get("severity"), default)
    return severity, json.dumps(items, sort_keys=True)


def stylelint_normalizer(config):
    default = "warn" if config.get("defaultSeverity") == "warning" else "error"
    return lambda value: normalize_stylelint_rule(value, default)


def compare_rules(base_rules, head_rules, normalize=normalize_rule, normalize_head=None):
    base = {name: normalize(value) for name, value in base_rules.items()}
    head = {name: (normalize_head or normalize)(value) for name, value in head_rules.items()}
    active = lambda rule: rule is not None and rule[0] != "off"
    diff = {"lost": [], "dropped": [], "gained": [], "weakened": [], "options": []}
    for name in sorted(set(base) | set(head)):
        old, new = base.get(name), head.get(name)
        if active(old) and not active(new):
            diff["lost"].append(name)
        elif active(new) and not active(old):
            diff["gained"].append(name)
        elif active(old) and active(new):
            if old[0] == "error" and new[0] == "warn":
                diff["weakened"].append(name)
            if old[1] != "[]" and new[1] == "[]":
                diff["dropped"].append(f"{name} {old[1][:80]}")
            elif old[1] != new[1]:
                diff["options"].append(name)
    diff["base_active"] = sum(1 for rule in base.values() if active(rule))
    diff["head_active"] = sum(1 for rule in head.values() if active(rule))
    return diff


def compare_sets(base, head):
    return {"lost": sorted(base - head), "gained": sorted(head - base)}


# ---- probes: each returns {"subject", "status", "lines", "data"} --------------------------------
# status: same, changed (look at it), lost (look harder), failed (cannot compare), skipped


def result(subject, status, lines=(), data=None):
    return {"subject": subject, "status": status, "lines": list(lines), "data": data or {}}


def names(label, values, full):
    shown = values if full else values[:LIMIT]
    more = "" if len(shown) == len(values) else f" ... and {len(values) - len(shown)} more"
    return f"{label} ({len(values)}): {' '.join(shown)}{more}"


def rules_lines(diff, full):
    lines = [f"active rules: base {diff['base_active']}, head {diff['head_active']}"]
    labels = (("lost", "LOST"), ("weakened", "WEAKENED error->warn"), ("options", "OPTIONS changed"), ("gained", "gained"))
    for key, label in labels:
        if diff[key]:
            lines.append(names(label, diff[key], full))
    for entry in diff["dropped"]:
        lines.insert(1, f"OPTIONS DROPPED: {entry}")
    return lines


def rules_status(diff):
    if diff["lost"] or diff["weakened"] or diff["dropped"]:
        return "lost"
    return "changed" if diff["options"] or diff["gained"] else "same"


def read_config(tree, sample, binary, bundled, command):
    """(config or None, source, error). wp-scripts passes its own config when it finds none."""
    exe = tool_path(tree, binary)
    if exe is None:
        return None, None, "not installed"
    code, out, err = run([exe, "--print-config", sample], tree)
    source = "project config"
    if code != 0 and wp_scripts_runs(tree, command):
        for name, extra in bundled:
            path = tool_path(tree, f"{WP_CONFIG}/{name}")
            if path:
                code, out, err = run([exe, *extra, "--config", path, "--print-config", sample], tree)
                source = f"wp-scripts' bundled {name}"
                if code == 0:
                    break
    if code != 0:
        return None, None, first_error(err, out)
    text = out.strip()
    if text in ("", "undefined"):
        return {}, f"{source}, file ignored", None
    try:
        config = json.loads(text)
    except ValueError:
        return None, None, "the output is not JSON"
    return (config if isinstance(config, dict) else {}), source, None


def source_kind(source):
    """Only a switch between the project's config and a bundled one, or a file that became
    ignored, changes what is checked. Two bundled files with other names are the same kind."""
    return source.startswith("wp-scripts' bundled"), source.endswith("file ignored")


def probe_config(tool, base, head, samples, binary, bundled, command, full, normalizer=None):
    results = []
    for sample in samples:
        old, old_source, old_err = read_config(base, sample, binary, bundled, command)
        new, new_source, new_err = read_config(head, sample, binary, bundled, command)
        if old_err == "not installed" and new_err == "not installed":
            if scripts_use(base, tool, f"wp-scripts {command}"):
                return [result(tool, "failed", [f"package.json runs it, but {binary} is missing: install the dependencies, or leave the tool out with --only"])]
            return [result(tool, "skipped", ["not installed"])]
        if old_err or new_err:
            lines = [f"{side}: {err}" for side, err in (("base", old_err), ("head", new_err)) if err]
            results.append(result(sample, "failed", lines))
            continue
        normalize = normalizer or (lambda config: normalize_rule)
        diff = compare_rules(old.get("rules", {}), new.get("rules", {}), normalize(old), normalize(new))
        lines = rules_lines(diff, full)
        status = rules_status(diff)
        if old_source != new_source and source_kind(old_source) == source_kind(new_source):
            lines.insert(0, f"config: base uses {old_source}, head uses {new_source}")
        elif old_source != new_source:
            lines.insert(0, f"CONFIG SOURCE: base uses {old_source}, head uses {new_source}")
            status = "lost"
            ignored = [n for n in LEGACY_ESLINT if tool_path(head, n)] if tool == "eslint" else []
            if ignored:
                lines.insert(1, f"NOT READ: {' '.join(ignored)} is still in the head tree, but nothing loads it")
        results.append(result(sample, status, lines, diff))
    return results or [result(tool, "skipped", ["no sample file in both trees"])]


def probe_eslint(base, head, explicit, full):
    kinds = ((".tsx", False), (".ts", False), (".jsx", False), (".js", False), (".tsx", True), (".ts", True), (".js", True))
    samples = pick_samples(base, head, explicit, kinds)
    bundled = (("eslint.config.cjs", ()), (".eslintrc.js", ("--no-eslintrc",)))
    return probe_config("eslint", base, head, samples, "node_modules/.bin/eslint", bundled, "lint-js", full)


def probe_stylelint(base, head, explicit, full):
    samples = pick_samples(base, head, explicit, ((".scss", False), (".css", False)))
    bundled = ((".stylelintrc.json", ()),)
    binary = "node_modules/.bin/stylelint"
    return probe_config("stylelint", base, head, samples, binary, bundled, "lint-style", full, stylelint_normalizer)


def tsc_config(tree):
    code, out, err = run([tool_path(tree, "node_modules/.bin/tsc"), "--showConfig"], tree)
    if code != 0:
        return None, first_error(out, err)
    try:
        return json.loads(out), None
    except ValueError:
        return None, "the output is not JSON"


def probe_tsc(base, head, full):
    if not tool_path(base, "tsconfig.json"):
        return [result("tsconfig", "skipped", ["no tsconfig.json"])]
    missing = missing_tool("tsconfig", base, head, "node_modules/.bin/tsc", ("tsconfig.json",))
    if missing:
        return missing
    old, old_err = tsc_config(base)
    new, new_err = tsc_config(head)
    if old_err or new_err:
        return [result("tsconfig", "failed", [f"{s}: {e}" for s, e in (("base", old_err), ("head", new_err)) if e])]
    old_opts, new_opts = old.get("compilerOptions", {}), new.get("compilerOptions", {})
    changed = sorted(k for k in set(old_opts) | set(new_opts) if old_opts.get(k) != new_opts.get(k))
    lines = [f"{k}: {old_opts.get(k)} -> {new_opts.get(k)}" for k in changed]
    weakened = [k for k in TSC_CHECKS if k in tsc_checks_on(old_opts) - tsc_checks_on(new_opts)]
    if weakened:
        lines.insert(0, names("WEAKENED checks no longer on", weakened, full))
    old_files, new_files = len(old.get("files", [])), len(new.get("files", []))
    if old_files != new_files:
        lines.append(f"files: {old_files} -> {new_files}")
    status = "lost" if new_files < old_files or weakened else ("changed" if lines else "same")
    return [result("tsconfig", status, lines, {"changed": changed, "weakened": weakened})]


def tsc_checks_on(options):
    """The checks in effect: set to true, or left unset under strict when strict covers them."""
    strict = options.get("strict") is True
    return {k for k in TSC_CHECKS
            if options.get(k) is True or (options.get(k) is None and strict and k in STRICT_FAMILY)}


def relative_lines(out, tree):
    root = os.path.realpath(tree) + os.sep
    return {line.strip().replace(root, "").replace(tree + os.sep, "") for line in out.splitlines() if line.strip()}


def probe_list(subject, base, head, command_for, keep, full, label="tests listed", clean=lambda line: line):
    """Compare what a test runner would run. An empty list on one side is a failure too."""
    listed = []
    for tree in (base, head):
        code, out, err = run(command_for(tree), tree)
        items = {clean(line) for line in relative_lines(out, tree) if keep(line)}
        listed.append((code, items, first_error(err, out)))
    (old_code, old, old_err), (new_code, new, new_err) = listed
    failures = [f"{side}: {err}" for side, code, items, err in
                (("base", old_code, old, old_err), ("head", new_code, new, new_err)) if code != 0 or not items]
    if failures:
        return [result(subject, "failed", failures)]
    diff = compare_sets(old, new)
    lines = [f"{label}: base {len(old)}, head {len(new)}"]
    if diff["lost"]:
        lines.append(names("LOST", diff["lost"], full))
    if diff["gained"]:
        lines.append(names("gained", diff["gained"], full))
    return [result(subject, "lost" if diff["lost"] else ("changed" if diff["gained"] else "same"), lines, diff)]


def bundled_jest_config(tree):
    """wp-scripts test-unit-js passes its bundled config as JSON when the project has none, so the
    rootDir is the tree, not node_modules. Do the same."""
    path = tool_path(tree, f"{WP_CONFIG}/jest-unit.config.js")
    if not path:
        return None, f"{WP_CONFIG}/jest-unit.config.js is missing: install the dependencies"
    code, out, err = run(["node", "-e", "process.stdout.write(JSON.stringify(require(process.argv[1])))", path], tree)
    return (out, None) if code == 0 and out.startswith("{") else (None, first_error(err, out))


def probe_jest(base, head, config, full):
    if not config:
        config, failure = script_config(base, "jest", JEST_COMMANDS, "--jest-config")
        if failure:
            return [failure]
    config = config or next((name for name in JEST_CONFIGS if tool_path(base, name)), None)
    if config:
        label, args = config, {base: ["--config", config], head: ["--config", config]}
    elif "jest" in package_json(base):
        label, args = "package.json", {base: [], head: []}  # Jest reads the key by itself
    elif wp_scripts_runs(base, "test-unit-js"):
        label, args = "wp-scripts' bundled jest-unit.config.js", {}
        errors = []
        for side, tree in (("base", base), ("head", head)):
            json_config, error = bundled_jest_config(tree)
            if error:
                errors.append(f"{side}: {error}")
            args[tree] = ["--config", json_config]
        if errors:
            return [result(f"jest ({label})", "failed", errors)]
    elif scripts_use(base, "jest"):
        return [result("jest", "failed", ["package.json runs Jest, but no config was found: pass --jest-config"])]
    else:
        return [result("jest", "skipped", ["no Jest config, and package.json does not run Jest"])]
    command = lambda tree: [os.path.join(tree, "node_modules/.bin/jest"), "--listTests", *args[tree]]
    keep = lambda line: not line.startswith(("Error", "at "))
    return probe_list(f"jest ({label})", base, head, command, keep, full, label="test files listed")


def probe_playwright(base, head, config, full):
    binary = "node_modules/.bin/playwright"
    bundled = f"{WP_CONFIG}/playwright.config.js"
    if not config:
        config, failure = script_config(base, "playwright", PLAYWRIGHT_COMMANDS, "--playwright-config")
        if failure:
            return [failure]
    if config:
        subject, args = f"playwright ({config})", ["--config", config]
    elif any(tool_path(base, name) for name in PLAYWRIGHT_CONFIGS):
        subject, args = "playwright", []
    elif wp_scripts_runs(base, "test-playwright"):
        # What wp-scripts test-playwright runs when the project has no config of its own.
        subject, args = "playwright (wp-scripts' bundled playwright.config.js)", ["--config", bundled]
        missing = [side for side, tree in (("base", base), ("head", head)) if not tool_path(tree, bundled)]
        if missing:
            return [result(subject, "failed", [f"{side}: {bundled} is missing: install the dependencies" for side in missing])]
    elif scripts_use(base, "playwright"):
        return [result("playwright", "failed", ["package.json runs Playwright, but no config was found: pass --playwright-config"])]
    else:
        return [result("playwright", "skipped", ["no Playwright config, and package.json does not run it"])]
    if not (tool_path(base, binary) and tool_path(head, binary)):
        return [result(subject, "failed", [f"{binary} is missing in a tree: install the dependencies, or leave the tool out with --only"])]
    command = lambda tree: [os.path.join(tree, binary), "test", "--list", *args]
    # An edit above a test moves its line number; that is the same test.
    clean = lambda line: re.sub(r":\d+:\d+", "", line)
    return probe_list(subject, base, head, command, lambda line: "\u203a" in line, full, clean=clean)


def probe_phpunit(base, head, config, full):
    missing = missing_tool("phpunit", base, head, "vendor/bin/phpunit", ("phpunit.xml", "phpunit.xml.dist"))
    if missing:
        return missing
    args = ["--configuration", config] if config else []
    command = lambda tree: [os.path.join(tree, "vendor/bin/phpunit"), *args, "--list-tests"]
    return probe_list("phpunit", base, head, command, lambda line: line.startswith("- "), full)


def sniffs(tree):
    code, out, err = run([os.path.join(tree, "vendor/bin/phpcs"), "-e"], tree)
    found = {m.group(1) for m in map(SNIFF.match, out.splitlines()) if m}
    if code != 0 or not found:
        return None, first_error(err, out)
    return found, None


def standards(tree):
    _, out, _ = run([os.path.join(tree, "vendor/bin/phpcs"), "-i"], tree)
    text = out.replace("The installed coding standards are", "").replace(" and ", ", ")
    return {item.strip(" .\n") for item in text.split(",") if item.strip(" .\n")}


def probe_phpcs(base, head, full):
    configs = ("phpcs.xml", "phpcs.xml.dist", ".phpcs.xml", ".phpcs.xml.dist")
    missing = missing_tool("phpcs", base, head, "vendor/bin/phpcs", configs)
    if missing:
        return missing
    old, old_err = sniffs(base)
    new, new_err = sniffs(head)
    if old_err or new_err:
        return [result("phpcs", "failed", [f"{s}: {e}" for s, e in (("base", old_err), ("head", new_err)) if e])]
    diff = compare_sets(old, new)
    lost_standards = sorted(standards(base) - standards(head))
    lines = [f"sniffs: base {len(old)}, head {len(new)}"]
    if diff["lost"]:
        lines.append(names("LOST", diff["lost"], full))
    if diff["gained"]:
        lines.append(names("gained", diff["gained"], full))
    if lost_standards:
        lines.append(names("LOST standards", lost_standards, full))
    lost = diff["lost"] or lost_standards
    return [result("phpcs", "lost" if lost else ("changed" if diff["gained"] else "same"), lines, diff)]


def phpstan_parameters(tree):
    code, out, err = run([os.path.join(tree, "vendor/bin/phpstan"), "dump-parameters", "--json"], tree)
    if code != 0:
        return None, first_error(err, out)
    text = out.replace(os.path.realpath(tree), "<root>").replace(tree, "<root>")
    start = text.find("{")
    try:
        return json.loads(text[start:]), None
    except ValueError:
        return None, "the output is not JSON"


def probe_phpstan(base, head, full):
    missing = missing_tool("phpstan", base, head, "vendor/bin/phpstan", ("phpstan.neon", "phpstan.neon.dist"))
    if missing:
        return missing
    old, old_err = phpstan_parameters(base)
    new, new_err = phpstan_parameters(head)
    if old_err or new_err:
        return [result("phpstan", "failed", [f"{s}: {e}" for s, e in (("base", old_err), ("head", new_err)) if e])]
    changed = sorted(k for k in set(old) | set(new) if old.get(k) != new.get(k))
    lines = []
    for key in changed:
        before, after = json.dumps(old.get(key), sort_keys=True), json.dumps(new.get(key), sort_keys=True)
        lines.append(f"{key}: {before[:120]} -> {after[:120]}")
    if not changed:
        lines.append(f"level {old.get('level')}, same parameters")
    level_dropped = str(new.get("level")) != str(old.get("level"))
    return [result("phpstan", "lost" if level_dropped else ("changed" if changed else "same"), lines, {"changed": changed})]


ASSET_DEPS = re.compile(r"""['"]dependencies['"]\s*=>\s*(?:array\(|\[)(.*?)(?:\)|\])""", re.S)


def asset_entries(tree, build_dir):
    folders = [build_dir] if build_dir else ["build", "assets/build", "dist"]
    entries = {}
    for folder in folders:
        root = os.path.join(tree, folder)
        for current, _, files in os.walk(root):
            for name in files:
                if name.endswith(".asset.php"):
                    path = os.path.join(current, name)
                    with open(path, encoding="utf-8") as handle:
                        found = ASSET_DEPS.search(handle.read())
                    deps = set(re.findall(r"""['"]([^'"]+)['"]""", found.group(1))) if found else set()
                    entries[os.path.relpath(path, root)] = deps
    return entries


def probe_assets(base, head, build_dir, full):
    old, new = asset_entries(base, build_dir), asset_entries(head, build_dir)
    if old and not new or new and not old:
        # Either the build did not run in one tree, or the build stopped writing them.
        side = "base" if old else "head"
        return [result("assets", "failed", [f"only the {side} has *.asset.php: run the build in both trees, "
                                            "or the build no longer writes them"])]
    if not old and not new:
        if scripts_use(base, "wp-scripts build", "webpack"):
            return [result("assets", "failed", ["package.json builds with wp-scripts or webpack, but there is no "
                                                "*.asset.php: run the build in both trees, or pass --build-dir"])]
        return [result("assets", "skipped", ["no *.asset.php, and package.json does not build with wp-scripts or webpack"])]
    lines = []
    for entry in sorted(set(old) | set(new)):
        if entry not in old or entry not in new:
            lines.append(f"{entry}: only in {'head' if entry not in old else 'base'}")
        elif old[entry] != new[entry]:
            removed, added = sorted(old[entry] - new[entry]), sorted(new[entry] - old[entry])
            lines.append(f"{entry}: dependencies -{removed} +{added}")
    if not lines:
        lines.append(f"{len(old)} entries, the same script dependencies")
        return [result("assets", "same", lines)]
    return [result("assets", "changed", lines)]


# ---- report ---------------------------------------------------------------------------------------


def merge_same(rows):
    """Samples with the same answer print as one: the differences are what the reader looks for."""
    merged = {}
    for row in rows:
        key = (row["status"], tuple(row["lines"]))
        if key in merged:
            merged[key]["subject"] += f", {row['subject']}"
        else:
            merged[key] = dict(row)
    return list(merged.values())


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--base")
    parser.add_argument("--head")
    parser.add_argument("--sample", action="append", default=[])
    parser.add_argument("--only", default=",".join(ALL_TOOLS))
    parser.add_argument("--jest-config")
    parser.add_argument("--playwright-config")
    parser.add_argument("--phpunit-config")
    parser.add_argument("--build-dir")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args = parser.parse_args()

    if args.help:
        print(__doc__)
        return 0
    if not args.base or not args.head:
        print("rules-diff: --base and --head are required", file=sys.stderr)
        return 2
    for tree in (args.base, args.head):
        if not os.path.isdir(tree):
            print(f"rules-diff: no such directory: {tree}", file=sys.stderr)
            return 2
    tools = [t.strip() for t in args.only.split(",") if t.strip()]
    unknown = [t for t in tools if t not in ALL_TOOLS]
    if unknown:
        print(f"rules-diff: unknown tool: {' '.join(unknown)}", file=sys.stderr)
        return 2

    base, head = os.path.abspath(args.base), os.path.abspath(args.head)
    probes = {
        "eslint": lambda: probe_eslint(base, head, args.sample, args.full),
        "stylelint": lambda: probe_stylelint(base, head, args.sample, args.full),
        "tsc": lambda: probe_tsc(base, head, args.full),
        "jest": lambda: probe_jest(base, head, args.jest_config, args.full),
        "playwright": lambda: probe_playwright(base, head, args.playwright_config, args.full),
        "phpcs": lambda: probe_phpcs(base, head, args.full),
        "phpstan": lambda: probe_phpstan(base, head, args.full),
        "phpunit": lambda: probe_phpunit(base, head, args.phpunit_config, args.full),
        "assets": lambda: probe_assets(base, head, args.build_dir, args.full),
    }

    report = {tool: merge_same(probes[tool]()) for tool in tools}
    flagged = [r for rows in report.values() for r in rows if r["status"] in ("lost", "failed")]

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        code, out, _ = run(["node", "-v"], head)
        print(f"node {out.strip() if code == 0 else 'not found'} · base {base} · head {head}")
        for tool, rows in report.items():
            for row in rows:
                print(f"\n[{row['status'].upper()}] {tool}: {row['subject']}")
                for line in row["lines"]:
                    print(f"  {line}")
        skipped = [t for t, rows in report.items() if all(r["status"] == "skipped" for r in rows)]
        print(f"\nsummary: flagged={len(flagged)} skipped={' '.join(skipped) or 'none'}")
        if any(row["status"] == "failed" for row in flagged):
            print("hint: FAILED can also mean a CI preparation step was skipped (composer install, a build, Strauss)")

    return 1 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
