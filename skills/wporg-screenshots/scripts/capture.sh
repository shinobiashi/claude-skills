#!/usr/bin/env bash
# capture.sh — take a plugin's wordpress.org screenshots on the wp-env tests site. See ../SKILL.md.
#
# Run from the repository root (where .wp-env.json is):
#   capture.sh shoot   [--config DIR] [--out DIR]   take the screenshots (default out: <plugin_dir>/.wordpress-org)
#   capture.sh status  [--config DIR]               is anything of this skill left on the tests site?
#   capture.sh cleanup [--config DIR]               run the installed teardown hook, then remove what this skill installed
#
# --config is the project's directory with shots.json and the optional hooks setup.php,
# teardown.php and mu-plugin.php (default: .claude/wporg-screenshots).
#
# The hooks are copied into <tests site>/wp-content/mu-plugins/wporg-screenshots-hooks/ (a
# subdirectory: WordPress does not load it by itself; an .htaccess denies HTTP) and run with
# `wp eval-file`, so they work whatever wp-env mounts. mu-plugin.php is loaded through a wrapper
# mu-plugin that carries this skill's marker. Nothing is written to the dev site.
#
# Environment: WPORG_SHOTS_CHANNEL= (empty) uses Playwright's Chromium instead of Google Chrome.
# WPORG_SHOTS_SHOOTER replaces `node shoot.cjs` (the scenario tests use it).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
WRAPPER_NAME="wporg-screenshots.php"
HOOKS_NAME="wporg-screenshots-hooks"
MARKER="wporg-screenshots: managed by the wporg-screenshots skill"
HOOK_MARKER_FILE=".wporg-screenshots-managed"
HOOK_FILES="mu-plugin.php setup.php teardown.php"

die() { echo "capture: $*" >&2; exit 1; }
usage() { sed -n '3,8p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 2; }

[ -f .wp-env.json ] || die "run this from the repository root (no .wp-env.json here)"

# `wp-env install-path` is this repository's instance (~/.wp-env/<hash>). Fail when it is empty or
# has no tests site: an empty value joined to a path would point at the host's root.
tests_mu_dir() {
	local p
	p=$(npx wp-env install-path 2>/dev/null) || { echo "npx wp-env install-path failed (is wp-env started for this repository?)" >&2; return 1; }
	p=${p%$'\n'}
	if [ -z "$p" ] || [ ! -d "$p/tests-WordPress" ]; then
		echo "wp-env install path is empty or has no tests-WordPress directory: '$p' (npx wp-env start)" >&2
		return 1
	fi
	printf '%s\n' "$p/tests-WordPress/wp-content/mu-plugins"
}

# The tests site, from testsPort of .wp-env.json (wp-env's default is 8889): never the dev site.
tests_url() {
	local port
	port=$(node -p "const c = require('./.wp-env.json'); c.testsPort === undefined ? 8889 : c.testsPort") || return 1
	case "$port" in ''|*[!0-9]*) echo "testsPort in .wp-env.json is not a number: '$port'" >&2; return 1 ;; esac
	printf 'http://localhost:%s\n' "$((10#$port))"
}

# WP-CLI on the tests site. A failure is shown and returned, never swallowed.
twp() {
	local out rc
	if out=$(npx wp-env run tests-cli wp "$@" 2>&1 </dev/null); then rc=0; else rc=$?; fi
	printf '%s\n' "$out" | grep -v '^ℹ\|^✔\|^$' || true
	return "$rc"
}

# Like twp, without echoing (for values the caller parses or that must not be printed).
twp_quiet() {
	npx wp-env run tests-cli wp "$@" 2>/dev/null </dev/null | grep -v '^ℹ\|^✔\|^$'
}

# The mu-plugins directory as the tests-cli container sees it.
container_mu_dir() {
	local d
	d=$(twp_quiet eval 'echo WPMU_PLUGIN_DIR;') || { echo "could not ask the tests site for WPMU_PLUGIN_DIR" >&2; return 1; }
	case "$d" in /*) ;; *) echo "unexpected WPMU_PLUGIN_DIR from the tests site: '$d'" >&2; return 1 ;; esac
	printf '%s\n' "$d"
}

installed() { # $1 = host mu-plugins dir
	[ -e "$1/$WRAPPER_NAME" ] || [ -e "$1/$HOOKS_NAME" ]
}

# Remove only what carries this skill's marker; refuse anything else. Called as `f || …`, where
# set -e does not apply inside the function, so every failure is returned explicitly.
remove_installed() { # $1 = host mu-plugins dir
	local dir=$1 hooks="$1/$HOOKS_NAME" f
	if [ -e "$dir/$WRAPPER_NAME" ]; then
		grep -q "$MARKER" "$dir/$WRAPPER_NAME" || { echo "not removing $dir/$WRAPPER_NAME (not managed by this skill)" >&2; return 1; }
		rm "$dir/$WRAPPER_NAME" || return 1
		[ ! -e "$dir/$WRAPPER_NAME" ] || { echo "could not remove $dir/$WRAPPER_NAME" >&2; return 1; }
		echo "removed $dir/$WRAPPER_NAME"
	fi
	if [ -e "$hooks" ]; then
		[ -f "$hooks/$HOOK_MARKER_FILE" ] || { echo "not removing $hooks (not managed by this skill)" >&2; return 1; }
		for f in $HOOK_FILES .htaccess "$HOOK_MARKER_FILE"; do
			[ ! -e "$hooks/$f" ] || rm "$hooks/$f" || return 1
		done
		rmdir "$hooks" || { echo "could not remove $hooks (unexpected files left in it?)" >&2; return 1; }
		echo "removed $hooks/"
	fi
}

# Run the installed teardown hook while the mu-plugin (the project's mock of external APIs) is
# still there, then remove everything. Removing the mock first would let what the setup left
# (queued jobs, a fake token) reach a real API from the admin screens or WP-Cron. When the
# teardown fails, everything stays and the failure is returned.
teardown_and_remove() { # $1 = host mu-plugins dir, $2 = tests site URL
	local dir=$1 url=$2 cdir
	if [ -f "$dir/$HOOKS_NAME/teardown.php" ]; then
		cdir=$(container_mu_dir) || { echo "capture: cannot run the teardown; keeping $dir/$HOOKS_NAME (run: $SELF cleanup)" >&2; return 1; }
		if ! twp eval-file "$cdir/$HOOKS_NAME/teardown.php" "$url"; then
			echo "capture: the teardown hook failed; keeping the mu-plugin and the hooks so that nothing reaches a real API: $dir (fix the cause, then run: $SELF cleanup)" >&2
			return 1
		fi
	fi
	remove_installed "$dir" || { echo "capture: something of this skill may still be installed in $dir (run: $SELF cleanup)" >&2; return 1; }
}

readme_captions() { # $1 = readme.txt
	awk '/^== Screenshots ==/ { f = 1; next } /^== / { f = 0 } f && /^[0-9]+\. / { print }' "$1"
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift
config_dir=".claude/wporg-screenshots"
out=""
while [ $# -gt 0 ]; do
	case "$1" in
		--config) [ $# -ge 2 ] || die "--config needs a directory"; config_dir=$2; shift 2 ;;
		--config=*) config_dir=${1#--config=}; shift ;;
		--out) [ "$cmd" = shoot ] || die "--out is for shoot"; [ $# -ge 2 ] || die "--out needs a directory"; out=$2; shift 2 ;;
		--out=*) [ "$cmd" = shoot ] || die "--out is for shoot"; out=${1#--out=}; shift ;;
		*) die "unknown option: $1" ;;
	esac
done

case "$cmd" in
	status)
		url=$(tests_url) || exit 1
		dir=$(tests_mu_dir) || exit 1
		echo "tests site: $url"
		if installed "$dir"; then
			echo "installed: YES ($dir/$WRAPPER_NAME, $dir/$HOOKS_NAME/). Run: $SELF cleanup"
		else
			echo "installed: no"
		fi
		;;

	cleanup)
		url=$(tests_url) || exit 1
		dir=$(tests_mu_dir) || exit 1
		teardown_and_remove "$dir" "$url" || exit 1
		! installed "$dir" || die "something of this skill is still in $dir"
		echo "clean"
		;;

	shoot)
		shots="$config_dir/shots.json"
		[ -f "$shots" ] || die "no $shots (see the skill's 'Set up a plugin' section)"
		if view=$(node "$HERE/config.cjs" check "$shots"); then :; else exit 1; fi
		plugin_dir="" format="" user="" locale="" permalink="" shots_count=""
		build=() deactivate=() activate=() setup_args=()
		while IFS= read -r kv; do
			case "$kv" in
				PLUGIN_DIR=*) plugin_dir=${kv#*=} ;;
				FORMAT=*) format=${kv#*=} ;;
				USER=*) user=${kv#*=} ;;
				LOCALE=*) locale=${kv#*=} ;;
				PERMALINK=*) permalink=${kv#*=} ;;
				SHOTS=*) shots_count=${kv#*=} ;;
				BUILD_ARG=*) build+=("${kv#*=}") ;;
				DEACTIVATE=*) deactivate+=("${kv#*=}") ;;
				ACTIVATE=*) activate+=("${kv#*=}") ;;
				SETUP_ARG=*) setup_args+=("${kv#*=}") ;;
				*) die "unexpected line from config.cjs: $kv" ;;
			esac
		done <<EOF
$view
EOF
		[ -n "$plugin_dir" ] && [ -n "$format" ] && [ -n "$user" ] && [ -n "$shots_count" ] || die "config.cjs did not report every value"
		readme="$plugin_dir/readme.txt"
		[ -f "$readme" ] || die "no $readme (plugin_dir in $shots)"
		[ -n "$out" ] || out="$plugin_dir/.wordpress-org"

		# The number of shots must equal the readme's screenshot captions: the directory pairs
		# caption N with screenshot-N, so a missing or extra image shows the wrong caption.
		captions=$(readme_captions "$readme")
		captions_count=$(printf '%s\n' "$captions" | grep -c . || true)
		[ "$shots_count" = "$captions_count" ] || die "$shots has $shots_count shots but $readme has $captions_count screenshot captions. Make them match first."

		has_setup=0; [ ! -f "$config_dir/setup.php" ] || has_setup=1
		if [ "$has_setup" = 1 ] && [ ! -f "$config_dir/teardown.php" ]; then
			echo "capture: WARNING: $config_dir has setup.php but no teardown.php; whatever the setup leaves stays on the tests site" >&2
		fi

		if [ -z "${WPORG_SHOTS_SHOOTER:-}" ]; then
			node -e "require.resolve('playwright', { paths: [ process.cwd() ] })" 2>/dev/null \
				|| die "playwright is not installed under ./node_modules (@wordpress/scripts brings it; or npm install --save-dev playwright)"
		fi
		if [ ${#build[@]} -gt 0 ]; then
			# The admin screens read the build: an old build shows the screen before the change.
			if build_out=$("${build[@]}" 2>&1); then :; else
				printf '%s\n' "$build_out" | tail -n 20 >&2
				die "the build failed: ${build[*]}"
			fi
			echo "built: ${build[*]}"
		fi

		url=$(tests_url) || exit 1
		code=$(curl -s -o /dev/null -w '%{http_code}' "$url/") || die "the tests site $url is not reachable (npx wp-env start)"
		case "$code" in 2??|3??) ;; *) die "the tests site $url answered HTTP $code (npx wp-env start)" ;; esac

		dir=$(tests_mu_dir) || exit 1
		if installed "$dir"; then
			die "something of this skill is already installed in $dir (a run that was killed?). Run: $SELF cleanup"
		fi
		mkdir -p "$out"
		if ! TMP=$(mktemp -d) || [ -z "$TMP" ]; then die "mktemp failed"; fi

		# Whatever happens, run the teardown and remove the hooks, the mu-plugin and the cookies.
		# DONE proves the run reached its end: with set -e and an EXIT trap, macOS bash 3.2 can
		# exit 0 after an error. set -e also applies inside the trap, so each cleanup step records
		# its failure in rc and the next one still runs.
		DONE=0
		INSTALLED=0
		finish() {
			local rc=$?
			if [ "$INSTALLED" = 1 ]; then
				teardown_and_remove "$dir" "$url" || rc=1
			fi
			rm -rf "$TMP" || rc=1
			if [ "$DONE" != 1 ] && [ "$rc" = 0 ]; then
				echo "capture: stopped before the end" >&2
				rc=1
			fi
			exit "$rc"
		}
		trap finish EXIT
		trap 'exit 130' INT TERM

		INSTALLED=1
		mkdir -p "$dir/$HOOKS_NAME"
		: > "$dir/$HOOKS_NAME/$HOOK_MARKER_FILE"
		printf 'Require all denied\n' > "$dir/$HOOKS_NAME/.htaccess"
		for f in $HOOK_FILES; do
			[ ! -f "$config_dir/$f" ] || cp "$config_dir/$f" "$dir/$HOOKS_NAME/$f"
		done
		if [ -f "$config_dir/mu-plugin.php" ]; then
			cat > "$dir/$WRAPPER_NAME" <<PHP
<?php
/**
 * $MARKER
 *
 * TEMPORARY. Loads the project's screenshot mu-plugin while capture.sh takes the wordpress.org
 * screenshots on the tests site; capture.sh removes it afterwards. Never commit it.
 */
require __DIR__ . '/$HOOKS_NAME/mu-plugin.php';
PHP
			echo "installed $dir/$WRAPPER_NAME"
		fi
		echo "installed $dir/$HOOKS_NAME/"
		cdir=$(container_mu_dir) || exit 1

		if [ ${#deactivate[@]} -gt 0 ]; then twp plugin deactivate "${deactivate[@]}"; fi
		if [ ${#activate[@]} -gt 0 ]; then twp plugin activate "${activate[@]}"; fi
		if [ -n "$permalink" ]; then twp rewrite structure "$permalink" --hard; fi
		if [ -n "$locale" ]; then twp user meta update "$user" locale "$locale"; fi

		: > "$TMP/setup.out"
		if [ "$has_setup" = 1 ]; then
			if setup_out=$(npx wp-env run tests-cli wp eval-file "$cdir/$HOOKS_NAME/setup.php" "$url" ${setup_args[@]+"${setup_args[@]}"} 2>&1 </dev/null); then rc=0; else rc=$?; fi
			printf '%s\n' "$setup_out" | grep -v '^ℹ\|^✔\|^$\|^COOKIES=' || true
			[ "$rc" = 0 ] || die "the setup hook failed (exit $rc)"
			printf '%s\n' "$setup_out" > "$TMP/setup.out"
		fi
		node "$HERE/config.cjs" vars "$TMP/setup.out" "$TMP/vars.json"
		sed -n 's/^COOKIES=//p' "$TMP/setup.out" > "$TMP/cookies.json"
		if [ ! -s "$TMP/cookies.json" ]; then
			# Log-in cookies of the configured user for an hour (a setup hook may print its own COOKIES=).
			cookie_php="if ( ! get_userdata( $user ) ) { fwrite( STDERR, 'no user $user' ); exit( 1 ); } \$e = time() + HOUR_IN_SECONDS; echo 'COOKIES=' . wp_json_encode( [ [ 'name' => AUTH_COOKIE, 'value' => wp_generate_auth_cookie( $user, \$e, 'auth' ), 'path' => ADMIN_COOKIE_PATH ], [ 'name' => LOGGED_IN_COOKIE, 'value' => wp_generate_auth_cookie( $user, \$e, 'logged_in' ), 'path' => COOKIEPATH ] ] ) . PHP_EOL;"
			if cookie_out=$(twp_quiet eval "$cookie_php"); then :; else die "could not make log-in cookies for user $user on the tests site"; fi
			printf '%s\n' "$cookie_out" | sed -n 's/^COOKIES=//p' > "$TMP/cookies.json"
		fi
		[ -s "$TMP/cookies.json" ] || die "no log-in cookies"

		# Take everything into a temporary directory first, so a failed run never mixes new and old images.
		mkdir "$TMP/shots"
		if [ -n "${WPORG_SHOTS_SHOOTER:-}" ]; then
			"$WPORG_SHOTS_SHOOTER" "$url" "$TMP/cookies.json" "$shots" "$TMP/vars.json" "$TMP/shots"
		else
			node "$HERE/shoot.cjs" "$url" "$TMP/cookies.json" "$shots" "$TMP/vars.json" "$TMP/shots"
		fi
		n=0
		while [ "$n" -lt "$shots_count" ]; do
			n=$((n + 1))
			[ -s "$TMP/shots/screenshot-$n.$format" ] || die "the shooter did not write screenshot-$n.$format"
		done
		cp "$TMP"/shots/screenshot-*."$format" "$out"/

		# Images left over from more shots, or in another format, are reported (a person decides
		# whether to delete them).
		for f in "$out"/screenshot-*.*; do
			[ -e "$f" ] || continue
			base=${f##*/screenshot-}
			num=${base%%.*}
			ext=${base#*.}
			case "$num" in ''|*[!0-9]*) continue ;; esac
			if [ "$((10#$num))" -gt "$shots_count" ]; then
				echo "capture: WARNING: $f is beyond the $shots_count shots (remove it if the readme no longer has that caption)" >&2
			elif [ "$ext" != "$format" ]; then
				echo "capture: WARNING: $f is in another format than this run's .$format (wordpress.org may show either; remove the stale one)" >&2
			fi
		done

		echo
		echo "screenshots in $out (check each against its readme caption):"
		printf '%s\n' "$captions" | awk -v ext="$format" '{ sub(/^[0-9]+\. /, ""); printf "  screenshot-%d.%s  %s\n", NR, ext, $0 }'
		DONE=1
		;;

	*)
		usage
		;;
esac
