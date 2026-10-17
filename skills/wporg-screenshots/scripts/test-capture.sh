#!/usr/bin/env bash
# Scenario tests for capture.sh and config.cjs: a throwaway repository, a fake `npx` (wp-env:
# install-path and `run tests-cli wp …`), a fake curl and a fake shooter. No wp-env, no browser,
# no network. Needs node. Usage: bash test-capture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CAPTURE="$HERE/capture.sh"
CONFIG="$HERE/config.cjs"
SHOOT="$HERE/shoot.cjs"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -z "${OUT:-}" ] || printf '%s\n' "$OUT" | sed 's/^/         | /' | head -25; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
run()   { OUT="$("$CAPTURE" "$@" 2>&1)"; RC=$?; }
has()   { printf '%s\n' "$OUT" | grep -qE -- "$1"; }
calls() { cat "$W/calls.log" 2>/dev/null; }
called() { calls | grep -qE -- "$1"; }
# line number of the first call matching $1 (0 when none)
at()    { calls | grep -nE -- "$1" | head -1 | cut -d: -f1 | grep . || echo 0; }

# ---- fakes ---------------------------------------------------------------
mkdir -p "$W/bin" "$W/wpenv/tests-WordPress/wp-content/mu-plugins"
MU="$W/wpenv/tests-WordPress/wp-content/mu-plugins"
cat > "$W/bin/npx" <<'EOF'
#!/usr/bin/env bash
# fake npx: wp-env install-path and `wp-env run tests-cli wp …`
[ "$1" = wp-env ] || { echo "unexpected npx call: $*" >&2; exit 99; }
shift
case "$1" in
  install-path) echo "$FAKE_WPENV"; exit 0 ;;
  run) shift; [ "$1" = tests-cli ] || { echo "unexpected container: $1" >&2; exit 99; }; shift ;;
  *) echo "unexpected wp-env call: $*" >&2; exit 99 ;;
esac
[ "$1" = wp ] || { echo "unexpected command: $*" >&2; exit 99; }
shift
echo "ℹ Starting '$*' on the tests-cli container."
host_of() { printf '%s' "$FAKE_WPENV/tests-WordPress${1#/var/www/html}"; }
mu="$FAKE_WPENV/tests-WordPress/wp-content/mu-plugins"
case "$1" in
  eval)
    case "$2" in
      *WPMU_PLUGIN_DIR*) echo "eval WPMU_PLUGIN_DIR" >> "$CALLS"; echo /var/www/html/wp-content/mu-plugins ;;
      *wp_generate_auth_cookie*) echo "eval cookies" >> "$CALLS"; echo 'COOKIES=[{"name":"wordpress_x","value":"from-eval","path":"/"}]' ;;
      *) echo "eval other" >> "$CALLS" ;;
    esac
    ;;
  eval-file)
    file=$(host_of "$2"); base=$(basename "$2"); shift 2
    [ -f "$file" ] || { echo "eval-file: no such file $file" >&2; exit 1; }
    wrapper=no; [ -e "$mu/wporg-screenshots.php" ] && wrapper=yes
    denied=no; grep -qx 'Require all denied' "$mu/wporg-screenshots-hooks/.htaccess" 2>/dev/null && denied=yes
    echo "eval-file $base wrapper=$wrapper denied=$denied args=$*" >> "$CALLS"
    case "$base" in
      setup.php) printf '%b' "${FAKE_SETUP_OUT:-}"; exit "${FAKE_SETUP_RC:-0}" ;;
      teardown.php) echo "teardown: done"; exit "${FAKE_TEARDOWN_RC:-0}" ;;
    esac
    ;;
  *) echo "$*" >> "$CALLS" ;;
esac
echo "✔ Ran \`wp $*\` in 'tests-cli'."
EOF
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${FAKE_HTTP:-200}"
EOF
cat > "$W/shooter" <<'EOF'
#!/usr/bin/env bash
# fake shooter: same arguments as shoot.cjs; writes FAKE_SHOTS_N images (default: all)
url=$1 cookies=$2 shots=$3 vars=$4 out=$5
echo "shooter url=$url cookies=$(cat "$cookies") vars=$(cat "$vars")" >> "$CALLS"
[ -e "$FAKE_WPENV/tests-WordPress/wp-content/mu-plugins/wporg-screenshots.php" ] && echo "shooter saw the mu-plugin" >> "$CALLS"
n=${FAKE_SHOTS_N:-$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).shots.length" "$shots")}
i=0
while [ "$i" -lt "$n" ]; do i=$((i + 1)); printf 'new-%s\n' "$i" > "$out/screenshot-$i.${FAKE_EXT:-png}"; done
exit "${FAKE_SHOOT_RC:-0}"
EOF
chmod +x "$W/bin/npx" "$W/bin/curl" "$W/shooter"
export PATH="$W/bin:$PATH" FAKE_WPENV="$W/wpenv" CALLS="$W/calls.log" WPORG_SHOTS_SHOOTER="$W/shooter"

# ---- fixture repository --------------------------------------------------
R="$W/repo"
mkdir -p "$R/plugins/my-plugin/.wordpress-org" "$R/.claude/wporg-screenshots"
cd "$R"
printf '{ "testsPort": 10011 }\n' > .wp-env.json
cat > plugins/my-plugin/readme.txt <<'EOF'
=== My Plugin ===
Stable tag: 1.0.0

== Screenshots ==

1. The settings screen.
2. The report.

== Changelog ==

= 1.0.0 =
* First.
EOF
printf 'old-1\n' > plugins/my-plugin/.wordpress-org/screenshot-1.png
C=".claude/wporg-screenshots"
write_config() {
	cat > "$C/shots.json" <<'EOF'
{
	"plugin_dir": "plugins/my-plugin",
	"build": [ "sh", "-c", "echo built > build.marker" ],
	"deactivate": [ "my-plugin-pro" ],
	"activate": [ "woocommerce", "my-plugin" ],
	"permalink": "/%postname%/",
	"setup_args": [ "category,tag", "two words" ],
	"local_storage": { "my_run": "{RUN_ID}" },
	"shots": [
		{ "path": "/wp-admin/admin.php?page=my-plugin#/settings", "wait_for": "Save" },
		{ "path": "/wp-admin/admin.php?page=my-plugin&run={RUN_ID}", "wait_for": "Report", "uncheck": [ "Stock" ] }
	]
}
EOF
}
write_config
printf '<?php // project mock\n' > "$C/mu-plugin.php"
printf '<?php // setup\n' > "$C/setup.php"
printf '<?php // teardown\n' > "$C/teardown.php"
export FAKE_SETUP_OUT='prepared the site\nRUN_ID=run-42\nCOOKIES=[{"name":"wordpress_x","value":"from-setup","path":"/"}]\n'
reset() { rm -f "$W/calls.log" build.marker; unset FAKE_SETUP_RC FAKE_TEARDOWN_RC FAKE_SHOOT_RC FAKE_SHOTS_N FAKE_EXT FAKE_HTTP; }
leftover() { [ -e "$MU/wporg-screenshots.php" ] || [ -e "$MU/wporg-screenshots-hooks" ]; }

# ---- config.cjs ------------------------------------------------------------
echo "== config.cjs"
OUT="$(node "$CONFIG" check "$C/shots.json" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && has '^PLUGIN_DIR=plugins/my-plugin$' && has '^FORMAT=png$' && has '^USER=1$' && has '^LOCALE=en_US$' && has '^SHOTS=2$' && has '^PERMALINK=/%postname%/$'; check "a valid config gives the shell view with defaults" $?
[ "$(printf '%s\n' "$OUT" | grep -c '^BUILD_ARG=')" -eq 3 ] && has '^SETUP_ARG=two words$' && has '^DEACTIVATE=my-plugin-pro$' && [ "$(printf '%s\n' "$OUT" | grep -c '^ACTIVATE=')" -eq 2 ]; check "lists repeat their key, one item per line" $?
cfg() { printf '%s\n' "$1" > "$W/c.json"; OUT="$(node "$CONFIG" check "$W/c.json" 2>&1)"; RC=$?; }
SHOT='"shots": [ { "path": "/wp-admin/", "wait_for": "Dashboard" } ]'
cfg "{ $SHOT, \"plugins_dir\": \"x\" }"
[ "$RC" -eq 2 ] && has 'unknown key "plugins_dir"'; check "an unknown key (a typo) is refused" $?
cfg "{ \"shots\": [ { \"path\": \"/x\", \"wait_for\": \"y\", \"tab\": \"z\" } ] }"
[ "$RC" -eq 2 ] && has 'unknown key "tab" in shots\[0\]'; check "an unknown key in a shot is refused" $?
cfg "{ $SHOT, \"plugin_dir\": \"../other\" }"
[ "$RC" -eq 2 ] && has 'inside the repository'; check "plugin_dir with .. is refused" $?
cfg "{ $SHOT, \"activate\": [ \"Bad Slug\" ] }"
[ "$RC" -eq 2 ] && has 'not a plugin slug'; check "a plugin that is not a slug is refused" $?
cfg '{ "shots": [] }'
[ "$RC" -eq 2 ] && has 'non-empty array'; check "no shots is refused" $?
cfg '{ "shots": [ { "path": "wp-admin/", "wait_for": "x" } ] }'
[ "$RC" -eq 2 ] && has 'must start with /'; check "a shot path without a leading / is refused" $?
cfg '{ "shots": [ { "path": "/wp-admin/", "wait_for": " " } ] }'
[ "$RC" -eq 2 ] && has 'wait_for must not be empty'; check "an empty wait_for is refused" $?
cfg "{ $SHOT, \"format\": \"webp\" }"
[ "$RC" -eq 2 ] && has 'png" or "jpg'; check "an unknown format is refused" $?
cfg "{ $SHOT, \"setup_args\": [ \"a\\nb\" ] }"
[ "$RC" -eq 2 ] && has 'single-line'; check "a value with a newline is refused" $?
cfg "{ $SHOT, \"locale\": \"English\" }"
[ "$RC" -eq 2 ] && has 'not a WordPress locale'; check "a locale that is not one is refused" $?
cfg "{ $SHOT, \"locale\": \"\" }"
[ "$RC" -eq 0 ] && has '^LOCALE=$'; check "an empty locale leaves the user's locale alone" $?
printf 'noise\nRUN_ID=run-42\nlower=x\nCOOKIES=[1]\nEMPTY=\n' > "$W/so"
node "$CONFIG" vars "$W/so" "$W/v.json"
[ "$(cat "$W/v.json")" = '{"RUN_ID":"run-42","EMPTY":""}' ]; check "vars: KEY=value lines in capitals, COOKIES excluded" $?

# ---- shoot.cjs (up to the browser) -----------------------------------------
echo "== shoot.cjs"
mkdir -p "$W/sout"
printf '[]' > "$W/ck.json"
printf '{}' > "$W/novars.json"
OUT="$(cd "$W" && node "$SHOOT" http://localhost:1 "$W/ck.json" "$R/$C/shots.json" "$W/novars.json" "$W/sout" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && has 'uses \{RUN_ID\}, but the setup hook did not print RUN_ID='; check "an unknown {KEY} in local_storage or a path fails before the browser" $?
OUT="$(cd "$W" && node "$SHOOT" http://localhost:1 "$W/ck.json" "$R/$C/shots.json" "$W/v.json" "$W/sout" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && has 'playwright is not installed under'; check "with every {KEY} known it goes on to resolve playwright from the project" $?

# ---- capture.sh shoot ------------------------------------------------------
echo "== shoot"
reset
run shoot
[ "$RC" -eq 0 ] && has 'screenshots in plugins/my-plugin/.wordpress-org'; check "shoot succeeds" $?
[ "$(cat plugins/my-plugin/.wordpress-org/screenshot-1.png)" = new-1 ] && [ "$(cat plugins/my-plugin/.wordpress-org/screenshot-2.png)" = new-2 ]; check "the images land in <plugin_dir>/.wordpress-org" $?
[ -f build.marker ]; check "the build command ran (argv, no shell of ours)" $?
! leftover; check "the wrapper mu-plugin and the hooks directory are removed" $?
d=$(at 'plugin deactivate my-plugin-pro'); a=$(at 'plugin activate woocommerce my-plugin'); p=$(at 'rewrite structure /%postname%/ --hard'); l=$(at 'user meta update 1 locale en_US'); s=$(at 'eval-file setup.php'); h=$(at '^shooter url'); t=$(at 'eval-file teardown.php')
[ "$d" -gt 0 ] && [ "$d" -lt "$a" ] && [ "$a" -lt "$p" ] && [ "$p" -lt "$l" ] && [ "$l" -lt "$s" ] && [ "$s" -lt "$h" ] && [ "$h" -lt "$t" ]; check "order: deactivate, activate, permalink, locale, setup, shoot, teardown" $?
called 'eval-file setup.php wrapper=yes denied=yes args=http://localhost:10011 category,tag two words$'; check "setup runs with the mu-plugin loaded, HTTP denied to the hooks, the tests URL and setup_args (one argument each)" $?
called 'eval-file teardown.php wrapper=yes denied=yes args=http://localhost:10011$'; check "teardown runs while the mu-plugin is still installed" $?
called 'shooter saw the mu-plugin'; check "the mu-plugin is installed while shooting" $?
called '^shooter url=http://localhost:10011 cookies=\[\{"name":"wordpress_x","value":"from-setup"' && ! called '^eval cookies'; check "the cookies the setup printed are used" $?
called 'vars=\{"RUN_ID":"run-42"\}'; check "the setup's KEY=value lines reach the shooter, without COOKIES" $?
has 'prepared the site' && has '^RUN_ID=run-42' && ! has 'from-setup'; check "the setup's output is shown without the cookies" $?
has 'screenshot-1\.png  The settings screen\.' && has 'screenshot-2\.png  The report\.'; check "each image is listed with its readme caption" $?

reset
run shoot --out "$W/trial"
[ "$RC" -eq 0 ] && [ "$(cat "$W/trial/screenshot-2.png")" = new-2 ] && [ "$(cat plugins/my-plugin/.wordpress-org/screenshot-2.png)" = new-2 ]; check "--out writes elsewhere" $?

reset
mv "$C/setup.php" "$W/setup.bak"
run shoot --out "$W/nosetup"
[ "$RC" -eq 0 ] && called '^eval cookies' && called 'vars=\{\}' && ! called 'eval-file setup.php'; check "without setup.php the log-in cookies are made by capture.sh" $?
mv "$W/setup.bak" "$C/setup.php"

reset
mv "$C/teardown.php" "$W/teardown.bak"
run shoot --out "$W/noteardown"
[ "$RC" -eq 0 ] && has 'WARNING: .*setup.php but no teardown.php' && ! leftover; check "setup.php without teardown.php warns, and still cleans up" $?
mv "$W/teardown.bak" "$C/teardown.php"

reset
mv "$C/mu-plugin.php" "$W/mu.bak"
run shoot --out "$W/nomu"
[ "$RC" -eq 0 ] && called 'eval-file setup.php wrapper=no' && ! leftover; check "without mu-plugin.php no wrapper is installed" $?
mv "$W/mu.bak" "$C/mu-plugin.php"

echo "== shoot: refusals and failures"
reset
printf '3. A third caption.\n' > "$W/cap"
cp plugins/my-plugin/readme.txt "$W/readme.bak"
awk 'NR == FNR { extra = $0; next } { print } /^2\. / { print extra }' "$W/cap" "$W/readme.bak" > plugins/my-plugin/readme.txt
run shoot
[ "$RC" -ne 0 ] && has 'has 2 shots but .* has 3 screenshot captions' && ! leftover && [ ! -s "$W/calls.log" ]; check "a caption count that differs is refused before anything is installed" $?
cp "$W/readme.bak" plugins/my-plugin/readme.txt

reset
printf 'keep-me\n' > plugins/my-plugin/.wordpress-org/screenshot-1.png
export FAKE_SETUP_RC=1
run shoot
[ "$RC" -ne 0 ] && has 'the setup hook failed' && called 'eval-file teardown.php wrapper=yes' && ! leftover && [ "$(cat plugins/my-plugin/.wordpress-org/screenshot-1.png)" = keep-me ]; check "a failing setup: teardown runs, everything is removed, the images stay" $?

reset
export FAKE_SHOOT_RC=1
run shoot
[ "$RC" -ne 0 ] && called 'eval-file teardown.php' && ! leftover && [ "$(cat plugins/my-plugin/.wordpress-org/screenshot-1.png)" = keep-me ]; check "a failing shooter: nothing is copied, teardown runs" $?

reset
export FAKE_SHOTS_N=1
run shoot
[ "$RC" -ne 0 ] && has 'did not write screenshot-2.png' && [ "$(cat plugins/my-plugin/.wordpress-org/screenshot-1.png)" = keep-me ] && ! leftover; check "a shooter that writes fewer images: nothing is copied" $?

reset
sed 's/echo built/exit 3; echo built/' "$C/shots.json" > "$W/s.json" && cp "$W/s.json" "$C/shots.json"
run shoot
[ "$RC" -ne 0 ] && has 'the build failed' && ! leftover && [ ! -s "$W/calls.log" ]; check "a failing build stops before anything is installed" $?
write_config

reset
export FAKE_HTTP=500
run shoot
[ "$RC" -ne 0 ] && has 'answered HTTP 500' && ! leftover; check "a tests site that answers 500 is refused" $?

reset
export FAKE_TEARDOWN_RC=1
run shoot
[ "$RC" -ne 0 ] && has 'teardown hook failed; keeping' && [ -f "$MU/wporg-screenshots.php" ] && [ -f "$MU/wporg-screenshots-hooks/teardown.php" ]; check "a failing teardown keeps the mu-plugin and the hooks" $?
run status
has '^installed: YES'; check "status reports what is left" $?
rm -f "$W/calls.log"
run shoot
[ "$RC" -ne 0 ] && has 'already installed' && grep -q 'managed by the wporg-screenshots skill' "$MU/wporg-screenshots.php" && [ ! -s "$W/calls.log" ]; check "shoot refuses while something is left, before it runs anything" $?
unset FAKE_TEARDOWN_RC
run cleanup
[ "$RC" -eq 0 ] && has '^clean$' && ! leftover && called 'eval-file teardown.php wrapper=yes'; check "cleanup runs the installed teardown, then removes everything" $?
run status
has '^installed: no$'; check "status after cleanup" $?
run cleanup
[ "$RC" -eq 0 ] && has '^clean$'; check "cleanup with nothing installed is a no-op" $?

reset
printf '<?php // somebody else\n' > "$MU/wporg-screenshots.php"
run cleanup
[ "$RC" -ne 0 ] && has 'not managed by this skill' && grep -q 'somebody else' "$MU/wporg-screenshots.php"; check "a file without the marker is neither overwritten nor removed" $?
rm "$MU/wporg-screenshots.php"
mkdir "$MU/wporg-screenshots-hooks" && printf 'x' > "$MU/wporg-screenshots-hooks/setup.php"
run cleanup
[ "$RC" -ne 0 ] && has 'not managed by this skill' && [ -f "$MU/wporg-screenshots-hooks/setup.php" ]; check "a hooks directory without the marker is not removed" $?
rm "$MU/wporg-screenshots-hooks/setup.php" && rmdir "$MU/wporg-screenshots-hooks"

echo "== shoot: leftovers in the output"
reset
printf 'x' > plugins/my-plugin/.wordpress-org/screenshot-3.png
printf 'x' > plugins/my-plugin/.wordpress-org/screenshot-1.jpg
run shoot
[ "$RC" -eq 0 ] && has 'WARNING: .*screenshot-3\.png is beyond the 2 shots' && has 'WARNING: .*screenshot-1\.jpg is in another format'; check "images beyond the shots or in another format are reported, not removed" $?
[ -f plugins/my-plugin/.wordpress-org/screenshot-3.png ]; check "and left in place" $?
rm plugins/my-plugin/.wordpress-org/screenshot-3.png plugins/my-plugin/.wordpress-org/screenshot-1.jpg

reset
node -e "const f='$C/shots.json', c=require('$R/'+f); c.format='jpg'; require('fs').writeFileSync(f, JSON.stringify(c))"
export FAKE_EXT=jpg
run shoot --out "$W/jpg"
[ "$RC" -eq 0 ] && [ -f "$W/jpg/screenshot-2.jpg" ] && has 'screenshot-2\.jpg  The report\.'; check "format jpg writes .jpg" $?
write_config

echo "== arguments"
reset
run shoot --config "$W/none"
[ "$RC" -ne 0 ] && has "no $W/none/shots.json"; check "a missing config is refused" $?
run status --out x
[ "$RC" -ne 0 ] && has '--out is for shoot'; check "--out only with shoot" $?
run frobnicate
[ "$RC" -eq 2 ]; check "an unknown command shows the usage" $?
( cd "$W" && "$CAPTURE" status >/dev/null 2>&1 ); RC=$?
[ "$RC" -ne 0 ]; check "outside a repository root (no .wp-env.json) it refuses" $?

echo ""
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
