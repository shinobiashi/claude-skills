#!/usr/bin/env bash
#
# Counts the checkboxes of a Markdown checklist (TODO.md) per section, for the progress summary that
# each PR updates, and checks the summary table against the counts. Part of the shared todo-progress
# skill; works on the TODO.md of any repository.
#
# Usage (installed at ~/.claude/skills/todo-progress/scripts/todo-progress.sh):
#   bash todo-progress.sh [FILE]           # print "done / total  percent  section" and the total
#   bash todo-progress.sh --check [FILE]   # also compare them with the summary table in FILE
#
# FILE defaults to TODO.md in the current directory, else at the top of the git repository.
#
# Options:
#   --check              compare the counts with the summary table: rows of a table with a section
#                        title (or its start, "2. Boot" for "## 2. Boot (ADR-0001)") and "done / total",
#                        optionally followed by a "percent%" cell, plus the total row. Exits 1 on a
#                        mismatch or a section without a row, 2 if FILE has no such row
#   --level N            the heading level of a section (default 2, "## "). Deeper headings count
#                        toward the section above them
#   --total-label LABEL  the label of the total line and of the total row (default 合計)
#   -h, --help           show this help
#
# Checkboxes are task list items ("- [ ]", "- [x]", also "[X]" and the "*", "+", "1." markers) at
# any indent; fenced code blocks are skipped. Sections without checkboxes are not listed.
# Percentages are truncated, not rounded (65 / 102 is 63%).

set -uo pipefail

FILE=""
CHECK=0
LEVEL=2
TOTAL_LABEL="合計"

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK=1; shift ;;
		--level)
			[[ "${2:-}" =~ ^[1-6]$ ]] || { echo "--level needs a heading level from 1 to 6" >&2; exit 2; }
			LEVEL="$2"; shift 2 ;;
		--total-label)
			[ -n "${2:-}" ] || { echo "--total-label needs a label" >&2; exit 2; }
			TOTAL_LABEL="$2"; shift 2 ;;
		-h | --help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
		*)
			[ -z "$FILE" ] || { echo "more than one file: $1 (see --help)" >&2; exit 2; }
			FILE="$1"; shift ;;
	esac
done

if [ -z "$FILE" ]; then
	FILE="TODO.md"
	if [ ! -f "$FILE" ] && TOP="$(git rev-parse --show-toplevel 2>/dev/null)"; then
		FILE="$TOP/TODO.md"
	fi
fi
[ -f "$FILE" ] || { echo "not found: $FILE" >&2; exit 2; }

# POSIX awk only (macOS awk, gawk, mawk). In bytes (LC_ALL=C): the patterns are ASCII, and macOS awk
# fails on a UTF-8 locale when a pattern meets an invalid byte. Section 0 holds the checkboxes before
# the first heading.
LC_ALL=C awk -v level="$LEVEL" -v check="$CHECK" -v total_label="$TOTAL_LABEL" '
	function trim(s) {
		sub(/^[ \t]+/, "", s)
		sub(/[ \t]+$/, "", s)
		return s
	}
	# The text of a heading or a table cell without emphasis and link targets.
	function plain(s,    link) {
		gsub(/\*\*|__/, "", s)
		while (match(s, /\[[^]]*\]\([^)]*\)/)) {
			link = substr(s, RSTART, RLENGTH)
			s = substr(s, 1, RSTART - 1) substr(link, 2, index(link, "](") - 2) substr(s, RSTART + RLENGTH)
		}
		return trim(s)
	}
	function pct(d, t) {
		return t ? int(100 * d / t) : 0
	}
	# The section a table row stands for: the one titled with the label, else the one titled with
	# the label and more ("2. Boot" for "2. Boot (ADR-0001)", but not "Phase 1" for "Phase 10").
	# 0 if none, -1 if more than one.
	function section_of(label,    i, found) {
		for (i = 1; i <= n; i++) if (title[i] == label) return i
		found = 0
		for (i = 1; i <= n; i++) {
			if (index(title[i], label) != 1) continue
			if (substr(title[i], length(label) + 1) ~ /^[0-9A-Za-z]/) continue
			if (found) return -1
			found = i
		}
		return found
	}

	BEGIN { sec = 0 }

	{ line = $0; sub(/\r$/, "", line) }

	infence { if (index(trim(line), fence) == 1) infence = 0; next }
	line ~ /^[ \t]*(```|~~~)/ { fence = substr(trim(line), 1, 3); infence = 1; next }

	line ~ /^#+([ \t]|$)/ {
		match(line, /^#+/)
		depth = RLENGTH
		if (depth <= level) {
			key = trim(line)
			sub(/[ \t]+#+$/, "", key)
			if (!(key in index_of)) {
				index_of[key] = ++n
				shown[n] = key
				title[n] = plain(substr(key, depth + 1))
			}
			sec = index_of[key]
		}
		next
	}

	line ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+\[[ xX]\]([ \t]|$)/ {
		total[sec]++
		all++
		if (line ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+\[[xX]\]/) {
			done[sec]++
			finished++
		}
		next
	}

	# A table row with a label and "done / total" (with or without bold and thousands separators).
	# Numbers are forced with "+ 0" throughout: busybox awk compares a copied unset value as a string.
	check && line ~ /^[ \t]*\|/ {
		cells = split(line, cell, "|")
		label = ""
		count = ""
		percent = -1
		for (i = 2; i <= cells; i++) {
			c = plain(cell[i])
			if (count != "") {
				if (c ~ /^[0-9]+(\.[0-9]+)?[ \t]*%$/) percent = c + 0
				break
			}
			digits = c
			gsub(/,/, "", digits)
			if (digits ~ /^[0-9]+[ \t]*\/[ \t]*[0-9]+$/) count = digits
			else if (label == "") label = c
		}
		if (count != "" && label != "") {
			split(count, part, "/")
			rows++
			row_label[rows] = label
			row_done[rows] = part[1] + 0
			row_total[rows] = part[2] + 0
			row_percent[rows] = percent
			row_line[rows] = NR
		}
	}

	END {
		if (total[0]) printf "%4d / %4d  %3d%%  %s\n", done[0], total[0], pct(done[0], total[0]), "(before the first heading)"
		for (i = 1; i <= n; i++) if (total[i]) printf "%4d / %4d  %3d%%  %s\n", done[i], total[i], pct(done[i], total[i]), shown[i]
		printf "%4d / %4d  %3d%%  %s\n", finished, all, pct(finished, all), total_label
		if (!check) exit 0

		print ""
		problems = 0
		matched = 0
		for (r = 1; r <= rows; r++) {
			if (row_label[r] == total_label) {
				d = finished + 0
				t = all + 0
				total_seen = 1
			} else {
				s = section_of(row_label[r])
				if (s < 0) {
					printf "NG    line %d: \"%s\" matches more than one section\n", row_line[r], row_label[r]
					problems++
					continue
				}
				if (s == 0) {
					printf "NOTE  line %d: \"%s\" matches no section (ignored)\n", row_line[r], row_label[r]
					continue
				}
				d = done[s] + 0
				t = total[s] + 0
				seen[s] = 1
			}
			matched++
			if (row_done[r] != d || row_total[r] != t || (row_percent[r] >= 0 && row_percent[r] != pct(d, t))) {
				printf "NG    line %d: %s — the table says %d / %d%s, the count is %d / %d (%d%%)\n", row_line[r], row_label[r], row_done[r], row_total[r], (row_percent[r] >= 0 ? " (" row_percent[r] "%)" : ""), d, t, pct(d, t)
				problems++
			}
		}
		if (!matched) {
			print "NO TABLE  no table row with a section title and \"done / total\" was found"
			exit 2
		}
		for (i = 1; i <= n; i++) if (total[i] && !seen[i]) {
			printf "NG    %s has no row in the summary table\n", shown[i]
			problems++
		}
		if (!total_seen) {
			printf "NG    the summary table has no \"%s\" row\n", total_label
			problems++
		}
		if (problems) {
			printf "RESULT: %d problem(s) — update the summary table\n", problems
			exit 1
		}
		printf "RESULT: the summary table matches the counts (%d rows)\n", matched
	}
' "$FILE"
