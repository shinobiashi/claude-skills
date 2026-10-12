#!/usr/bin/env bash
# Scenario tests for po-add-entry.py on a throwaway plugin repository with a
# WP-CLI style .pot (no wrapping), a Poedit style ja .po (wrapped at 79
# columns, nplurals=1) and a .mo built from it. No network.
# Usage: bash test-po-add-entry.sh [path/to/po-add-entry.py]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/po-add-entry.py}"
case "$SCRIPT" in /*) ;; *) SCRIPT="$PWD/$SCRIPT" ;; esac
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()    { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()   { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" | sed 's/^/         | /' | head -20; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
run()   { OUT="$(python3 "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has()   { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
sums()  { cat lang/dom.pot lang/dom-ja.po lang/dom-ja.mo 2>/dev/null | cksum; }
line_of() { grep -nF -- "$1" "$2" | head -1 | cut -d: -f1; }
# The entry (blank-line separated block) of a .po/.pot that contains $1.
entry() { awk -v RS= -v needle="$1" 'index($0, needle) { print; exit }' "$2"; }
# Translation the compiled .mo returns for msgid $1 (context $2, plural $3, n $4).
mo_get() {
	python3 - "$1" "${2:-}" "${3:-}" "${4:-1}" <<'EOF'
import gettext, sys
msgid, ctx, plural, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
t = gettext.GNUTranslations(open("lang/dom-ja.mo", "rb"))
if plural:
    print(t.ngettext(msgid, plural, n))
elif ctx:
    print(t.pgettext(ctx, msgid))
else:
    print(t.gettext(msgid))
EOF
}

# ---- fixtures ------------------------------------------------------------
fixtures() {
	rm -rf "$W/repo"
	mkdir -p "$W/repo/inc" "$W/repo/tests" "$W/repo/lang"
	cd "$W/repo" || exit 2
	git init -q .
	cat > inc/class-a.php <<'EOF'
<?php
// Fixture for po-add-entry.py.
echo esc_html__( 'Alpha', 'dom' );

function dom_gamma( $name ) {
	// The new string sits between Alpha (line 3) and Omega (line 40).
	return sprintf( __( 'Gamma %s', 'dom' ), $name );
}

function dom_delta() {
	return __(
		'Delta',
		'dom'
	);
}

echo _n( 'One item', '%d items', 2, 'dom' );
echo _x( 'Post', 'noun', 'dom' );
echo __( 'Don\'t "stop"', 'dom' );
$label = 'Epsilon';
echo __( 'Zeta is a long sentence that is clearly longer than the seventy-nine columns gettext wraps at.', 'dom' );
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
// Filler.
echo esc_html__( 'Omega', 'dom' );
EOF
	cat > tests/test-a.php <<'EOF'
<?php
$this->assertSame( 'x', __( 'Gamma %s', 'dom' ) );
EOF
	cat > inc/class-b.php <<'EOF'
<?php
echo __( 'Beta', 'dom' );
echo __( 'Theta', 'dom' );
EOF
	git add inc tests
	cat > lang/dom.pot <<'EOF'
# Copyright (C) 2026 Test
# This file is distributed under the same license as the Test plugin.
msgid ""
msgstr ""
"Project-Id-Version: Test 1.0\n"
"MIME-Version: 1.0\n"
"Content-Type: text/plain; charset=UTF-8\n"
"Content-Transfer-Encoding: 8bit\n"
"X-Generator: WP-CLI 2.12.0\n"

#: inc/class-a.php:3
msgid "Alpha"
msgstr ""

#: inc/class-a.php:40
msgid "Omega"
msgstr ""

#: inc/class-a.php:41
msgid ""
"Line one\n"
"Line two"
msgstr ""

#: inc/class-b.php:2
msgid "Beta, a string that WP-CLI writes on a single line however long it happens to get"
msgstr ""
EOF
	cat > lang/dom-ja.po <<'EOF'
# Translation of Test in Japanese
msgid ""
msgstr ""
"Project-Id-Version: Test 1.0\n"
"Language: ja_JP\n"
"MIME-Version: 1.0\n"
"Content-Type: text/plain; charset=UTF-8\n"
"Content-Transfer-Encoding: 8bit\n"
"Plural-Forms: nplurals=1; plural=0;\n"
"X-Generator: Poedit 3.9\n"

#: inc/class-a.php:3
msgid "Alpha"
msgstr "アルファ"

#: inc/class-a.php:40
msgid "Omega"
msgstr "オメガ"

#: inc/class-b.php:2
msgid ""
"Beta, a string that WP-CLI writes on a single line however long it happens "
"to get"
msgstr "ベータ"

#~ msgid "Old"
#~ msgstr "古い"
EOF
	msgfmt -o lang/dom-ja.mo lang/dom-ja.po
}

POT=(--pot lang/dom.pot)
PO=(--po lang/dom-ja.po)

# ---- 1. basic add ----------------------------------------------------------
echo "1. add a string with a placeholder"
fixtures
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s'
check "exit 0" $([ "$RC" -eq 0 ]; echo $?)
check "reference is the call in inc/, not the copy in tests/" $(has 'references: inc/class-a.php:7' && ! has 'tests/'; echo $?)
check "reports the php-format flag" $(has 'flag: php-format'; echo $?)
E="$(entry 'msgid "Gamma %s"' lang/dom.pot)"
check ".pot entry: reference, flag, empty msgstr" $([ "$E" = "$(printf '#: inc/class-a.php:7\n#, php-format\nmsgid "Gamma %%s"\nmsgstr ""')" ]; echo $?)
check ".pot: inserted after Alpha (line 3), before Omega (line 40)" $(a=$(line_of '"Alpha"' lang/dom.pot); g=$(line_of '"Gamma %s"' lang/dom.pot); o=$(line_of '"Omega"' lang/dom.pot); [ "$a" -lt "$g" ] && [ "$g" -lt "$o" ]; echo $?)
check ".po: inserted after Alpha, before Omega" $(a=$(line_of '"Alpha"' lang/dom-ja.po); g=$(line_of '"Gamma %s"' lang/dom-ja.po); o=$(line_of '"Omega"' lang/dom-ja.po); [ "$a" -lt "$g" ] && [ "$g" -lt "$o" ]; echo $?)
check ".po entry has the translation" $(entry 'msgid "Gamma %s"' lang/dom-ja.po | grep -qx 'msgstr "ガンマ %s"'; echo $?)
check ".mo returns the translation" $([ "$(mo_get 'Gamma %s')" = 'ガンマ %s' ]; echo $?)
check ".mo still returns the old ones" $([ "$(mo_get 'Alpha')" = 'アルファ' ] && [ "$(mo_get 'Omega')" = 'オメガ' ]; echo $?)
check "reports the .mo differs by exactly the new entry" $(has 'differs from the old one by exactly the new entry'; echo $?)
check "blank lines stay single" $(! awk 'NR > 1 && prev == "" && $0 == "" {f = 1} {prev = $0} END {exit !f}' lang/dom.pot lang/dom-ja.po; echo $?)
check "msgfmt accepts both files" $(msgfmt -o /dev/null lang/dom.pot && msgfmt --check-format -o /dev/null lang/dom-ja.po; echo $?)

# ---- 2. running again --------------------------------------------------------
echo "2. the same string again"
S="$(sums)"
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s'
check "exit 1" $([ "$RC" -eq 1 ]; echo $?)
check "says the .po already has it" $(has 'already has this entry (msgstr "ガンマ %s")'; echo $?)
check "nothing written" $([ "$(sums)" = "$S" ]; echo $?)

# ---- 3. a second locale: the .pot is left alone -------------------------------
echo "3. .pot already has the entry, a .po without it"
fixtures
run --msgid 'Gamma %s' "${POT[@]}"
check ".pot only: exit 0, no .mo step" $([ "$RC" -eq 0 ] && ! has 'mo:'; echo $?)
S_POT="$(cksum < lang/dom.pot)"
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s'
check "exit 0" $([ "$RC" -eq 0 ]; echo $?)
check "says the .pot was left alone" $(has 'already has this entry; left alone'; echo $?)
check ".pot unchanged" $([ "$(cksum < lang/dom.pot)" = "$S_POT" ]; echo $?)
check ".pot has the entry once" $([ "$(grep -c 'msgid "Gamma %s"' lang/dom.pot)" -eq 1 ]; echo $?)

# ---- 4. placeholder check -----------------------------------------------------
echo "4. a translation that drops the placeholder"
fixtures
S="$(sums)"
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ'
check "exit 1" $([ "$RC" -eq 1 ]; echo $?)
check "msgfmt --check-format explains" $(has 'msgfmt --check-format rejected the translation' && has "doesn't exist in 'msgstr'"; echo $?)
check "nothing written" $([ "$(sums)" = "$S" ]; echo $?)

# ---- 5. a .mo not built from this .po --------------------------------------
echo "5. the old .mo was not built from this .po"
fixtures
sed 's/msgstr "オメガ"/msgstr "古いオメガ"/' lang/dom-ja.po > "$W/stale.po" && msgfmt -o lang/dom-ja.mo "$W/stale.po"
S="$(sums)"
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s'
check "exit 1" $([ "$RC" -eq 1 ]; echo $?)
check "names the other changed entry" $(has 'changed: Omega'; echo $?)
check "nothing written (.pot and .po too)" $([ "$(sums)" = "$S" ]; echo $?)
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s' --accept-mo-drift
check "--accept-mo-drift: exit 0 and lists the drift" $([ "$RC" -eq 0 ] && has 'also changes 1 other entries' && [ "$(mo_get 'Omega')" = 'オメガ' ]; echo $?)

# ---- 6. no .mo yet ----------------------------------------------------------
echo "6. no .mo yet"
fixtures
rm lang/dom-ja.mo
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s'
check "exit 0, creates the .mo" $([ "$RC" -eq 0 ] && has 'mo:  created' && [ "$(mo_get 'Gamma %s')" = 'ガンマ %s' ]; echo $?)

# ---- 7. --no-mo, --mo ---------------------------------------------------------
echo "7. --no-mo and --mo"
fixtures
S_MO="$(cksum < lang/dom-ja.mo)"
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s' --no-mo
check "--no-mo leaves the .mo alone" $([ "$RC" -eq 0 ] && [ "$(cksum < lang/dom-ja.mo)" = "$S_MO" ] && ! has 'mo:'; echo $?)
fixtures
mkdir -p "$W/repo/lang/compiled"
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s' --mo lang/compiled/dom-ja.mo
check "--mo writes the named file" $([ "$RC" -eq 0 ] && [ -s lang/compiled/dom-ja.mo ] && [ "$(cksum < lang/dom-ja.mo)" = "$S_MO" ]; echo $?)

echo "7b. a .l10n.php next to the .po"
fixtures
printf '<?php\nreturn array();\n' > lang/dom-ja.l10n.php
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s'
check "says WordPress loads the .l10n.php instead" $([ "$RC" -eq 0 ] && has 'loads lang/dom-ja.l10n.php instead of the .mo' && has 'wp i18n make-php lang'; echo $?)

# ---- 8. a call split over lines ------------------------------------------------
echo "8. __( on its own line"
fixtures
run --msgid 'Delta' "${POT[@]}" "${PO[@]}" --msgstr 'デルタ'
check "reference is the line of the call" $([ "$RC" -eq 0 ] && has 'references: inc/class-a.php:11'; echo $?)

# ---- 9. not found / not in a call / --ref --------------------------------------
echo "9. finding references"
fixtures
S="$(sums)"
run --msgid 'Epsilon' "${POT[@]}" "${PO[@]}" --msgstr 'イプシロン'
check "a literal outside a gettext call: exit 2, noted, nothing written" $([ "$RC" -eq 2 ] && has 'inc/class-a.php:20 has the string, but not as the first argument' && [ "$(sums)" = "$S" ]; echo $?)
run --msgid 'Nowhere' "${POT[@]}" "${PO[@]}" --msgstr 'どこにも'
check "missing everywhere: exit 2 with a hint" $([ "$RC" -eq 2 ] && has 'pass --ref PATH:LINE'; echo $?)
run --msgid 'Nowhere' "${POT[@]}" "${PO[@]}" --msgstr 'どこにも' --ref inc/class-c.php:4 --ref inc/class-b.php:9
check "--ref: uses each reference" $([ "$RC" -eq 0 ] && [ "$(entry '"Nowhere"' lang/dom.pot | grep -c '^#: ')" -eq 2 ]; echo $?)
check "--ref to a file no entry has yet: appended to the .pot" $([ "$(tail -1 lang/dom.pot)" = 'msgstr ""' ] && [ "$(line_of '"Nowhere"' lang/dom.pot)" -gt "$(line_of '"Beta, a string' lang/dom.pot)" ]; echo $?)
check "--ref to a file no entry has yet: before the .po's obsolete entries" $(n=$(line_of '"Nowhere"' lang/dom-ja.po); o=$(line_of '#~ msgid "Old"' lang/dom-ja.po); [ "$n" -lt "$o" ] && [ "$n" -gt "$(line_of '"Omega"' lang/dom-ja.po)" ]; echo $?)

# ---- 10. quotes and apostrophes ----------------------------------------------
echo "10. a string with ' and \""
fixtures
run --msgid "Don't \"stop\"" "${POT[@]}" "${PO[@]}" --msgstr '「止まるな」'
check "found through the PHP escapes" $([ "$RC" -eq 0 ] && has 'references: inc/class-a.php:19'; echo $?)
check "escaped in the .pot" $(grep -qxF 'msgid "Don'"'"'t \"stop\""' lang/dom.pot; echo $?)
check ".mo returns it" $([ "$(mo_get "Don't \"stop\"")" = '「止まるな」' ]; echo $?)

# ---- 11. wrapping follows each file ----------------------------------------
echo "11. wrapping"
fixtures
LONG='Zeta is a long sentence that is clearly longer than the seventy-nine columns gettext wraps at.'
run --msgid "$LONG" "${POT[@]}" "${PO[@]}" --msgstr 'ゼータはとても長い文で、gettext が折り返す 79 桁よりも明らかに長くなっています。'
check "exit 0" $([ "$RC" -eq 0 ]; echo $?)
check ".pot (WP-CLI): one line" $(grep -qxF "msgid \"$LONG\"" lang/dom.pot; echo $?)
check ".po (Poedit): wrapped" $(entry 'Zeta is a long' lang/dom-ja.po | grep -qx 'msgid ""'; echo $?)
check ".po: msgcat would not rewrap it" $(printf 'msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n\n%s\n' "$(entry 'Zeta is a long' lang/dom-ja.po)" > "$W/e.po"; msgcat --width=79 -o "$W/e2.po" "$W/e.po"; [ "$(entry 'Zeta is a long' "$W/e.po")" = "$(entry 'Zeta is a long' "$W/e2.po")" ]; echo $?)
check "a .pot multi-line string (split at \\n) is not taken as wrapping" $(! entry 'Zeta is a long' lang/dom.pot | grep -qx 'msgid ""'; echo $?)

# ---- 12. plural and context --------------------------------------------------
echo "12. _n() and _x()"
fixtures
run --msgid 'One item' --msgid-plural '%d items' "${POT[@]}" "${PO[@]}" --msgstr '%d 個' --msgstr 'x'
check "plural with the wrong number of forms: exit 2" $([ "$RC" -eq 2 ] && has 'nplurals=1; give --msgstr 1 times'; echo $?)
run --msgid 'One item' --msgid-plural '%d items' "${POT[@]}" "${PO[@]}" --msgstr '%d 個'
check "plural: exit 0" $([ "$RC" -eq 0 ]; echo $?)
check "plural .pot: msgid_plural and two empty forms" $(E="$(entry '"One item"' lang/dom.pot)"; printf '%s\n' "$E" | grep -qx 'msgid_plural "%d items"' && printf '%s\n' "$E" | grep -qx 'msgstr\[1\] ""' && printf '%s\n' "$E" | grep -qx '#, php-format'; echo $?)
check "plural .mo returns it" $([ "$(mo_get 'One item' '' '%d items' 3)" = '%d 個' ]; echo $?)
run --msgid 'Post' --context 'noun' "${POT[@]}" "${PO[@]}" --msgstr '投稿'
check "context: exit 0, msgctxt written" $([ "$RC" -eq 0 ] && entry '"Post"' lang/dom.pot | grep -qx 'msgctxt "noun"'; echo $?)
check "context .mo returns it" $([ "$(mo_get 'Post' 'noun')" = '投稿' ]; echo $?)
run --msgid 'Post' --context 'verb' "${POT[@]}" "${PO[@]}" --msgstr '投稿する' --ref inc/class-a.php:18
check "the same msgid in another context is a new entry" $([ "$RC" -eq 0 ] && [ "$(grep -c '^msgid "Post"' lang/dom-ja.po)" -eq 2 ]; echo $?)

# ---- 13. comment, --after, --dry-run ------------------------------------------
echo "13. --comment, --after, --dry-run"
fixtures
S="$(sums)"
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s' --dry-run
check "--dry-run: exit 0, says so, nothing written" $([ "$RC" -eq 0 ] && has 'dry run: nothing written' && [ "$(sums)" = "$S" ]; echo $?)
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s' --after 'Nope'
check "--after an unknown msgid: exit 2, nothing written" $([ "$RC" -eq 2 ] && [ "$(sums)" = "$S" ]; echo $?)
run --msgid 'Gamma %s' "${POT[@]}" "${PO[@]}" --msgstr 'ガンマ %s' --after 'Omega' --comment 'translators: %s: a name'
check "--after Omega: placed after it" $([ "$RC" -eq 0 ] && [ "$(line_of '"Gamma %s"' lang/dom.pot)" -gt "$(line_of '"Omega"' lang/dom.pot)" ]; echo $?)
check "--comment comes first, as #." $([ "$(entry '"Gamma %s"' lang/dom.pot | head -1)" = '#. translators: %s: a name' ]; echo $?)

# ---- 14. argument errors ----------------------------------------------------
echo "14. argument errors"
fixtures
run --msgid 'Gamma %s' "${PO[@]}"
check "--po without --msgstr: exit 2" $([ "$RC" -eq 2 ]; echo $?)
run --msgid 'Gamma %s' "${PO[@]}" --msgstr ''
check "empty --msgstr: exit 2" $([ "$RC" -eq 2 ]; echo $?)
run --msgid 'Gamma %s'
check "neither --pot nor --po: exit 2" $([ "$RC" -eq 2 ]; echo $?)
run --msgid 'Gamma %s' "${POT[@]}" --msgstr 'x'
check "--msgstr without --po: exit 2" $([ "$RC" -eq 2 ]; echo $?)

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
