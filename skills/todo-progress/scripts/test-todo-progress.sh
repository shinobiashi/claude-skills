#!/usr/bin/env bash
# Scenario tests for todo-progress.sh on throwaway Markdown files (no network).
# Usage: bash test-todo-progress.sh [path/to/todo-progress.sh]
# Uses the awk on PATH; run it where mawk or busybox awk is the awk to test those too.
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/todo-progress.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
# run ARGS...: the output in $OUT, the exit status in $RC.
run() { OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }
hasnt() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then bad "$1 (unexpected line: $2)"; else ok "$1"; fi }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }

echo "todo-progress.sh"

# Counting -------------------------------------------------------------------------------------

cat >"$W/count.md" <<'EOF'
- [x] before any heading
# Title

## 1. Setup
- [x] a
- [ ] b
- [ ] c
### 1.1 Sub
- [x] a deeper heading counts toward its section
  - [X] upper-case, nested
* [x] star marker
+ [ ] plus marker
1. [x] numbered
2) [ ] numbered with a parenthesis
- [x]no space after the box is not a task
> - [ ] a quote is not a task
- `- [ ]` in code text is not a task

## 2. Fences ##
```bash
- [ ] in a backtick fence
## Not a heading
```
~~~
- [x] in a tilde fence
~~~
- [x] after the fences

## 3. No boxes
Just text.
EOF

run "$W/count.md"
status "counts without --check exit 0" 0
has "items before the first heading get their own line" "   1 /    1  100%  (before the first heading)"
has "deeper headings, markers and indents count toward the section" "   5 /    9   55%  ## 1. Setup"
has "fences are skipped and closing hashes are dropped" "   1 /    1  100%  ## 2. Fences"
hasnt "a heading inside a fence is not a section" "Not a heading"
hasnt "a section without boxes is not listed" "No boxes"
has "the total line, truncated percent" "   7 /   11   63%  合計"

run --level 3 "$W/count.md"
has "--level 3 makes a ### heading a section up to the next heading" "   4 /    6   66%  ### 1.1 Sub"
has "--level 3 leaves the boxes before it in the ## section" "   1 /    3   33%  ## 1. Setup"

printf '## A\r\n- [x] one\r\n- [ ] two\r\n' >"$W/crlf.md"
run "$W/crlf.md"
has "CRLF lines are counted and the title has no CR" "   1 /    2   50%  ## A"

run --total-label Total "$W/crlf.md"
has "--total-label names the total line" "   1 /    2   50%  Total"

: >"$W/empty.md"
run "$W/empty.md"
status "an empty file exits 0" 0
has "an empty file totals 0 / 0" "   0 /    0    0%  合計"

# Japanese text with a UTF-8 locale: macOS awk failed ("towc: multibyte conversion failure") when a
# pattern met a single byte of a multibyte character.
cat >"$W/ja.md" <<'EOF'
| 節 | 完了 / 全体 | 進捗 |
| --- | --- | --- |
| 2. 起動処理 | 1 / 2 | 50% |
| **合計** | **1 / 2** | **50%** |

## 2. 起動処理（ADR-0001。PR #9）
- [x] 実装
- [ ] テスト
EOF
OUT="$(LC_ALL=en_US.UTF-8 bash "$SCRIPT" --check "$W/ja.md" 2>&1)"; RC=$?
status "Japanese titles under a UTF-8 locale pass --check" 0
has "a label matches the start of a Japanese title" "RESULT: the summary table matches the counts (2 rows)"

# --check ----------------------------------------------------------------------------------------

cat >"$W/table.md" <<'EOF'
| Section | Done / Total | % | Note |
| --- | --- | --- | --- |
| Phase 1 | 2 / 3 | 66% | the start of "Phase 1 — Setup" |
| [Phase 10](#phase-10) | **2 / 3** | **66%** | a link and bold |
| Phase 2 — Big | 1,000 / 1,000 | 100% | thousands separators |
| | **Total** | **1,004 / 1,006** | **99%** |

## Phase 1 — Setup
- [x] a
- [x] b
- [ ] c

## Phase 10
- [x] a
- [x] b
- [ ] c

## Phase 2 — Big
EOF
# 1,000 boxes, all done.
for _ in $(seq 1 1000); do echo "- [x] item"; done >>"$W/table.md"

run --check --total-label Total "$W/table.md"
status "a matching table exits 0" 0
has "prefix labels, links, bold, separators and an empty first cell all match" "RESULT: the summary table matches the counts (4 rows)"
hasnt "Phase 1 does not also match Phase 10" "more than one section"

sed 's#| Phase 1 | 2 / 3 | 66% |#| Phase 1 | 1 / 3 | 33% |#' "$W/table.md" >"$W/stale.md"
run --check --total-label Total "$W/stale.md"
status "a stale row exits 1" 1
has "the stale row is reported with both counts and its line" "NG    line 3: Phase 1 — the table says 1 / 3 (33%), the count is 2 / 3 (66%)"
has "the result counts the problems" "RESULT: 1 problem(s) — update the summary table"

sed 's#| Phase 1 | 2 / 3 | 66% |#| Phase 1 | 2 / 3 | 67% |#' "$W/table.md" >"$W/percent.md"
run --check --total-label Total "$W/percent.md"
status "a rounded (not truncated) percent exits 1" 1
has "a percent-only mismatch is reported" "NG    line 3: Phase 1 — the table says 2 / 3 (67%), the count is 2 / 3 (66%)"

cat >"$W/nopercent.md" <<'EOF'
| Section | Done / Total | State |
| --- | --- | --- |
| A | 1 / 2 | half |
| 合計 | 1 / 2 | |

## A
- [x] a
- [ ] b
EOF
run --check "$W/nopercent.md"
status "a table without a percent column passes" 0

cat >"$W/missing.md" <<'EOF'
| Section | Done / Total | % |
| --- | --- | --- |
| A | 1 / 1 | 100% |
| Gone | 3 / 3 | 100% |

## A
- [x] a

## B
- [ ] b
EOF
run --check "$W/missing.md"
status "a section without a row exits 1" 1
has "the section without a row is reported" "NG    ## B has no row in the summary table"
has "the missing total row is reported" "NG    the summary table has no \"合計\" row"
has "a row of no section is only a note" "NOTE  line 4: \"Gone\" matches no section (ignored)"

cat >"$W/ambiguous.md" <<'EOF'
| Section | Done / Total |
| --- | --- |
| Phase | 1 / 2 |
| 合計 | 1 / 2 |

## Phase A
- [x] a

## Phase B
- [ ] b
EOF
run --check "$W/ambiguous.md"
status "a label of two sections exits 1" 1
has "the ambiguous label is reported" "NG    line 3: \"Phase\" matches more than one section"

cat >"$W/zero.md" <<'EOF'
| Section | Done / Total | % |
| --- | --- | --- |
| A | 0 / 2 | 0% |
| 合計 | 0 / 2 | 0% |

## A
- [ ] a
- [ ] b
EOF
run --check "$W/zero.md"
status "a section with nothing done matches 0 / N (0%)" 0

cat >"$W/fenced-table.md" <<'EOF'
```
| A | 1 / 1 | 100% |
```
## A
- [x] a
EOF
run --check "$W/fenced-table.md"
status "a table inside a fence is not the summary table" 2

run --check "$W/crlf.md"
status "no summary table exits 2" 2
has "no summary table is said" "NO TABLE  no table row with a section title and \"done / total\" was found"

# Arguments and the default file ------------------------------------------------------------------

run --help
status "--help exits 0" 0
has "--help shows the usage" "Usage (installed at ~/.claude/skills/todo-progress/scripts/todo-progress.sh):"
run --level 9
status "--level out of range exits 2" 2
run --total-label
status "--total-label without a label exits 2" 2
run --nope
status "an unknown option exits 2" 2
run "$W/count.md" "$W/crlf.md"
status "two files exit 2" 2
run "$W/none.md"
status "a missing file exits 2" 2

if command -v git >/dev/null; then
	git init -q "$W/repo"
	printf '## Top\n- [x] top\n' >"$W/repo/TODO.md"
	mkdir -p "$W/repo/sub/dir"
	OUT="$(cd "$W/repo/sub/dir" && bash "$SCRIPT" 2>&1)"; RC=$?
	status "from a subdirectory of a repository without TODO.md" 0
	has "the TODO.md at the top of the repository is read" "## Top"
	printf '## Here\n- [ ] here\n' >"$W/repo/sub/TODO.md"
	OUT="$(cd "$W/repo/sub" && bash "$SCRIPT" 2>&1)"; RC=$?
	has "a TODO.md in the current directory comes first" "## Here"
else
	echo "  skip - the default file in a repository (no git)"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
