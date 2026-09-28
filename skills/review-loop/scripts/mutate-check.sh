#!/usr/bin/env bash
# mutate-check.sh — prove that a test actually pins a guard.
#
# Breaks one guard on purpose, runs the tests that claim to cover it, and
# restores the file no matter how the run ends. Answers one question: did the
# test notice?
#
# Why a script: the manual sequence (back up, edit, run, restore, confirm the
# tree is clean) is short but has two failure modes that are easy to hit and
# expensive to miss — leaving a mutated file behind in a shared working tree,
# and mutating something that turns out to be a no-op, which makes the tests
# pass for the wrong reason and reads as "the guard is covered".
#
# Usage:
#   mutate-check.sh --file <path> --test-cmd <cmd> <mutation> [options]
#
# Mutation (exactly one):
#   --delete-matching <ERE>        delete every line matching the regex
#   --replace <OLD> <NEW>          literal replacement of the first occurrence
#   --replace-file <OLD> <NEW>     same, with both sides read from files
#                                  (for multi-line bodies)
#   --apply <script>               run an executable that mutates the file;
#                                  it receives the path as $1
#
# Options:
#   --expect <REGEX>   additionally require a failure header naming this test
#                      (PHPUnit "1) Name", Vitest "× name" / "FAIL  file > name",
#                      Jest "✕ name" / "● Suite › name"; override with
#                      --failure-line)
#   --failure-line <ERE>  what a failure header looks like
#                         (default: any of the above, see FAILURE_LINE)
#   --only             with --expect: every failing test must match it, or the
#                      verdict is NOT CAUGHT CLEANLY (the mutation broke more
#                      than the guard). Without it, other failures only warn
#   --allow-errors     accept a run whose output shows the code itself broke
#                      (see BROKEN_LINE); by default that is NOT CAUGHT
#   --dry-run          show the mutation diff, restore, and stop
#   --quiet            only print the verdict
#
# --test-cmd may also come from $MUTATE_CHECK_TEST_CMD. Filter it down to the
# tests under examination — the verdict keys on its exit status.
#
# A mutation that breaks the code rather than the guard (a parse error, a
# class or function that no longer exists — e.g. a replacement naming a class
# the file does not import) fails every test, the named one included, and
# would read as CAUGHT while proving nothing. Such a run is reported as
# BROKEN, and failures of tests other than --expect are reported.
#
# Exit codes:
#   0  the mutation was caught (the guard is genuinely covered)
#   1  the mutation was NOT caught (tests passed, the wrong test failed, the
#      mutation broke the code, or --only saw other tests fail)
#   2  setup error — nothing was concluded (and the file is restored)

set -uo pipefail

PROG="$(basename "$0")"

die() {
	printf '%s: %s\n' "$PROG" "$1" >&2
	exit 2
}

FILE=""
TEST_CMD="${MUTATE_CHECK_TEST_CMD:-}"
EXPECT=""
# Failure headers that name the test: PHPUnit "1) Class::test", Vitest
# "  × name 12ms" and " FAIL  file > suite > name", Jest "  ✕ name (5 ms)"
# and "  ● Suite › name". Written as an alternation, not a bracket
# expression, so the multi-byte marks match in any locale.
FAILURE_LINE='^[[:space:]]*([0-9]+\)|×|✕|●|FAIL[[:space:]])'
# The code did not load or compile: PHP parse errors and missing
# classes / functions, JS syntax and reference errors. A null dereference or a
# type error is left out on purpose: breaking a guard legitimately causes them.
BROKEN_LINE='(Parse error|ParseError|syntax error, unexpected|(Class|Interface|Trait|Enum) "[^"]+" not found|Call to undefined (function|method)|Cannot redeclare|SyntaxError|ReferenceError)'
ONLY=0
ALLOW_ERRORS=0
DRY_RUN=0
QUIET=0
MUTATION=""
ARG1=""
ARG2=""

set_mutation() {
	[ -z "$MUTATION" ] || die "choose one mutation, got --$MUTATION and --$1"
	MUTATION="$1"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--file) FILE="${2:-}"; shift 2 ;;
		--test-cmd) TEST_CMD="${2:-}"; shift 2 ;;
		--expect) EXPECT="${2:-}"; shift 2 ;;
		--failure-line) FAILURE_LINE="${2:-}"; shift 2 ;;
		--only) ONLY=1; shift ;;
		--allow-errors) ALLOW_ERRORS=1; shift ;;
		--dry-run|-n) DRY_RUN=1; shift ;;
		--quiet|-q) QUIET=1; shift ;;
		--delete-matching) set_mutation delete-matching; ARG1="${2:-}"; shift 2 ;;
		--replace) set_mutation replace; ARG1="${2:-}"; ARG2="${3:-}"; shift 3 ;;
		--replace-file) set_mutation replace-file; ARG1="${2:-}"; ARG2="${3:-}"; shift 3 ;;
		--apply) set_mutation apply; ARG1="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "$FILE" ] || die "--file is required"
[ -f "$FILE" ] || die "no such file: $FILE"
[ -n "$MUTATION" ] || die "a mutation is required (--delete-matching / --replace / --replace-file / --apply)"
[ "$ONLY" -eq 0 ] || [ -n "$EXPECT" ] || die "--only needs --expect (the tests that are allowed to fail)"
if [ "$DRY_RUN" -eq 0 ]; then
	[ -n "$TEST_CMD" ] || die "--test-cmd is required (or set MUTATE_CHECK_TEST_CMD)"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"

# The file has to start clean, or "restored" cannot be verified afterwards.
if ! git diff --quiet -- "$FILE" 2>/dev/null || ! git diff --cached --quiet -- "$FILE" 2>/dev/null; then
	die "$FILE has uncommitted changes; commit or stash them first so the restore can be verified"
fi

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }

WORK_DIR="$(mktemp -d)"
BACKUP="$WORK_DIR/$(basename "$FILE")"
OUT_FILE="$WORK_DIR/out.txt"
cp "$FILE" "$BACKUP"

RESTORED=0
# Restoring and cleaning up are deliberately separate: the runner's output
# lives in the same directory, and the verdict is read from it *after* the
# file has been put back.
restore() {
	[ "$RESTORED" -eq 0 ] || return 0
	RESTORED=1
	cp "$BACKUP" "$FILE"
}
cleanup() { restore; rm -rf "$WORK_DIR"; }
trap 'cleanup' EXIT
trap 'cleanup; exit 2' INT TERM

apply_mutation() {
	case "$MUTATION" in
		delete-matching)
			MC_RE="$ARG1" python3 - "$FILE" <<-'PY'
				import os, re, sys
				path = sys.argv[1]
				pattern = re.compile(os.environ["MC_RE"])
				with open(path, encoding="utf-8") as fh:
				    lines = fh.readlines()
				kept = [l for l in lines if not pattern.search(l)]
				with open(path, "w", encoding="utf-8") as fh:
				    fh.writelines(kept)
			PY
			;;
		replace)
			MC_OLD="$ARG1" MC_NEW="$ARG2" python3 - "$FILE" <<-'PY'
				import os, sys
				path = sys.argv[1]
				old, new = os.environ["MC_OLD"], os.environ["MC_NEW"]
				with open(path, encoding="utf-8") as fh:
				    body = fh.read()
				with open(path, "w", encoding="utf-8") as fh:
				    fh.write(body.replace(old, new, 1))
			PY
			;;
		replace-file)
			[ -f "$ARG1" ] || die "--replace-file: no such file: $ARG1"
			[ -f "$ARG2" ] || die "--replace-file: no such file: $ARG2"
			MC_OLD_F="$ARG1" MC_NEW_F="$ARG2" python3 - "$FILE" <<-'PY'
				import os, sys
				path = sys.argv[1]
				old = open(os.environ["MC_OLD_F"], encoding="utf-8").read()
				new = open(os.environ["MC_NEW_F"], encoding="utf-8").read()
				with open(path, encoding="utf-8") as fh:
				    body = fh.read()
				with open(path, "w", encoding="utf-8") as fh:
				    fh.write(body.replace(old, new, 1))
			PY
			;;
		apply)
			[ -x "$ARG1" ] || die "--apply: not executable: $ARG1"
			"$ARG1" "$FILE" || die "--apply: mutation script failed"
			;;
	esac
}

apply_mutation || die "could not apply the mutation"

# A mutation that changed nothing would let the tests pass for the wrong
# reason and read as "the guard is covered". This is the trap worth catching.
if git diff --quiet -- "$FILE"; then
	die "the mutation changed nothing in $FILE — it did not match, so the run would prove nothing"
fi

if [ "$DRY_RUN" -eq 1 ]; then
	say "--- mutation (not run, will be restored) ---"
	git --no-pager diff -- "$FILE"
	restore
	git diff --quiet -- "$FILE" || die "RESTORE FAILED — $FILE still differs; recover it by hand"
	say "restored."
	exit 0
fi

say "--- mutation applied to $FILE ---"
[ "$QUIET" -eq 1 ] || git --no-pager diff --stat -- "$FILE"
say "--- running: $TEST_CMD ---"

bash -c "$TEST_CMD" >"$OUT_FILE" 2>&1
TEST_STATUS=$?

restore
if ! git diff --quiet -- "$FILE"; then
	printf '%s: RESTORE FAILED — %s still differs from HEAD. Recover it by hand.\n' "$PROG" "$FILE" >&2
	exit 2
fi
say "--- restored, working tree clean for $FILE ---"

# Collected once, without a pipe: `grep -q` closes the pipe on its first
# match, which SIGPIPEs the upstream grep, and `pipefail` would then report
# the whole pipeline as failed — turning a match into a miss.
FAILING="$(grep -E "$FAILURE_LINE" "$OUT_FILE" || true)"
BROKEN="$(grep -E "$BROKEN_LINE" "$OUT_FILE" | head -3 || true)"
OTHERS=""
if [ -n "$EXPECT" ] && [ -n "$FAILING" ]; then
	OTHERS="$(grep -Ev "$EXPECT" <<<"$FAILING" || true)"
fi

VERDICT=0
if [ "$TEST_STATUS" -eq 0 ]; then
	printf 'NOT CAUGHT: the tests passed with the guard broken — nothing covers it.\n'
	VERDICT=1
elif [ -n "$BROKEN" ] && [ "$ALLOW_ERRORS" -eq 0 ]; then
	printf 'BROKEN: the mutation broke the code, not the guard — the failures prove nothing.\n'
	printf 'Rewrite the mutation so the file still loads (or pass --allow-errors if this is intended):\n'
	printf '%s\n' "$BROKEN"
	VERDICT=1
elif [ "$ONLY" -eq 1 ] && [ -n "$OTHERS" ]; then
	printf 'NOT CAUGHT CLEANLY: tests other than %s failed too — the mutation breaks more than the guard.\n' "$EXPECT"
	VERDICT=1
elif [ -n "$EXPECT" ]; then
	if [ -n "$FAILING" ] && grep -Eq "$EXPECT" <<<"$FAILING"; then
		printf 'CAUGHT: a failing test matches %s.\n' "$EXPECT"
	else
		printf 'NOT CAUGHT BY THE NAMED TEST: the run failed, but no failure header matched %s.\n' "$EXPECT"
		printf 'Something else broke, or the test that should pin this is a different one.\n'
		VERDICT=1
	fi
else
	printf 'CAUGHT: the tests failed with the guard broken.\n'
fi

if [ "$VERDICT" -eq 0 ] && [ -n "$OTHERS" ]; then
	printf 'WARNING: %s other failing test(s) besides %s — check they fail for the same reason (--only makes this a failure).\n' "$(grep -c . <<<"$OTHERS")" "$EXPECT"
fi

if { [ "$QUIET" -eq 0 ] || [ "$VERDICT" -ne 0 ]; } && [ -n "$FAILING" ]; then
	printf -- '--- failing tests ---\n'
	printf '%s\n' "$FAILING" | head -20
fi

exit "$VERDICT"
