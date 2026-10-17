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
new WC_AM_Client_2_12_2( __FILE__, null, 188, '1.2.3', 'plugin', 'https://example.com/', 'My Plugin', 'mp' );
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
printf -- '- **Version**: 1.2.3 | **PHP**: 8.3+\n- Delivery meta is stored as entered since 1.2.3 (pitfall, must stay)\n- 現バージョン: 1.2.3\n- 1.2.3 までの版は手数料が 0 円になっていた（落とし穴、残す）\n' > CLAUDE.md
mkdir -p docs includes tests i18n .github/workflows
printf 'Shipped in 1.2.3.\nVersion 1.2.30 is unrelated and 11.2.3 too.\n' > docs/notes.md
cat > includes/class-foo.php <<'EOF'
<?php
/**
 * @since 1.2.3
 * @version 1.2.3
 */
class MP_Foo {
	const VERSION = '1.2.3';
}
EOF
# a class with its own @version that happens to equal the release: not a carrier
cat > includes/class-baz.php <<'EOF'
<?php
/**
 * @version 1.2.3
 */
class MP_Baz {}
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
[ "$(printf '%s\n' "$OUT" | grep -c '^CARRIER')" -eq 9 ]; check "9 carriers (header, define, WC_AM_Client, @version, const, Stable tag, package.json, CLAUDE.md x2)" $?
has "^CARRIER${TAB}my-plugin.php${TAB}4${TAB}" && has "^CARRIER${TAB}my-plugin.php${TAB}6${TAB}"; check "header and define of the plugin file are carriers" $?
has "^CARRIER${TAB}my-plugin.php${TAB}14${TAB}new WC_AM_Client"; check "the WC_AM_Client version argument is a carrier" $?
has "^CARRIER${TAB}includes/class-foo.php${TAB}7${TAB}"; check "class constant is a carrier" $?
has "^CARRIER${TAB}includes/class-foo.php${TAB}4${TAB} \* @version 1\.2\.3$"; check "@version in a file that holds a carrier is a carrier" $?
! has "class-baz"; check "@version in a file without a carrier is not listed" $?
has "^CARRIER${TAB}CLAUDE.md${TAB}1${TAB}" && has "^MENTION${TAB}CLAUDE.md${TAB}2${TAB}"; check "CLAUDE.md: the Version line is a carrier, a 'since x.y.z' pitfall is a mention" $?
has "^CARRIER${TAB}CLAUDE.md${TAB}3${TAB}- 現バージョン" && has "^MENTION${TAB}CLAUDE.md${TAB}4${TAB}"; check "CLAUDE.md: '現バージョン: x.y.z' is a carrier, Japanese prose a mention" $?
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
grep -q "188, '1.3.0', 'plugin'" my-plugin.php; check "WC_AM_Client version argument bumped" $?
grep -q '^ \* @version 1.3.0$' includes/class-foo.php && grep -q '^ \* @version 1.2.3$' includes/class-baz.php; check "@version bumped next to the class constant, a class's own @version untouched" $?
grep -q '^Stable tag: 1.3.0$' readme.txt; check "Stable tag bumped" $?
grep -q '"version": "1.3.0"' package.json; check "package.json bumped (via npm)" $?
[ "$(grep -c '"version": "1.3.0"' package-lock.json)" -eq 2 ] && grep -q '"version": "1.2.3"' package-lock.json; check "package-lock.json: root and packages[\"\"] bumped, dependency version untouched" $?
grep -q 'Version\*\*: 1.3.0' CLAUDE.md && grep -q 'since 1.2.3 (pitfall' CLAUDE.md; check "CLAUDE.md: version line bumped, pitfall prose untouched" $?
grep -q '^- 現バージョン: 1.3.0$' CLAUDE.md && grep -q '^- 1.2.3 までの版' CLAUDE.md; check "CLAUDE.md: '現バージョン' bumped, Japanese prose untouched" $?
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
git diff --quiet -- docs tests i18n includes/class-baz.php; check "no other file changed" $?
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
has '^OK +carriers: 9 lines' && has '^OK +heading: = 1\.3\.0 - 2026-02-01 ='; check "carriers and heading reported OK" $?
has '^OK +every code PR'; check "every code PR referenced" $?
has '^OK +up to date'; check "not behind upstream/main" $?
has '^WARN +1 added line\(s\) with translation calls.*POT regen'; check "translation call added without a .pot change is flagged" $?
# the POT is regenerated on the release branch, before main has it
printf '"Project-Id-Version: My Plugin 1.3.0\\n"\nmsgid "New string"\n' > i18n/my-plugin.pot
git add -A && git commit -q -m "chore: regenerate the POT"
run check
[ "$RC" -eq 0 ] && has '^OK +1 added line\(s\) with translation calls.*regenerated after all of them'; check "a POT regen on the release branch (not yet on main) clears the warning" $?
printf "<?php\n// __( 'Later string', 'mp' );\n" > includes/class-qux.php
git add -A && git commit -q -m "feat: later string"
LATE="$(git rev-parse --short=7 HEAD)"
run check
has "^WARN +translation calls changed after i18n/my-plugin.pot was last regenerated .*: ${LATE} "; check "a translation change after the regen is named by its commit" $?
git reset -q --hard HEAD~1
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

# ---- monorepo: plugins/<slug>/ ------------------------------------------
# Two plugins at the same version (free with a readme without dates, pro
# without a readme), root tooling at that version too, v* and pro-v* tags.
echo "== monorepo"
git init -q --bare "$W/mono-up.git"
git clone -q "$W/mono-up.git" "$W/mono" 2>/dev/null
cd "$W/mono"
git config user.email t@example.com
git config user.name tester
git checkout -q -b main
mkdir -p plugins/free/includes plugins/free/languages plugins/pro bin tools/mu .claude/skills
cat > plugins/free/free.php <<'EOF'
<?php
/**
 * Plugin Name: Free
 * Version: 1.2.3
 */
define( 'FREE_VERSION', '1.2.3' );

/**
 * @since 1.2.3
 */
function free_boot() {}
EOF
cat > plugins/free/readme.txt <<'EOF'
=== Free ===
Stable tag: 1.2.3

== Changelog ==

= 1.2.3 =
* Old entry.

== Upgrade Notice ==

= 1.2.3 =
Nothing.
EOF
printf '{\n  "name": "free",\n  "version": "1.2.3"\n}\n' > plugins/free/package.json
printf '"Project-Id-Version: Free 1.2.3\\n"\n' > plugins/free/languages/free.pot
printf '<?php\n// free code\n' > plugins/free/includes/class-a.php
cat > plugins/pro/pro.php <<'EOF'
<?php
/**
 * Plugin Name: Pro
 * Version: 1.2.3
 */
define( 'PRO_VERSION', '1.2.3' );
EOF
printf '{\n  "name": "dev-tools",\n  "version": "1.2.3"\n}\n' > package.json
printf -- '- Version: 1.2.3\n' > CLAUDE.md
printf '#!/bin/sh\n' > bin/tool.sh
# plugins that are not release candidates: no readme, or under a dot directory
printf '<?php\n/**\n * Plugin Name: MU helper\n */\n' > tools/mu/mu.php
printf '<?php\n/**\n * Plugin Name: Template\n */\n' > .claude/skills/template.php
printf '=== Template ===\n' > .claude/skills/readme.txt
git add -A && git commit -q -m init
git tag v1.2.3
git tag pro-v1.2.3
git tag pro-v1.2.9
git push -q -u origin main --tags 2>/dev/null
git remote set-head origin main

run detect
[ "$RC" -eq 0 ] && has '^PLUGIN_FILE=plugins/free/free\.php$' && has '^PLUGIN_DIR=plugins/free$' && has '^README=plugins/free/readme\.txt$'; check "monorepo: detect finds the one plugins/<slug>/ with a readme.txt" $?
[ "$(printf '%s\n' "$OUT" | grep -c '^CARRIER')" -eq 4 ] && [ -z "$(printf '%s\n' "$OUT" | grep '^CARRIER' | grep -v "${TAB}plugins/free/")" ]; check "monorepo: 4 carriers, all in plugins/free (header, define, Stable tag, its package.json)" $?
has "^MENTION${TAB}package.json${TAB}3${TAB}" && has "^MENTION${TAB}CLAUDE.md${TAB}1${TAB}"; check "monorepo: the root package.json and CLAUDE.md are only mentions" $?
! has 'plugins/pro'; check "monorepo: the other plugin at the same version is not listed" $?
has '^HEADING_STYLE=bare$'; check "a readme whose headings have no date: bare style" $?
has '^PREVIOUS_TAG=v1\.2\.3$' && has '^WARN=.*--tag-prefix v'; check "no prefix: v1.2.3 is the previous tag (pro-v* ignored), with a warning" $?
run detect --tag-prefix v --version 1.3.0
has '^PREVIOUS_TAG=v1\.2\.3$' && has '^TAG_PREFIX=v$' && has '^NEW_TAG=v1\.3\.0$' && ! has '^WARN='; check "--tag-prefix v: previous tag, new tag, no warning" $?
run detect --plugin plugins/pro --tag-prefix pro-v
has '^PLUGIN_FILE=plugins/pro/pro\.php$' && has '^PREVIOUS_TAG=pro-v1\.2\.9$' && has '^README=plugins/pro/readme\.txt \(missing\)$' && has "^CARRIER${TAB}plugins/pro/pro.php${TAB}6${TAB}" && ! has 'plugins/free'; check "--plugin selects the other plugin; --tag-prefix pro-v picks pro-v1.2.9" $?
printf '=== Pro ===\nStable tag: 1.2.3\n' > plugins/pro/readme.txt
run detect
[ "$RC" -ne 0 ] && has 'more than one plugin directory' && has 'plugins/free plugins/pro'; check "two plugin directories with a readme are refused without --plugin" $?
run detect --plugin plugins/free/
[ "$RC" -eq 0 ] && has '^PLUGIN_FILE=plugins/free/free\.php$'; check "--plugin with a trailing slash" $?
OUT="$(RELEASE_BUMP_PLUGIN_DIR=./plugins/free "$SCRIPT" detect 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && has '^PLUGIN_FILE=plugins/free/free\.php$'; check "RELEASE_BUMP_PLUGIN_DIR=./plugins/free" $?
run "--plugin=$W/mono/plugins/free" detect
[ "$RC" -eq 0 ] && has '^PLUGIN_DIR=plugins/free$'; check "an absolute --plugin= before the subcommand" $?
rm plugins/pro/readme.txt
run detect --plugin plugins/none
[ "$RC" -ne 0 ] && has 'no directory plugins/none'; check "a missing --plugin directory is refused" $?
run detect --plugin ../mono
[ "$RC" -ne 0 ] && has 'without \. or \.\. parts'; check "a --plugin path with .. is refused" $?
run detect --plugin bin
[ "$RC" -ne 0 ] && has "no \*\.php with a 'Plugin Name:' header in bin"; check "a --plugin directory without a plugin file is refused" $?

printf '* Fixed the thing (#20)\n' > "$W/m-entries.md"
run bump 1.3.0 --date 2026-02-01 --entries "$W/m-entries.md"
[ "$RC" -eq 0 ] && has '^NOTE .*have no date'; check "monorepo bump succeeds; --date is not written into a readme without dates" $?
grep -q '^ \* Version: 1.3.0$' plugins/free/free.php && grep -q "define( 'FREE_VERSION', '1.3.0' );" plugins/free/free.php && grep -q '@since 1.2.3' plugins/free/free.php; check "monorepo: header and constant bumped, @since untouched" $?
grep -q '^Stable tag: 1.3.0$' plugins/free/readme.txt && grep -q '"version": "1.3.0"' plugins/free/package.json; check "monorepo: Stable tag and the plugin's package.json (npm in its directory) bumped" $?
grep -q '^ \* Version: 1.2.3$' plugins/pro/pro.php && grep -q "define( 'PRO_VERSION', '1.2.3' );" plugins/pro/pro.php; check "monorepo: the other plugin is untouched" $?
grep -q '"version": "1.2.3"' package.json && grep -q 'Version: 1.2.3' CLAUDE.md; check "monorepo: the root package.json and CLAUDE.md are untouched" $?
EXPECT="$(cat <<'EOF'
== Changelog ==

= 1.3.0 =
* Fixed the thing (#20)

= 1.2.3 =
EOF
)"
[ "$(awk '/^== Changelog ==/{f=1} f' plugins/free/readme.txt | head -6)" = "$EXPECT" ]; check "a heading without a date, entries and blank lines are exactly right" $?
git checkout -q -- .

merge_pr 20 f20 plugins/free/includes/class-a.php "// fix"; M20="$SHA"
merge_pr 21 f21 plugins/pro/pro.php "// __( 'Pro string', 'pro' );"; M21="$SHA"
merge_pr 22 f22 bin/tool.sh "echo hi"; M22="$SHA"
merge_pr 23 f23 plugins/free/docs/notes.md "Notes."; M23="$SHA"
git checkout -q -b f24 main
printf '<?php\n// both\n' > plugins/free/includes/class-b.php && printf 'echo both\n' >> bin/tool.sh
git add -A && git commit -q -m "f24 change" && git checkout -q main
git merge -q --no-ff -m "Merge pull request #24 from x/f24" f24
M24="$(git rev-parse HEAD)"
git push -q origin main 2>/dev/null
export FAKE_PRS="20${TAB}${M20}${TAB}-${TAB}fix: free${TAB}plugins/free/includes/class-a.php
21${TAB}${M21}${TAB}-${TAB}feat: pro${TAB}plugins/pro/pro.php
22${TAB}${M22}${TAB}-${TAB}chore: tool${TAB}bin/tool.sh
23${TAB}${M23}${TAB}-${TAB}docs: free notes${TAB}plugins/free/docs/notes.md
24${TAB}${M24}${TAB}-${TAB}fix: both${TAB}bin/tool.sh plugins/free/includes/class-b.php
"
export RELEASE_BUMP_TAG_PREFIX=v
run prs
[ "$RC" -eq 0 ] && has "^20${TAB}code${TAB}" && has "^24${TAB}code${TAB}" && has "^23${TAB}docs${TAB}"; check "monorepo prs: a PR with a file in the plugin is code (or docs), whatever else it touches" $?
has "^21${TAB}outside${TAB}" && has "^22${TAB}outside${TAB}"; check "monorepo prs: the other plugin's and the tooling's PRs are outside" $?

git checkout -q -b release/1.3.0 main
"$SCRIPT" bump 1.3.0 --entries "$W/m-entries.md" >/dev/null
git add -A && git commit -q -m "chore: bump version to 1.3.0 and add changelog"
git push -q -u origin release/1.3.0 2>/dev/null
run check
[ "$RC" -ne 0 ] && has '^MISSING +code PRs without a changelog reference: #24$' && ! has '#2[123] '; check "monorepo check: only the plugin's unreferenced code PR is missing" $?
has '^OK +heading: = 1\.3\.0 =$' && has '^OK +carriers: 4 lines'; check "monorepo check: a heading without a date is OK, 4 carriers" $?
has '^OK +no translation calls added'; check "monorepo check: a translation call in the other plugin does not ask for this plugin's POT" $?
printf '* Fixed both (#24)\n' > "$W/m24.md"
"$SCRIPT" add-entries "$W/m24.md" >/dev/null
[ "$(awk '/^= 1.3.0 =/{f=1} f' plugins/free/readme.txt | sed -n '3p')" = '* Fixed both (#24)' ]; check "monorepo add-entries writes into the plugin's readme" $?
git add -A && git commit -q -m "chore: add the 1.3.0 changelog entry for #24"
printf "<?php\n// __( 'Free string', 'free' );\n" > plugins/free/includes/class-c.php
git add -A && git commit -q -m "feat: free string"
run check
has '^WARN +1 added line\(s\) with translation calls.*no \.pot change'; check "monorepo check: a translation call in the plugin asks for its POT" $?
git reset -q --hard HEAD~1
git push -q origin release/1.3.0 2>/dev/null
run check
[ "$RC" -eq 0 ]; check "monorepo check passes once the entry is in" $?

git checkout -q main
git merge -q --no-ff -m "Merge pull request #25 from x/release/1.3.0" release/1.3.0
git push -q origin main 2>/dev/null
run tag 1.3.0 --dry-run
[ "$RC" -eq 0 ] && has '^tag: +v1\.3\.0 at .*plugins/free/free\.php 1\.3\.0'; check "monorepo tag --dry-run names v1.3.0" $?
run tag 1.3.0 --tag-prefix 'bad prefix '
[ "$RC" -ne 0 ] && has 'not a valid tag name'; check "an invalid tag prefix is refused" $?
run tag 1.3.0
[ "$RC" -eq 0 ] && [ -n "$(git ls-remote --tags origin refs/tags/v1.3.0)" ] && [ -z "$(git ls-remote --tags origin refs/tags/1.3.0)" ]; check "monorepo tag pushes v1.3.0, not 1.3.0" $?
run tag 1.3.0
[ "$RC" -ne 0 ] && has 'v1\.3\.0 already exists'; check "a second run is refused by the prefixed name" $?
unset RELEASE_BUMP_TAG_PREFIX

# ---- a plugin file git does not track yet --------------------------------
echo "== untracked"
git init -q "$W/fresh"
cd "$W/fresh"
printf '<?php\n/**\n * Plugin Name: Fresh\n * Version: 0.1.0\n */\n' > fresh.php
printf '=== Fresh ===\nStable tag: 0.1.0\n\n== Changelog ==\n\n= 0.1.0 =\n* First.\n' > readme.txt
run detect
[ "$RC" -eq 0 ] && has '^WARN=fresh\.php is not tracked' && ! has '^CARRIER'; check "detect warns that an untracked plugin file has no carriers" $?
run bump 0.2.0 --allow-dirty
[ "$RC" -ne 0 ] && has "not among the carriers" && grep -q '^ \* Version: 0.1.0$' fresh.php && ! grep -q '0\.2\.0' readme.txt; check "bump refuses and writes nothing when the header is not a carrier" $?

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
