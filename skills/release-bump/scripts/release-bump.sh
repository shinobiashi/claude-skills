#!/usr/bin/env bash
#
# release-bump.sh — the mechanical half of the release-bump skill: find the
# files that carry the plugin version, bump them, keep the readme.txt
# changelog in step with the PRs merged since the previous release, and push
# the release tag to the canonical remote.
#
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.
# Needs git, awk, jq and gh (prs / check only).
#
# Subcommands (run from anywhere inside the plugin repository):
#
#   Global options, accepted before or after the subcommand:
#     --plugin <dir>        the plugin directory, relative to the repository
#                           root (env RELEASE_BUMP_PLUGIN_DIR). Default: the
#                           root when a root *.php has a 'Plugin Name:'
#                           header, else the one directory up to two levels
#                           down (plugins/<slug>/, <slug>/) that holds such a
#                           file and a readme.txt; more than one is refused.
#                           In a plugin directory, version lines, readme.txt,
#                           package.json, the .pot check and the PR kinds are
#                           all read inside that directory.
#     --tag-prefix <p>      release tags are <p><x.y.z> (env
#                           RELEASE_BUMP_TAG_PREFIX), e.g. v or pro-v when the
#                           deploy workflow strips it. Default: none.
#
#   detect [--version <new>]
#       Print the repository facts the skill needs, one KEY=value per line:
#       the main plugin file and its directory, the readme, the current
#       version, the tag prefix, the previous release tag, the changelog
#       heading style, the default branch, the canonical remote (upstream
#       when it exists, else origin), the GitHub repo, the release branch
#       and tag for <new>; then a
#       CARRIER line for every line that holds the version and is rewritten
#       by `bump`, and a MENTION line for every other line that contains the
#       version string and is left alone (docblock @since lines and changelog
#       headings are history and are not even listed). A docblock @version is
#       a carrier only in a PHP file that holds another carrier (the plugin
#       header, or the main class $version); elsewhere it is a class's own
#       version and is not listed either. With a plugin directory, only the
#       files in it can be carriers; the repository root's own files (root
#       package.json, CLAUDE.md) are listed as MENTION, and other directories
#       (another plugin of the monorepo) are not searched.
#
#   prs [--since <tag>] [--changelog-ref <ref>] [--skip <n,n,...>]
#       List the PRs merged into the default branch after <since> (default:
#       the previous release tag), as TSV:
#         number  kind  merge-sha  issues  referenced  title
#       kind is docs when every changed file is documentation (docs/, *.md,
#       .claude/), ci when every file is under .github/, else code. With a
#       plugin directory only its files count, and a PR that changes nothing
#       in it is outside.
#       referenced says whether the newest changelog block of readme.txt at
#       <changelog-ref> (default: the release branch when exactly one exists
#       on the canonical remote, else the working tree) mentions #<number> or
#       one of the PR's linked issues; skip for numbers given with --skip.
#
#   bump <version> [--date <YYYY-MM-DD>] [--entries <file>] [--allow-dirty]
#       Rewrite every carrier from the current version to <version>, update
#       package.json / package-lock.json through `npm version` when they
#       exist, and insert the changelog heading `= <version> - <date> =`
#       (date: today) with the bullets of <file> at the top of == Changelog ==.
#       When the newest existing heading has no date (`= x.y.z =`), the new
#       one has none either and --date is ignored.
#       Refuses when the heading already exists or the tree is dirty.
#
#   add-entries <file> [--version <x.y.z>]
#       Append the bullets of <file> to the changelog block of <version>
#       (default: the newest heading). Lines already in the block are skipped,
#       so re-running with the same file is harmless.
#
#   check [--since <tag>] [--skip <n,n,...>]
#       What the bump PR needs before it merges, against the current checkout:
#       every carrier holds the same version, that version has a changelog
#       heading, every code PR since <since> is referenced in it, the branch
#       is not behind the canonical default branch, and whether translation
#       calls were changed since <since> without the .pot being regenerated
#       after them (both read at HEAD, so a regen on the release branch counts).
#       Exit 1 when something needs attention.
#
#   tag <version> [--remote <name>] [--dry-run]
#       Create the lightweight tag <tag-prefix><version> at HEAD and push it
#       to the canonical remote only (never to a fork). Refuses a `v` on
#       <version> itself, a dirty
#       tree, a HEAD that is not the remote's default branch tip, carriers
#       that do not hold <version>, a missing changelog heading and a tag that
#       already exists locally or on the remote.
#
# Why these rules are baked in rather than typed each time:
#   - A `v`-prefixed tag yields an empty GitHub Release body when the deploy
#     workflow extracts the changelog with `awk /^= <TAG> /` against readme.txt
#     (Japanized-for-WooCommerce v2.9.14 had to be edited by hand). A prefix
#     is only added when it is asked for (--tag-prefix), for workflows that
#     strip it (`${GITHUB_REF_NAME#v}`).
#   - A monorepo (plugins/<free>/ and plugins/<pro>/) can hold two plugins
#     at the same version: a repository-wide search would bump the other
#     plugin's constant and count its PRs (cart-bridge-jp 1.0.1 was bumped by
#     hand because the script only looked at the root).
#   - The fork has the same deploy workflow but no SVN secrets; a tag pushed
#     there only produces a failed run.
#   - `@since x.y.z` docblocks hold the version a feature shipped in and must
#     never be bumped; a plain search-and-replace of the version would hit them.
#   - A fix PR merged after the bump PR was opened has no changelog line unless
#     somebody notices (2.9.17: #228 and #230 were both added after the fact).
set -euo pipefail

# this file, absolute: the script cds to the repository root before usage runs
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
usage() { sed -n '2,/^set -euo pipefail$/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; }

die() { echo "release-bump: $*" >&2; exit 2; }

# --- repository facts ------------------------------------------------------

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"

canonical_remote() {
	if git remote get-url upstream >/dev/null 2>&1; then echo upstream; else echo origin; fi
}

default_branch() { # $1 = remote
	local b
	b="$(git symbolic-ref --short "refs/remotes/$1/HEAD" 2>/dev/null || true)"
	if [ -n "$b" ]; then echo "${b#"$1"/}"; return; fi
	for b in main master; do
		if git show-ref --verify --quiet "refs/remotes/$1/$b"; then echo "$b"; return; fi
	done
	echo main
}

gh_repo() { # $1 = remote -> owner/repo
	git remote get-url "$1" 2>/dev/null \
		| sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://git@[^/]+/)##; s#\.git$##; s#/$##'
}

# Set by the global options (or their environment variables) in main.
PLUGIN_DIR_ARG="${RELEASE_BUMP_PLUGIN_DIR:-}"
TAG_PREFIX="${RELEASE_BUMP_TAG_PREFIX:-}"
# Set by resolve_plugin: the plugin directory ("" for the root, else "dir/"),
# the main plugin file and the readme, all relative to the repository root.
PDIR=""
PLUGIN=""
README="readme.txt"

# The first *.php directly in $1 ("" or "dir/") with a Plugin Name header.
plugin_file_in() {
	local f
	for f in "$1"*.php; do
		[ -f "$f" ] || continue
		if grep -qE '^[[:space:]]*\*?[[:space:]]*Plugin Name:' "$f"; then echo "$f"; return; fi
	done
	return 1
}

# A directory argument as a path relative to the root without ./ or a
# trailing slash ("" for the root). Refuses one that leaves the repository.
normalize_dir() {
	local d="$1" abs root
	if [ "${d#/}" != "$d" ]; then
		abs="$(cd "$d" 2>/dev/null && pwd -P)" || die "--plugin: no directory $1"
		root="$(pwd -P)"
		case "$abs" in
			"$root") d="" ;;
			"$root"/*) d="${abs#"$root"/}" ;;
			*) die "--plugin: $1 is outside the repository" ;;
		esac
	fi
	while [ "${d#./}" != "$d" ]; do d="${d#./}"; done
	while [ "${d%/}" != "$d" ]; do d="${d%/}"; done
	[ "$d" != . ] || d=""
	case "/$d/" in */../*|*/./*) die "--plugin: $1 must be a path inside the repository without . or .. parts" ;; esac
	printf '%s' "$d"
}

# Directories one or two levels down (plugins/<slug>, <slug>) that hold a
# readme.txt and a *.php with a Plugin Name header. Dependencies, tests,
# build output and dot directories (.claude/ skill templates are plugins
# too) are not candidates.
plugin_dir_candidates() {
	git ls-files -- '*.php' \
		| awk -F/ 'NF == 2 || NF == 3 { d = $1; for (i = 2; i < NF; i++) d = d "/" $i; print d }' \
		| sort -u \
		| { grep -vE '(^|/)(vendor|node_modules|tests?|dist|build)(/|$)|(^|/)\.' || true; } \
		| while IFS= read -r d; do
			[ -f "$d/readme.txt" ] || continue
			plugin_file_in "$d/" >/dev/null || continue
			echo "$d"
		done
}

resolve_plugin() {
	local d pd list n
	if [ -n "${RELEASE_BUMP_PLUGIN_FILE:-}" ]; then
		[ -f "$RELEASE_BUMP_PLUGIN_FILE" ] || die "RELEASE_BUMP_PLUGIN_FILE not found: $RELEASE_BUMP_PLUGIN_FILE"
		PLUGIN="${RELEASE_BUMP_PLUGIN_FILE#./}"
		d="$(dirname "$PLUGIN")"; [ "$d" != . ] || d=""
		if [ -n "$PLUGIN_DIR_ARG" ]; then
			pd="$(normalize_dir "$PLUGIN_DIR_ARG")"
			[ "$pd" = "$d" ] || die "RELEASE_BUMP_PLUGIN_FILE ($PLUGIN) is not in --plugin $PLUGIN_DIR_ARG"
		fi
		PDIR="${d:+$d/}"
	elif [ -n "$PLUGIN_DIR_ARG" ]; then
		d="$(normalize_dir "$PLUGIN_DIR_ARG")"
		[ -z "$d" ] || [ -d "$d" ] || die "--plugin: no directory $PLUGIN_DIR_ARG"
		PDIR="${d:+$d/}"
		PLUGIN="$(plugin_file_in "$PDIR")" || die "no *.php with a 'Plugin Name:' header in ${d:-the repository root}"
	elif PLUGIN="$(plugin_file_in "")"; then
		PDIR=""
	else
		list="$(plugin_dir_candidates)"
		n="$(printf '%s\n' "$list" | grep -c . || true)"
		case "$n" in
			0) die "no root *.php with a 'Plugin Name:' header and no plugins/<slug>/ with one and a readme.txt (pass --plugin <dir>)" ;;
			1) PDIR="$list/"; PLUGIN="$(plugin_file_in "$PDIR")" ;;
			*) die "more than one plugin directory, pass --plugin <dir>: $(printf '%s' "$list" | tr '\n' ' ')" ;;
		esac
	fi
	README="${PDIR}readme.txt"
}

# Prints "date" when the newest changelog heading is `= x.y.z - <date> =` (or
# there is none yet) and "bare" when it is `= x.y.z =`: a new heading follows
# the readme's own style (cart-bridge-jp writes no dates).
heading_style() {
	awk '/^== Changelog ==/ { f = 1; next }
		f && /^= / { print ($0 ~ /^= [^ ]+ =[ \t]*$/) ? "bare" : "date"; done = 1; exit }
		f && /^== / { exit }
		END { if (!done) print "date" }' "$README"
}

# The release tag of a version (the prefix is only added when asked for).
tag_name() { printf '%s%s' "$TAG_PREFIX" "$1"; }

current_version() { # $1 = plugin file
	grep -E '^[[:space:]]*\*?[[:space:]]*Version:' "$1" | head -1 \
		| sed -E 's/^[[:space:]]*\*?[[:space:]]*Version:[[:space:]]*//; s/[[:space:]]*$//'
}

is_semver() { printf '%s' "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$'; }

# Versions only contain digits, dots, letters and '-'. The dot is written as
# [.] rather than \. because the pattern also travels through `awk -v`, which
# processes backslash escapes in the value.
regex_escape() { printf '%s' "$1" | sed 's/\./[.]/g'; }

# Highest x.y.z tag. Without a tag prefix, with or without a v: prints the tag
# as it is named, so `v2.9.14` and `2.9.16` are both found and the
# numerically highest wins. With one, only <prefix>x.y.z (a monorepo's
# `pro-v1.0.0` is not the free plugin's `v1.0.0`).
previous_tag() {
	git tag --list \
		| awk -v p="$TAG_PREFIX" '
			{
				t = $0
				if (p != "") {
					if (index(t, p) != 1) next
					n = substr(t, length(p) + 1)
					if (n !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) next
				} else {
					if (t !~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/) next
					n = t; sub(/^v/, "", n)
				}
				split(n, q, ".")
				key = sprintf("%06d%06d%06d", q[1], q[2], q[3])
				# an unprefixed tag beats a v-prefixed one of the same version
				if (key > best || (key == best && t !~ /^v/)) { best = key; tag = t }
			}
			END { if (tag != "") print tag }'
}

# Every line that contains the version, classified. Prints
#   CARRIER<TAB>file<TAB>line<TAB>text   (rewritten by bump)
#   MENTION<TAB>file<TAB>line<TAB>text   (left alone, shown for review)
# @since/@deprecated docblock lines and readme changelog headings are history
# and are not printed at all. A docblock `@version <version>` is a CARRIER in
# a PHP file that holds another carrier (the plugin header, or the main class
# with its $version: jp4wc-pro keeps the two in step) and is not printed
# elsewhere, where it is a class's own version that happens to be equal.
# With a plugin directory (PDIR), the rules see paths relative to it, only
# its files are searched for carriers, and the root's own files (not those of
# other directories: another plugin of a monorepo can be at the same version)
# are listed as MENTION.
classify_lines() { # $1 = version, $2 = plugin file
	local v="$1" plugin="$2" ve
	ve="$(regex_escape "$v")"
	{
		git grep -n -I -F -e "$v" -- "${PDIR:-.}" \
			":!${PDIR}node_modules" ":!${PDIR}vendor" ":!${PDIR}dist" ':!*.pot' ':!*.po' ':!*.mo' \
			':!*package-lock.json' ':!*composer.lock' ':!*.min.js' ':!*.map' ':!*.lock' \
			2>/dev/null || true
		# the root's own files (glob: * does not cross a /)
		[ -z "$PDIR" ] || git grep -n -I -F -e "$v" -- ':(glob)*' \
			':!*package-lock.json' ':!*composer.lock' ':!*.lock' 2>/dev/null || true
	} \
	| awk -F: -v ve="$ve" -v plugin="$plugin" -v pdir="$PDIR" '
		{
			file = $1; line = $2
			text = $0; sub(/^[^:]*:[^:]*:/, "", text)
			# the version must stand on its own (2.9.1 is not 2.9.16)
			if (text !~ ("(^|[^0-9.])" ve "([^0-9]|$)")) next
			if (text ~ /@(since|deprecated)/) next
			# rel: the path the rules below see; outside the plugin directory nothing is a carrier
			rel = file; outside = 0
			if (pdir != "") { if (substr(file, 1, length(pdir)) == pdir) rel = substr(file, length(pdir) + 1); else outside = 1 }
			if (!outside && rel == "readme.txt" && text ~ ("^= " ve "( |$)")) next
			kind = "MENTION"
			if (outside) kind = "MENTION"
			# decided in END, once the carriers of every file are known
			else if (text ~ /@version/) kind = (rel ~ /\.php$/ && rel !~ /^tests?\// && text ~ ("@version[ \t]+" ve "[ \t]*$")) ? "ATVERSION" : "SKIP"
			else if (file == plugin && text ~ ("^[ \t]*\\*?[ \t]*Version:[ \t]*" ve "[ \t]*$")) kind = "CARRIER"
			# \047 is the single quote: the program itself sits inside shell single quotes
			else if (rel ~ /\.php$/ && rel !~ /^tests?\// && text ~ ("define\\([ \t]*[\047\"][A-Za-z0-9_]*_VERSION[\047\"][ \t]*,[ \t]*[\047\"]" ve "[\047\"]")) kind = "CARRIER"
			else if (rel ~ /\.php$/ && rel !~ /^tests?\// && text ~ ("(VERSION|version)[ \t]*=[ \t]*[\047\"]" ve "[\047\"]")) kind = "CARRIER"
			# WooCommerce API Manager client: new WC_AM_Client_2_12_2( __FILE__, null, 188, 'x.y.z', ... )
			# passes the software version as a literal; a stale one makes the update check misreport
			else if (rel ~ /\.php$/ && rel !~ /^tests?\// && text ~ /WC_AM_Client[A-Za-z0-9_]*[ \t]*\(/ && text ~ ("[\047\"]" ve "[\047\"]")) kind = "CARRIER"
			else if (rel == "readme.txt" && text ~ ("^Stable tag:[ \t]*" ve "[ \t]*$")) kind = "CARRIER"
			# top level only (one indent step: up to two spaces or one tab): a nested "version" belongs to something else
			else if ((rel == "package.json" || rel == "composer.json") && text ~ ("^( ? ?|\t)\"version\":[ \t]*\"" ve "\"")) kind = "CARRIER"
			# CLAUDE.md: only a version declaration ("**Version**: x.y.z", "Version: x.y.z",
			# "現バージョン: x.y.z"); prose such as "stored as entered since x.y.z" is history and stays
			else if (rel == "CLAUDE.md" && (text ~ ("[Vv]ersion[*]*:[ \t]*" ve "([^0-9]|$)") || text ~ ("バージョン[*]*(:|：)[ \t]*" ve "([^0-9]|$)"))) kind = "CARRIER"
			n++; F[n] = file; L[n] = line; T[n] = text; K[n] = kind
			if (kind == "CARRIER" && file ~ /\.php$/) carrier_php[file] = 1
		}
		END {
			for (i = 1; i <= n; i++) {
				kind = K[i]
				if (kind == "SKIP") continue
				if (kind == "ATVERSION") { if (!(F[i] in carrier_php)) continue; kind = "CARRIER" }
				printf "%s\t%s\t%s\t%s\n", kind, F[i], L[i], T[i]
			}
		}'
}

changelog_file() { [ -f "$README" ] && echo "$README" || return 1; }

# The newest changelog block (bullets under the first `= x.y.z ...` heading
# after `== Changelog ==`) of the readme at a git ref.
newest_block_at() { # $1 = ref ("" = working tree)
	local content
	if [ -n "$1" ]; then content="$(git show "$1:$README" 2>/dev/null)" || return 1
	else content="$(cat "$README")"; fi
	printf '%s\n' "$content" | awk '
		/^== Changelog ==/ { inlog = 1; next }
		inlog && /^= / { if (found) exit; found = 1; print; next }
		found && /^== / { exit }
		found { print }'
}

newest_heading_version() { # from the working tree
	awk '/^== Changelog ==/ { f = 1; next } f && /^= / { v = $2; print v; exit }' "$README"
}

# --- detect ----------------------------------------------------------------

cmd_detect() {
	local new="" remote branch version prev
	while [ $# -gt 0 ]; do
		case "$1" in
			--version) new="$2"; shift 2 ;;
			*) die "detect: unknown argument $1" ;;
		esac
	done
	resolve_plugin
	version="$(current_version "$PLUGIN")"
	[ -n "$version" ] || die "no 'Version:' header in $PLUGIN"
	remote="$(canonical_remote)"
	branch="$(default_branch "$remote")"
	prev="$(previous_tag)"
	echo "PLUGIN_FILE=$PLUGIN"
	if [ -n "$PDIR" ]; then echo "PLUGIN_DIR=${PDIR%/}"; else echo "PLUGIN_DIR=."; fi
	echo "README=$README$([ -f "$README" ] || echo ' (missing)')"
	echo "VERSION=$version"
	echo "TAG_PREFIX=$TAG_PREFIX"
	echo "PREVIOUS_TAG=${prev:-none}"
	[ ! -f "$README" ] || echo "HEADING_STYLE=$(heading_style)"
	echo "DEFAULT_BRANCH=$branch"
	echo "REMOTE=$remote"
	echo "REPO=$(gh_repo "$remote")"
	if [ -n "$new" ]; then
		echo "NEW_VERSION=$new"
		echo "NEW_TAG=$(tag_name "$new")"
		echo "RELEASE_BRANCH=release/$new"
	fi
	if [ -z "$TAG_PREFIX" ] && [ -n "$prev" ] && printf '%s' "$prev" | grep -q '^v'; then
		echo "WARN=the previous tag '$prev' has a v prefix; tags are pushed without one unless --tag-prefix v (when the deploy workflow strips it)"
	fi
	if ! git ls-files --error-unmatch -- "$PLUGIN" >/dev/null 2>&1; then
		echo "WARN=$PLUGIN is not tracked by git; git grep finds no carriers in it and bump refuses"
	fi
	classify_lines "$version" "$PLUGIN"
}

# --- prs -------------------------------------------------------------------

# Resolve the changelog ref: the single release/* branch on the canonical
# remote, else "" (= the working tree, so an entry just added is seen).
default_changelog_ref() { # $1 = remote
	local n
	n="$(git for-each-ref --format='%(refname:short)' "refs/remotes/$1/release/" | wc -l | tr -d ' ')"
	if [ "$n" = 1 ]; then git for-each-ref --format='%(refname:short)' "refs/remotes/$1/release/"; fi
}

in_list() { # $1 = item, $2 = comma list
	case ",$2," in *",$1,"*) return 0 ;; esac
	return 1
}

# With a plugin directory only the files in it count (paths relative to it),
# and a PR that changes none of them is "outside": another plugin of the
# monorepo, or the repository's own tooling.
pr_kind() { # $1 = space-separated files (relative to the root)
	local f rel docs=1 ci=1 inside=0
	[ -n "$1" ] || { echo code; return; }
	for f in $1; do
		rel="$f"
		if [ -n "$PDIR" ]; then
			case "$f" in
				"$PDIR"*) rel="${f#"$PDIR"}" ;;
				*) continue ;;
			esac
		fi
		inside=1
		case "$rel" in
			docs/*|*.md|.claude/*|CHANGELOG*) ;;
			*) docs=0 ;;
		esac
		case "$rel" in
			.github/*) ;;
			*) ci=0 ;;
		esac
	done
	if [ $inside = 0 ]; then echo outside; elif [ $docs = 1 ]; then echo docs; elif [ $ci = 1 ]; then echo ci; else echo code; fi
}

referenced_in() { # $1 = block text, $2 = pr number, $3 = comma-separated issues
	local n
	for n in "$2" $(printf '%s' "$3" | tr ',' ' '); do
		[ -n "$n" ] || continue
		if printf '%s\n' "$1" | grep -qE "#${n}([^0-9]|$)"; then return 0; fi
	done
	return 1
}

# gh pr list as TSV: number  sha  issues  title  files. Empty fields are
# printed as "-": `read` with a tab IFS collapses consecutive tabs, so an
# empty field would shift the ones after it.
merged_prs_raw() { # $1 = repo, $2 = base, $3 = since-date (YYYY-MM-DD)
	gh pr list --repo "$1" --state merged --base "$2" --search "merged:>=$3" --limit 200 \
		--json number,title,mergeCommit,closingIssuesReferences,files \
		--jq '.[] | [
			(.number|tostring),
			(.mergeCommit.oid // "-"),
			([.closingIssuesReferences[]?.number|tostring] | if length == 0 then "-" else join(",") end),
			(.title | gsub("\t"; " ") | if . == "" then "-" else . end),
			([.files[]?.path] | if length == 0 then "-" else join(" ") end)
		] | @tsv'
}

list_prs() { # $1 = since-tag, $2 = changelog-ref, $3 = skip list -> TSV lines
	local remote branch repo since_date block number sha issues title files kind ref
	remote="$(canonical_remote)"
	branch="$(default_branch "$remote")"
	repo="$(gh_repo "$remote")"
	git fetch -q "$remote" "$branch" 2>/dev/null || true
	since_date="$(git log -1 --format=%cs "$1" 2>/dev/null)" || die "unknown tag or ref: $1"
	block="$(newest_block_at "$2" || true)"
	merged_prs_raw "$repo" "$branch" "$since_date" | while IFS="$(printf '\t')" read -r number sha issues title files; do
		[ -n "$sha" ] && [ "$sha" != - ] || continue
		[ "$issues" != - ] || issues=""
		[ "$files" != - ] || files=""
		# in the tag already, or not on the default branch (e.g. merged elsewhere)
		git merge-base --is-ancestor "$sha" "$1" 2>/dev/null && continue
		git merge-base --is-ancestor "$sha" "$remote/$branch" 2>/dev/null || continue
		kind="$(pr_kind "$files")"
		if in_list "$number" "$3"; then ref=skip
		elif referenced_in "$block" "$number" "$issues"; then ref=yes
		else ref=no; fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$number" "$kind" "${sha:0:7}" "${issues:--}" "$ref" "$title"
	done | sort -t "$(printf '\t')" -k1,1n
}

cmd_prs() {
	local since="" ref="" skip=""
	while [ $# -gt 0 ]; do
		case "$1" in
			--since) since="$2"; shift 2 ;;
			--changelog-ref) ref="$2"; shift 2 ;;
			--skip) skip="$2"; shift 2 ;;
			*) die "prs: unknown argument $1" ;;
		esac
	done
	resolve_plugin
	[ -n "$since" ] || since="$(previous_tag)"
	[ -n "$since" ] || die "no previous release tag${TAG_PREFIX:+ named $TAG_PREFIX<x.y.z>}; pass --since <ref>"
	[ -n "$ref" ] || ref="$(default_changelog_ref "$(canonical_remote)")"
	echo "# merged into $(default_branch "$(canonical_remote)") after $since; changelog $README read at ${ref:-the working tree}${PDIR:+; kinds for ${PDIR%/}}" >&2
	list_prs "$since" "$ref" "$skip"
}

# --- bump ------------------------------------------------------------------

rewrite_line() { # $1 = file, $2 = line number, $3 = old, $4 = new (first occurrence on that line)
	local tmp
	tmp="$(mktemp)"
	awk -v n="$2" -v old="$3" -v new="$4" '
		NR == n { i = index($0, old); if (i > 0) $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) }
		{ print }' "$1" > "$tmp" && cat "$tmp" > "$1" && rm -f "$tmp"
}

insert_changelog_block() { # $1 = version, $2 = date ("" = a heading without one), $3 = entries file ("" = none)
	local tmp
	grep -qE "^= $(regex_escape "$1")( |$)" "$README" && die "$README already has a changelog heading for $1"
	grep -q '^== Changelog ==' "$README" || die "$README has no '== Changelog ==' section"
	tmp="$(mktemp)"
	awk -v v="$1" -v d="$2" -v entries="$3" '
		{ print }
		/^== Changelog ==/ && !done {
			print ""
			print "= " v (d != "" ? " - " d : "") " ="
			if (entries != "") while ((getline line < entries) > 0) if (line != "") print line
			print ""
			done = 1
			# the blank line that followed the section heading is now the one
			# printed above; keep the next line only when it is not blank
			if ((getline nxt) > 0 && nxt != "") print nxt
		}' "$README" > "$tmp" && cat "$tmp" > "$README" && rm -f "$tmp"
}

# package.json is a carrier and is rewritten with the others; this handles
# package-lock.json, which classify_lines skips. With npm, `npm version`
# rewrites both files (package.json is then left out of the carrier loop).
# With a plugin directory, its own package.json (the root's belongs to the
# repository's tooling and is left alone).
bump_package_json() { # $1 = old, $2 = new
	local pkg="${PDIR}package.json" lock="${PDIR}package-lock.json"
	[ -f "$pkg" ] || return 0
	if command -v npm >/dev/null 2>&1; then
		( cd "${PDIR:-.}" && npm version "$2" --no-git-tag-version --allow-same-version --ignore-scripts >/dev/null )
		echo "$pkg: npm version $2 (package-lock.json too when present)"
		return
	fi
	[ -f "$lock" ] || return 0
	# No npm: the root "version" (one indent step) and packages[""] (three steps),
	# with two-space or tab indentation.
	local n line
	n="$(grep -nE "^(  |      |	|			)\"version\":[[:space:]]*\"$(regex_escape "$1")\"" "$lock" | head -2 | cut -d: -f1 || true)"
	for line in $n; do rewrite_line "$lock" "$line" "$1" "$2"; done
	echo "$lock: rewritten without npm (lines $(printf '%s' "${n:-none}" | tr '\n' ' '))"
}

cmd_bump() {
	local new="" date="" entries="" allow_dirty=0 version lines kind file line text style
	while [ $# -gt 0 ]; do
		case "$1" in
			--date) date="$2"; shift 2 ;;
			--entries) entries="$2"; shift 2 ;;
			--allow-dirty) allow_dirty=1; shift ;;
			-*) die "bump: unknown option $1" ;;
			*) [ -z "$new" ] || die "bump: one version only"; new="$1"; shift ;;
		esac
	done
	[ -n "$new" ] || die "bump: version required"
	is_semver "$new" || die "bump: '$new' is not x.y.z (no v prefix)"
	[ -z "$date" ] || printf '%s' "$date" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "bump: --date must be YYYY-MM-DD"
	[ -z "$entries" ] || [ -f "$entries" ] || die "bump: entries file not found: $entries"
	if [ $allow_dirty = 0 ] && [ -n "$(git status --porcelain)" ]; then
		die "bump: the working tree has changes (commit or stash them, or --allow-dirty)"
	fi
	resolve_plugin
	version="$(current_version "$PLUGIN")"
	[ "$version" != "$new" ] || die "bump: already at $new"
	changelog_file >/dev/null || die "bump: no $README"
	style="$(heading_style)"
	if [ "$style" = bare ]; then
		[ -z "$date" ] || echo "NOTE the changelog headings of $README have no date; --date $date is not written"
		date=""
	else
		[ -n "$date" ] || date="$(date +%Y-%m-%d)"
	fi

	# Take the list before rewriting anything: git grep must not see a file
	# that has already been bumped. package.json is handled by npm below, so
	# it is skipped here when npm exists.
	lines="$(classify_lines "$version" "$PLUGIN")"
	# git grep reads tracked files only: without the header among the carriers
	# the bump would write a changelog heading and no version at all
	printf '%s\n' "$lines" | grep -qF "CARRIER$(printf '\t')$PLUGIN$(printf '\t')" \
		|| die "bump: the 'Version:' header of $PLUGIN is not among the carriers (git grep reads tracked files only: is it committed?)"
	printf '%s\n' "$lines" | while IFS="$(printf '\t')" read -r kind file line text; do
		[ "$kind" = CARRIER ] || continue
		if [ "$file" = "${PDIR}package.json" ] && command -v npm >/dev/null 2>&1; then continue; fi
		rewrite_line "$file" "$line" "$version" "$new"
		echo "$file:$line: $version -> $new"
	done
	bump_package_json "$version" "$new"
	insert_changelog_block "$new" "$date" "$entries"
	echo "$README: added '= $new${date:+ - $date} =' with $(if [ -n "$entries" ]; then grep -c . "$entries"; else echo 0; fi) entries"
	echo "DONE version=$new date=${date:-none}"
}

# --- add-entries -----------------------------------------------------------

cmd_add_entries() {
	local file="" version="" tmp added
	while [ $# -gt 0 ]; do
		case "$1" in
			--version) version="$2"; shift 2 ;;
			-*) die "add-entries: unknown option $1" ;;
			*) [ -z "$file" ] || die "add-entries: one file only"; file="$1"; shift ;;
		esac
	done
	[ -n "$file" ] && [ -f "$file" ] || die "add-entries: entries file required"
	resolve_plugin
	changelog_file >/dev/null || die "add-entries: no $README"
	[ -n "$version" ] || version="$(newest_heading_version)"
	[ -n "$version" ] || die "add-entries: $README has no changelog heading"
	grep -qE "^= $(regex_escape "$version")( |$)" "$README" || die "add-entries: no changelog heading for $version"
	tmp="$(mktemp)"
	added="$(awk -v ve="$(regex_escape "$version")" -v entries="$file" '
		BEGIN { n = 0; while ((getline line < entries) > 0) if (line != "") { n++; want[n] = line } }
		function flush(   i) {
			for (i = 1; i <= n; i++) if (!(want[i] in seen)) { print want[i]; added++ }
			flushed = 1
		}
		{
			if (inblock && !flushed && ($0 == "" || $0 ~ /^= / || $0 ~ /^== /)) flush()
			if ($0 ~ ("^= " ve "( |$)")) inblock = 1
			else if (inblock && !flushed) seen[$0] = 1
			print
		}
		END { if (inblock && !flushed) flush(); print added + 0 > "/dev/stderr" }' "$README" 2>&1 >"$tmp" | tail -1)"
	cat "$tmp" > "$README" && rm -f "$tmp"
	echo "$README: $added new line(s) under '= $version'"
}

# --- check -----------------------------------------------------------------

cmd_check() {
	local since="" skip="" status=0 remote branch version carriers n behind cur
	local heading missing unref strings pot_changed pot_last number kind sha issues ref title
	local calls pot_commit late c
	while [ $# -gt 0 ]; do
		case "$1" in
			--since) since="$2"; shift 2 ;;
			--skip) skip="$2"; shift 2 ;;
			*) die "check: unknown argument $1" ;;
		esac
	done
	resolve_plugin
	remote="$(canonical_remote)"
	branch="$(default_branch "$remote")"
	version="$(current_version "$PLUGIN")"
	[ -n "$since" ] || since="$(previous_tag)"
	[ -n "$since" ] || die "no previous release tag${TAG_PREFIX:+ named $TAG_PREFIX<x.y.z>}; pass --since <ref>"
	git rev-parse -q --verify "$since^{commit}" >/dev/null || die "unknown tag or ref: $since"
	git fetch -q "$remote" "$branch" 2>/dev/null || true

	cur="$(git branch --show-current 2>/dev/null || true)"
	[ -n "$cur" ] || cur="detached at $(git rev-parse --short HEAD)"
	echo "version:   $version (from $PLUGIN)"
	echo "previous:  $since"
	echo "branch:    $cur vs $remote/$branch"

	# 1. carriers agree with the plugin header
	carriers="$(classify_lines "$version" "$PLUGIN" | awk -F'\t' '$1 == "CARRIER" { print $2 ":" $3 }')"
	n="$(printf '%s\n' "$carriers" | grep -c . || true)"
	if [ "$n" -lt 2 ]; then
		echo "WARN     carriers: only $n line(s) hold $version — run detect and look at MENTION lines"
	else
		echo "OK       carriers: $n lines hold $version ($(printf '%s' "$carriers" | tr '\n' ' '))"
	fi
	# Stable tag must match specifically (the deploy copies readme.txt as is)
	if [ -f "$README" ] && ! grep -qE "^Stable tag:[[:space:]]*$(regex_escape "$version")[[:space:]]*$" "$README"; then
		echo "MISSING  $README 'Stable tag:' is not $version"; status=1
	fi
	if [ -f "${PDIR}package.json" ] && ! grep -qE "^[[:space:]]*\"version\":[[:space:]]*\"$(regex_escape "$version")\"" "${PDIR}package.json"; then
		echo "MISSING  ${PDIR}package.json version is not $version"; status=1
	fi

	# 2. changelog heading: `= x.y.z - YYYY-MM-DD =`, or `= x.y.z =` in a readme
	#    that writes no dates (both match the deploy workflow's '^= x.y.z ')
	if [ -f "$README" ]; then
		heading="$(grep -E "^= $(regex_escape "$version")( |$)" "$README" | head -1 || true)"
		if [ -z "$heading" ]; then
			echo "MISSING  $README has no '= $version - <date> =' (or '= $version =') heading"; status=1
		elif ! printf '%s' "$heading" | grep -qE "^= $(regex_escape "$version")( - [0-9]{4}-[0-9]{2}-[0-9]{2})? =$"; then
			echo "WARN     heading '$heading' is not '= $version - YYYY-MM-DD =' or '= $version =' (the deploy workflow matches '^= $version ')"
		else
			echo "OK       heading: $heading"
		fi
	fi

	# 3. every code PR since the previous tag is referenced in the newest block
	missing=""; unref=""
	while IFS="$(printf '\t')" read -r number kind sha issues ref title; do
		[ -n "$number" ] || continue
		[ "$kind" = code ] || continue
		case "$ref" in
			yes|skip) ;;
			*) missing="$missing #$number"; unref="$unref
           #$number $title" ;;
		esac
	done <<EOF
$(list_prs "$since" "" "$skip")
EOF
	if [ -n "$missing" ]; then
		echo "MISSING  code PRs without a changelog reference:$missing$unref"
		echo "         (a line that describes the PR without its number counts once you pass --skip <n>)"
		status=1
	else
		echo "OK       every code PR merged after $since is referenced in the $version block (or skipped)"
	fi

	# 4. behind the canonical default branch?
	if git rev-parse --verify -q "$remote/$branch" >/dev/null; then
		behind="$(git rev-list --count "HEAD..$remote/$branch")"
		if [ "$behind" -gt 0 ]; then
			echo "BEHIND   $behind commit(s) on $remote/$branch are not in this branch (run sync)"; status=1
		else
			echo "OK       up to date with $remote/$branch"
		fi
	fi

	# 5. translation strings added since the previous tag vs the .pot, both read at HEAD: on a
	#    release branch the POT regen is a commit of that branch and not yet of the default
	#    branch (jp4wc-pro 3.2.0 was warned "no .pot change" right after its regen commit).
	#    With a plugin directory, only its sources and .pot (a pathspec `*` crosses `/`).
	calls="(__|_e|_x|_ex|_n|_nx|_n_noop|_nx_noop|esc_html__|esc_html_e|esc_html_x|esc_attr__|esc_attr_e|esc_attr_x)\\([[:space:]]*['\"]"
	strings="$(git diff "$since..HEAD" -- "${PDIR}*.php" "${PDIR}*.js" "${PDIR}*.jsx" "${PDIR}*.ts" "${PDIR}*.tsx" 2>/dev/null \
		| grep -cE "^\+.*[^A-Za-z0-9_]$calls" || true)"
	if [ "${strings:-0}" -gt 0 ]; then
		pot_changed="$(git diff --name-only "$since..HEAD" -- "${PDIR}*.pot" 2>/dev/null | head -1 || true)"
		if [ -n "$pot_changed" ]; then
			pot_commit="$(git log -1 --format=%H HEAD -- "$pot_changed")"
			pot_last="$(git log -1 --format='%h %cs' "$pot_commit")"
			# commits that changed translation calls and are not in the history of the regen
			late=""
			for c in $(git log --format=%H -G"(^|[^A-Za-z0-9_])$calls" "$since..HEAD" -- "${PDIR}*.php" "${PDIR}*.js" "${PDIR}*.jsx" "${PDIR}*.ts" "${PDIR}*.tsx" 2>/dev/null); do
				git merge-base --is-ancestor "$c" "$pot_commit" || late="$late ${c:0:7}"
			done
			if [ -z "$late" ]; then
				echo "OK       $strings added line(s) with translation calls since $since; $pot_changed was regenerated after all of them ($pot_last)"
			else
				echo "WARN     translation calls changed after $pot_changed was last regenerated ($pot_last):$late — regenerate the POT"
			fi
		else
			echo "WARN     $strings added line(s) with translation calls since $since and no .pot change — a POT regen is probably needed"
		fi
	else
		echo "OK       no translation calls added since $since"
	fi

	[ $status = 0 ] && echo "DONE" || echo "ATTENTION NEEDED"
	return $status
}

# --- tag -------------------------------------------------------------------

cmd_tag() {
	local version="" remote="" dry=0 branch head_version tag
	while [ $# -gt 0 ]; do
		case "$1" in
			--remote) remote="$2"; shift 2 ;;
			--dry-run) dry=1; shift ;;
			-*) die "tag: unknown option $1" ;;
			*) [ -z "$version" ] || die "tag: one version only"; version="$1"; shift ;;
		esac
	done
	[ -n "$version" ] || die "tag: version required"
	printf '%s' "$version" | grep -q '^v' && die "tag: no v prefix — the deploy workflow matches '= $version ' in readme.txt (a workflow that strips a prefix: --tag-prefix v)"
	is_semver "$version" || die "tag: '$version' is not x.y.z"
	tag="$(tag_name "$version")"
	git check-ref-format "refs/tags/$tag" || die "tag: '$tag' is not a valid tag name (--tag-prefix $TAG_PREFIX)"
	resolve_plugin
	[ -n "$remote" ] || remote="$(canonical_remote)"
	if [ "$remote" != "$(canonical_remote)" ]; then
		die "tag: $remote is not the canonical remote ($(canonical_remote)); a fork has no deploy secrets"
	fi
	branch="$(default_branch "$remote")"
	[ -z "$(git status --porcelain)" ] || die "tag: the working tree has changes"
	[ "$(git branch --show-current)" = "$branch" ] || die "tag: not on $branch"
	git fetch -q "$remote" "$branch" --tags 2>/dev/null || true
	[ "$(git rev-parse HEAD)" = "$(git rev-parse "$remote/$branch")" ] || die "tag: HEAD is not $remote/$branch (pull or push first)"
	head_version="$(current_version "$PLUGIN")"
	[ "$head_version" = "$version" ] || die "tag: $PLUGIN says $head_version, not $version (merge the bump PR first)"
	if [ -f "$README" ]; then
		grep -qE "^Stable tag:[[:space:]]*$(regex_escape "$version")[[:space:]]*$" "$README" || die "tag: $README Stable tag is not $version"
		grep -qE "^= $(regex_escape "$version") " "$README" || die "tag: $README has no '= $version - <date> =' (or '= $version =') heading (empty release body)"
	fi
	git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag: $tag already exists locally"
	[ -z "$(git ls-remote --tags "$remote" "refs/tags/$tag")" ] || die "tag: $tag already exists on $remote"

	echo "tag:    $tag at $(git rev-parse --short HEAD) ($branch; $PLUGIN $version)"
	echo "push:   $remote ($(gh_repo "$remote"))"
	if [ $dry = 1 ]; then echo "DRY-RUN nothing created or pushed"; return 0; fi
	git tag "$tag"
	git push "$remote" "refs/tags/$tag"
	echo "DONE pushed $tag to $remote — watch: gh run list --repo $(gh_repo "$remote") --branch $tag"
}

# --- main ------------------------------------------------------------------

# Global options may come before or after the subcommand.
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--plugin) [ $# -ge 2 ] || die "--plugin needs a directory"; PLUGIN_DIR_ARG="$2"; shift 2 ;;
		--plugin=*) PLUGIN_DIR_ARG="${1#--plugin=}"; shift ;;
		--tag-prefix) [ $# -ge 2 ] || die "--tag-prefix needs a value"; TAG_PREFIX="$2"; shift 2 ;;
		--tag-prefix=*) TAG_PREFIX="${1#--tag-prefix=}"; shift ;;
		*) ARGS+=("$1"); shift ;;
	esac
done
# bash 3.2 treats "${ARGS[@]}" of an empty array as unbound under set -u
set -- ${ARGS[@]+"${ARGS[@]}"}

[ $# -gt 0 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
	detect) cmd_detect "$@" ;;
	prs) cmd_prs "$@" ;;
	bump) cmd_bump "$@" ;;
	add-entries) cmd_add_entries "$@" ;;
	check) cmd_check "$@" ;;
	tag) cmd_tag "$@" ;;
	-h|--help|help) usage ;;
	*) die "unknown subcommand: $cmd (detect | prs | bump | add-entries | check | tag)" ;;
esac
