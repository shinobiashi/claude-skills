#!/usr/bin/env bash
# Scenario tests for release-bump.sh on a throwaway plugin repository with
# two bare remotes (origin = fork, upstream = canonical), a fake gh and a fake
# npm. No network. Usage: bash test-release-bump.sh [path/to/release-bump.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/release-bump.sh}"
case "$SCRIPT" in /*) ;; *) SCRIPT="$PWD/$SCRIPT" ;; esac
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0
TAB="$(printf '\t')"

ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" | sed 's/^/         | /' | head -20; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
run()   { OUT="$("$SCRIPT" "$@" 2>&1)"; RC=$?; }
has()   { printf '%s\n' "$OUT" | grep -qE -- "$1"; }

# ---- fixtures ------------------------------------------------------------
git init -q --bare "$W/upstream.git"
git init -q --bare "$W/origin.git"
git clone -q "$W/origin.git" "$W/repo" 2>/dev/null
cd "$W/repo"
git config user.email t@example.com
git config user.name tester
git remote add upstream "$W/upstream.git"
git checkout -q -b main

cat > my-plugin.php <<'EOF'
<?php
/**
 * Plugin Name: My Plugin
 * Version: 1.2.3
 */
define( 'MP_VERSION', '1.2.3' );

/**
 * Shipped in the 1.2.3 cycle.
 *
 * @since 1.2.3
 */
function mp_boot() {}
EOF
cat > readme.txt <<'EOF'
=== My Plugin ===
Contributors: tester
Stable tag: 1.2.3
License: GPLv2 or later

== Description ==

A plugin.

== Changelog ==

= 1.2.3 - 2026-01-01 =
* **Fixed** - Something that was broken (#5)

= 1.2.2 - 2025-12-01 =
* **Added** - The first thing

== Upgrade Notice ==

= 1.2.3 =
Nothing special.
EOF
cat > package.json <<'EOF'
{
  "name": "my-plugin",
  "version": "1.2.3",
  "scripts": {
    "version": "echo hook-must-not-run && exit 1"
  }
}
EOF
cat > package-lock.json <<'EOF'
{
  "name": "my-plugin",
  "version": "1.2.3",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "name": "my-plugin",
      "version": "1.2.3"
    },
    "node_modules/dep": {
      "version": "1.2.3"
    }
  }
}
EOF
printf -- '- **Version**: 1.2.3 | **PHP**: 8.3+\n' > CLAUDE.md
mkdir -p docs includes tests i18n .github/workflows
printf 'Shipped in 1.2.3.\nVersion 1.2.30 is unrelated and 11.2.3 too.\n' > docs/notes.md
cat > includes/class-foo.php <<'EOF'
<?php
/**
 * @since 1.2.3
 */
class MP_Foo {
	const VERSION = '1.2.3';
}
EOF
printf '<?php\n$this->assertSame( "1.2.3", MP_VERSION );\n' > tests/test-x.php
printf '"Project-Id-Version: My Plugin 1.2.3\\n"\n' > i18n/my-plugin.pot
git add -A && git commit -q -m init
git tag v1.2.2
git tag v1.2.3
git tag 1.2.3
git push -q -u origin main 2>/dev/null
git push -q upstream main --tags 2>/dev/null
git remote set-head upstream main
git remote set-head origin main
INIT="$(git rev-parse HEAD)"

merge_pr() { # number, branch, file, content -> merge sha in $SHA
	git checkout -q -b "$2" main
	mkdir -p "$(dirname "$3")"
	printf '%s\n' "$4" >> "$3"
	git add -A && git commit -q -m "$2 change"
	git checkout -q main
	git merge -q --no-ff -m "Merge pull request #$1 from x/$2" "$2"
	SHA="$(git rev-parse HEAD)"
}
merge_pr 10 f10 includes/class-foo.php "// __( 'New string', 'mp' );"; S10="$SHA"
merge_pr 11 f11 docs/notes.md "More notes."; S11="$SHA"
merge_pr 12 f12 .github/workflows/ci.yml "name: ci"; S12="$SHA"
git push -q upstream main 2>/dev/null
# a commit that is not on main at all (PR "merged" into another base)
git checkout -q -b stray main && printf 'x\n' > stray.txt && git add -A && git commit -q -m stray && S13="$(git rev-parse HEAD)" && git checkout -q main

# ---- fakes ---------------------------------------------------------------
mkdir -p "$W/bin"
cat > "$W/bin/gh" <<'EOF'
#!/usr/bin/env bash
# `gh pr list ... --jq` output as the real --jq would print it: number, sha, issues, title, files.
if [ "$1 $2" = "pr list" ]; then printf '%b' "${FAKE_PRS:-}"; exit 0; fi
echo "unexpected gh call: $*" >&2; exit 99
EOF
cat > "$W/bin/npm" <<'EOF'
#!/usr/bin/env bash
# fake `npm version <v> --no-git-tag-version ...`: rewrite package.json and the
# two top-level versions of package-lock.json, like npm does.
[ "$1" = version ] || { echo "unexpected npm call: $*" >&2; exit 99; }
v="$2"
case "$*" in *--ignore-scripts*) ;; *) echo "scripts not ignored" >&2; exit 98 ;; esac
for f in package.json package-lock.json; do
  [ -f "$f" ] || continue
  awk -v v="$v" '/^(  |      )"version": "/ && n < 2 { sub(/"version": "[^"]*"/, "\"version\": \"" v "\""); n++ } { print }' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
EOF
chmod +x "$W/bin/gh" "$W/bin/npm"
export PATH="$W/bin:$PATH"
# empty fields are "-", as the script's --jq filter prints them
export FAKE_PRS="9${TAB}${INIT}${TAB}-${TAB}old: in the tag${TAB}my-plugin.php
10${TAB}${S10}${TAB}7${TAB}fix: the thing${TAB}includes/class-foo.php
11${TAB}${S11}${TAB}-${TAB}docs: notes${TAB}docs/notes.md
12${TAB}${S12}${TAB}-${TAB}ci: workflow${TAB}.github/workflows/ci.yml
13${TAB}${S13}${TAB}-${TAB}stray: not on main${TAB}stray.txt
"

# ---- detect --------------------------------------------------------------
echo "== detect"
run detect
[ "$RC" -eq 0 ]; check "detect succeeds" $?
has '^PLUGIN_FILE=my-plugin.php$'; check "finds the main plugin file by its header" $?
has '^VERSION=1\.2\.3$'; check "reads the current version" $?
has '^PREVIOUS_TAG=1\.2\.3$'; check "unprefixed tag beats v1.2.3 and v1.2.2" $?
has '^REMOTE=upstream$' && has '^DEFAULT_BRANCH=main$'; check "canonical remote is upstream, default branch main" $?
[ "$(printf '%s\n' "$OUT" | grep -c '^CARRIER')" -eq 6 ]; check "6 carriers (header, define, const, Stable tag, package.json, CLAUDE.md)" $?
has "^CARRIER${TAB}my-plugin.php${TAB}4${TAB}" && has "^CARRIER${TAB}my-plugin.php${TAB}6${TAB}"; check "both lines of the plugin file are carriers" $?
has "^CARRIER${TAB}includes/class-foo.php${TAB}6${TAB}"; check "class constant is a carrier" $?
has "^MENTION${TAB}docs/notes.md${TAB}1${TAB}" && has "^MENTION${TAB}tests/test-x.php${TAB}"; check "docs and tests only mention the version" $?
has "^MENTION${TAB}my-plugin.php${TAB}9${TAB}"; check "prose in the plugin file is a mention, not a carrier" $?
! has '@since'; check "@since lines are not listed" $?
! has "= 1\.2\.3 - 2026" ; check "changelog headings are not listed" $?
! has "^MENTION${TAB}docs/notes.md${TAB}2${TAB}" ; check "1.2.30 and 11.2.3 do not match 1.2.3" $?
! has "pot" ; check ".pot files are skipped" $?
run detect --version 1.3.0
has '^RELEASE_BRANCH=release/1\.3\.0$' && has '^NEW_VERSION=1\.3\.0$'; check "--version adds the release branch name" $?
git tag -d 1.2.3 v1.2.3 >/dev/null
run detect
has '^PREVIOUS_TAG=v1\.2\.2$' && has '^WARN=.*v prefix'; check "v-prefixed previous tag is reported with a warning" $?
git tag 1.2.3 "$INIT" && git tag v1.2.3 "$INIT"
printf '{\n\t"name": "my-plugin",\n\t"version": "1.2.3",\n\t"scripts": {\n\t\t"version": "1.2.3"\n\t}\n}\n' > package.json
run detect
has "^CARRIER${TAB}package.json${TAB}3${TAB}" && has "^MENTION${TAB}package.json${TAB}5${TAB}"; check "tab-indented package.json: top-level version is a carrier, nested one a mention" $?
git checkout -q -- package.json

# ---- bump ----------------------------------------------------------------
echo "== bump"
printf '* **Fixed** - Entry one (#10)\n\n* **Changed** - Entry two\n' > "$W/entries.md"
echo dirty > dirty.txt
run bump 1.3.0 --entries "$W/entries.md"
[ "$RC" -ne 0 ] && has 'working tree has changes'; check "refuses a dirty tree" $?
rm dirty.txt
run bump v1.3.0
[ "$RC" -ne 0 ] && has 'not x.y.z'; check "refuses a v prefix" $?
run bump 1.3.0 --date 2026/02/01
[ "$RC" -ne 0 ] && has 'YYYY-MM-DD'; check "refuses a malformed date" $?

run bump 1.3.0 --date 2026-02-01 --entries "$W/entries.md"
[ "$RC" -eq 0 ]; check "bump succeeds" $?
grep -q '^ \* Version: 1.3.0$' my-plugin.php && grep -q "define( 'MP_VERSION', '1.3.0' );" my-plugin.php; check "plugin header and constant bumped" $?
grep -q '@since 1.2.3' my-plugin.php && grep -q '@since 1.2.3' includes/class-foo.php; check "@since docblocks untouched" $?
grep -q 'Shipped in the 1.2.3 cycle' my-plugin.php; check "prose mention in the plugin file untouched" $?
grep -q "const VERSION = '1.3.0';" includes/class-foo.php; check "class constant bumped" $?
grep -q '^Stable tag: 1.3.0$' readme.txt; check "Stable tag bumped" $?
grep -q '"version": "1.3.0"' package.json; check "package.json bumped (via npm)" $?
[ "$(grep -c '"version": "1.3.0"' package-lock.json)" -eq 2 ] && grep -q '"version": "1.2.3"' package-lock.json; check "package-lock.json: root and packages[\"\"] bumped, dependency version untouched" $?
grep -q 'Version\*\*: 1.3.0' CLAUDE.md; check "CLAUDE.md bumped" $?
grep -q 'Shipped in 1.2.3' docs/notes.md && grep -q '"1.2.3"' tests/test-x.php; check "docs and tests untouched" $?
grep -q '1.2.3' i18n/my-plugin.pot; check ".pot untouched" $?
EXPECT="$(cat <<'EOF'
== Changelog ==

= 1.3.0 - 2026-02-01 =
* **Fixed** - Entry one (#10)
* **Changed** - Entry two

= 1.2.3 - 2026-01-01 =
EOF
)"
[ "$(awk '/^== Changelog ==/{f=1} f' readme.txt | head -7)" = "$EXPECT" ]; check "changelog heading, entries and blank lines are exactly right" $?
grep -q '^= 1.2.3 =$' readme.txt && grep -q 'Nothing special' readme.txt; check "Upgrade Notice untouched" $?
git diff --quiet -- docs tests i18n; check "no other file changed" $?
run bump 1.3.0 --allow-dirty
[ "$RC" -ne 0 ] && has 'already at 1.3.0'; check "refuses to bump to the current version" $?
git checkout -q -- . && printf '\n= 1.4.0 - 2026-03-01 =\n' > "$W/x"
run bump 1.4.0 --date 2026-03-01
[ "$RC" -eq 0 ] && grep -q '^= 1.4.0 - 2026-03-01 =$' readme.txt; check "bump without --entries writes an empty block" $?
git checkout -q -- .
run bump 1.3.0
[ "$RC" -eq 0 ] && grep -q "^= 1.3.0 - $(date +%Y-%m-%d) =$" readme.txt; check "default date is today" $?
git checkout -q -- .
( PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v git)")"; export PATH; command -v npm >/dev/null && exit 3; "$SCRIPT" bump 1.3.0 --date 2026-02-01 >"$W/nonpm.out" 2>&1 )
RC=$?; OUT="$(cat "$W/nonpm.out")"
[ "$RC" -eq 0 ] && grep -q '"version": "1.3.0"' package.json && [ "$(grep -c '"version": "1.3.0"' package-lock.json)" -eq 2 ] && grep -q 'hook-must-not-run' package.json && has 'package-lock.json: rewritten without npm'; check "without npm the package files are rewritten directly" $?
git checkout -q -- .
printf '{\n\t"name": "my-plugin",\n\t"version": "1.2.3",\n\t"packages": {\n\t\t"": {\n\t\t\t"version": "1.2.3"\n\t\t},\n\t\t"node_modules/dep": {\n\t\t\t"version": "1.2.3"\n\t\t}\n\t}\n}\n' > package-lock.json
git add package-lock.json && git commit -q -m "tab lock"
( PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v git)")"; export PATH; "$SCRIPT" bump 1.3.0 --date 2026-02-01 >"$W/nonpm.out" 2>&1 )
RC=$?; OUT="$(cat "$W/nonpm.out")"
[ "$RC" -eq 0 ] && [ "$(grep -c '"version": "1.3.0"' package-lock.json)" -eq 2 ] && [ "$(sed -n '9p' package-lock.json)" = "$(printf '\t\t\t"version": "1.2.3"')" ]; check "without npm a tab-indented lock file: root and packages[\"\"] bumped, dependency untouched" $?
git checkout -q -- . && git reset -q --hard HEAD~1

# ---- add-entries ---------------------------------------------------------
echo "== add-entries"
printf '* **Fixed** - Something that was broken (#5)\n* **Security** - New line (#10)\n' > "$W/more.md"
run add-entries "$W/more.md"
[ "$RC" -eq 0 ] && has '1 new line'; check "adds only the line that is not there yet" $?
EXPECT="$(cat <<'EOF'
= 1.2.3 - 2026-01-01 =
* **Fixed** - Something that was broken (#5)
* **Security** - New line (#10)

= 1.2.2 - 2025-12-01 =
EOF
)"
[ "$(awk '/^= 1.2.3 - /{f=1} f' readme.txt | head -5)" = "$EXPECT" ]; check "new line sits after the last bullet, blank line kept" $?
run add-entries "$W/more.md"
[ "$RC" -eq 0 ] && has '0 new line'; check "second run adds nothing" $?
printf '* **Added** - Into the old block\n' > "$W/old.md"
run add-entries "$W/old.md" --version 1.2.2
[ "$RC" -eq 0 ] && [ "$(awk '/^= 1.2.2 - /{f=1} f' readme.txt | sed -n '3p')" = '* **Added** - Into the old block' ]; check "--version targets an older block" $?
run add-entries "$W/old.md" --version 9.9.9
[ "$RC" -ne 0 ] && has 'no changelog heading for 9.9.9'; check "unknown version is refused" $?
git checkout -q -- readme.txt
printf '== Changelog ==\n\n= 1.2.3 - 2026-01-01 =\n* only\n' > readme.txt
run add-entries "$W/old.md"
[ "$RC" -eq 0 ] && [ "$(tail -1 readme.txt)" = '* **Added** - Into the old block' ]; check "a block at the end of the file gets the line appended" $?
git checkout -q -- readme.txt

# ---- prs -----------------------------------------------------------------
echo "== prs"
run prs
[ "$RC" -eq 0 ]; check "prs succeeds" $?
[ "$(printf '%s\n' "$OUT" | grep -c "^1[0-9]${TAB}")" -eq 3 ]; check "3 PRs after the tag (#9 in the tag and #13 off main are dropped)" $?
has "^10${TAB}code${TAB}${S10:0:7}${TAB}7${TAB}no${TAB}fix: the thing$"; check "#10: code, linked issue 7, not referenced" $?
has "^11${TAB}docs${TAB}" && has "^12${TAB}ci${TAB}"; check "#11 is docs, #12 is ci" $?
run prs --skip 10,12
has "^10${TAB}code${TAB}[0-9a-f]{7}${TAB}7${TAB}skip${TAB}"; check "--skip marks the PR" $?
printf '* **Fixed** - Fixed the thing (#7)\n' > "$W/e7.md"
"$SCRIPT" add-entries "$W/e7.md" >/dev/null
run prs
has "^10${TAB}code${TAB}[0-9a-f]{7}${TAB}7${TAB}yes${TAB}"; check "an entry citing the linked issue counts as referenced" $?
git checkout -q -- readme.txt
run prs --since v1.2.2
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c "^1[0-9]${TAB}")" -eq 3 ]; check "--since accepts a v-prefixed tag" $?
run prs --since no-such-tag
[ "$RC" -ne 0 ] && has 'unknown tag'; check "unknown --since is refused" $?

# ---- check on a release branch ------------------------------------------
echo "== check"
git checkout -q -b release/1.3.0 main
printf '* **Fixed** - Fixed the thing (#10)\n' > "$W/entries.md"
"$SCRIPT" bump 1.3.0 --date 2026-02-01 --entries "$W/entries.md" >/dev/null
git add -A && git commit -q -m "chore: bump version to 1.3.0 and add changelog"
git push -q -u upstream release/1.3.0 2>/dev/null
run check
[ "$RC" -eq 0 ]; check "check passes on a complete release branch" $?
has '^OK +carriers: 6 lines' && has '^OK +heading: = 1\.3\.0 - 2026-02-01 ='; check "carriers and heading reported OK" $?
has '^OK +every code PR'; check "every code PR referenced" $?
has '^OK +up to date'; check "not behind upstream/main" $?
has '^WARN +1 added line\(s\) with translation calls.*POT regen'; check "translation call added without a .pot change is flagged" $?
run prs
has "^10${TAB}code${TAB}[0-9a-f]{7}${TAB}7${TAB}yes${TAB}"; check "prs reads the changelog from the single release/* branch on upstream by default" $?

git checkout -q main
merge_pr 14 f14 includes/class-bar.php "<?php // later fix"; S14="$SHA"
git push -q upstream main 2>/dev/null
export FAKE_PRS="${FAKE_PRS}14${TAB}${S14}${TAB}-${TAB}fix: later${TAB}includes/class-bar.php
"
git checkout -q release/1.3.0
run check
[ "$RC" -ne 0 ]; check "a code PR merged after the branch point fails the check" $?
has '^MISSING +code PRs without a changelog reference: #14' && has '#14 fix: later'; check "the missing PR is named with its title" $?
has '^BEHIND +2 commit'; check "and the branch is reported behind (branch commit + merge commit)" $?
run check --skip 14
! has '^MISSING' && has '^BEHIND'; check "--skip silences the reference, not the behind count" $?
git merge -q upstream/main 2>/dev/null
printf '* **Fixed** - Later fix (#14)\n' > "$W/e14.md"
"$SCRIPT" add-entries "$W/e14.md" >/dev/null
git add -A && git commit -q -m "chore: add the 1.3.0 changelog entry for #14"
run check
[ "$RC" -eq 0 ] && ! has '^BEHIND'; check "after merging main and adding the entry the check passes" $?
sed -e 's/^Stable tag: 1.3.0$/Stable tag: 1.2.3/' readme.txt > "$W/r" && cat "$W/r" > readme.txt
run check
[ "$RC" -ne 0 ] && has "^MISSING +readme.txt 'Stable tag:' is not 1.3.0"; check "a stale Stable tag is caught" $?
git checkout -q -- readme.txt

# ---- tag -----------------------------------------------------------------
echo "== tag"
run tag 1.3.0
[ "$RC" -ne 0 ] && has 'not on main'; check "refuses on a non-default branch" $?
git checkout -q main
run tag 1.3.0
[ "$RC" -ne 0 ] && has 'says 1.2.3, not 1.3.0'; check "refuses before the bump PR is merged" $?
git merge -q --no-ff -m "Merge pull request #15 from x/release/1.3.0" release/1.3.0
run tag 1.3.0
[ "$RC" -ne 0 ] && has 'HEAD is not upstream/main'; check "refuses when main is not pushed" $?
git push -q upstream main 2>/dev/null
run tag v1.3.0
[ "$RC" -ne 0 ] && has 'no v prefix'; check "refuses a v prefix" $?
run tag 1.3.0 --remote origin
[ "$RC" -ne 0 ] && has 'not the canonical remote'; check "refuses the fork" $?
echo dirty > dirty.txt
run tag 1.3.0
[ "$RC" -ne 0 ] && has 'working tree has changes'; check "refuses a dirty tree" $?
rm dirty.txt
run tag 1.3.0 --dry-run
[ "$RC" -eq 0 ] && has '^DRY-RUN' && [ -z "$(git tag --list 1.3.0)" ]; check "--dry-run creates nothing" $?
run tag 1.3.0
[ "$RC" -eq 0 ] && has '^DONE pushed 1\.3\.0 to upstream'; check "tag is created and pushed" $?
[ -n "$(git ls-remote --tags upstream refs/tags/1.3.0)" ]; check "upstream has the tag" $?
[ -z "$(git ls-remote --tags origin refs/tags/1.3.0)" ]; check "origin (the fork) does not" $?
run tag 1.3.0
[ "$RC" -ne 0 ] && has 'already exists'; check "a second run is refused" $?
git tag -d 1.3.0 >/dev/null
run tag 1.3.0
[ "$RC" -ne 0 ] && has 'already exists' && [ -n "$(git tag --list 1.3.0)" ]; check "a tag deleted locally is fetched back from the remote and refused" $?

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
