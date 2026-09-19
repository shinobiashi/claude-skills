#!/usr/bin/env bash
#
# verify-env.sh — prove a wp-env is actually usable, not merely "started".
#
# Usage (from the repository root, with the environment running):
#   bash verify-env.sh            # development + tests
#   bash verify-env.sh --dev-only # skip the tests environment
#
# Prints one PASS/FAIL/INFO line per check and exits 1 if anything FAILed.
# `wp-env start` exiting 0 only means the containers are up: a plugin that fatals on
# load, or one that silently failed to activate, still leaves wp-env reporting success.

set -uo pipefail

DEV_ONLY=0
[ "${1:-}" = "--dev-only" ] && DEV_ONLY=1

if [ ! -f .wp-env.json ]; then
	echo "FAIL  .wp-env.json not found — run this from the repository root." >&2
	exit 1
fi

SLUG="$(basename "$PWD")"
FAILED=0
DEV_HPOS=""
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }
warn() { echo "WARN  $*"; }
info() { echo "INFO  $*"; }

# .wp-env.override.json wins over .wp-env.json, and an unset web port means wp-env's default.
read -r PORT TESTS_PORT PMA_PORT TESTS_PMA_PORT < <(node -e '
	const fs = require("fs");
	const load = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { return {}; } };
	const base = load(".wp-env.json"), over = load(".wp-env.override.json");
	const pick = (...vals) => vals.find((v) => Number.isInteger(v));
	const env = (c, name) => (c.env && c.env[name]) || {};
	const port = pick(env(over,"development").port, over.port, env(base,"development").port, base.port, 8888);
	const tests = pick(env(over,"tests").port, over.testsPort, env(base,"tests").port, base.testsPort, 8889);
	const pma = pick(env(over,"development").phpmyadminPort, over.phpmyadminPort, env(base,"development").phpmyadminPort, base.phpmyadminPort) ?? "-";
	const tpma = pick(env(over,"tests").phpmyadminPort, env(base,"tests").phpmyadminPort) ?? "-";
	console.log(port, tests, pma, tpma);
')

http_check() { # label url
	local code
	code="$(curl -s -o /dev/null -L --max-time 20 -w '%{http_code}' "$2" || true)"
	if [ "$code" = "200" ]; then pass "$1 → HTTP 200 ($2)"; else fail "$1 → HTTP ${code:-no response} ($2)"; fi
}

# One `wp-env run` per environment: each call costs a docker exec round trip.
# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` would print "0" twice.
container_report() { # container
	npx wp-env run "$1" bash -c '
		echo "WP=$(wp core version)"
		echo "PHP=$(php -r "echo PHP_VERSION;")"
		echo "WC=$(wp plugin get woocommerce --field=version 2>/dev/null || echo MISSING)"
		echo "WC_ACTIVE=$(wp plugin is-active woocommerce && echo yes || echo no)"
		echo "SELF_ACTIVE=$(wp plugin is-active '"$SLUG"' && echo yes || echo no)"
		echo "HPOS=$(wp option get woocommerce_custom_orders_table_enabled 2>/dev/null || echo unset)"
		echo "CURRENCY=$(wp option get woocommerce_currency 2>/dev/null || echo unset)"
		echo "PRODUCTS=$(wp post list --post_type=product --format=count 2>/dev/null || echo 0)"
		if [ -f wp-content/debug.log ]; then echo "FATALS=$(grep -c "PHP Fatal" wp-content/debug.log || true)"; else echo "FATALS=0"; fi
		echo "INACTIVE=$(wp plugin list --status=inactive --field=name 2>/dev/null | grep -v -x -e hello -e akismet | tr "\n" " ")"
	' 2>/dev/null | tr -d '\r'
}

value() { echo "$REPORT" | sed -n "s/^$1=//p" | head -1; }

check_container() { # label container expect_provisioned(0|1)
	local label="$1"
	REPORT="$(container_report "$2")"
	if [ -z "$REPORT" ]; then
		fail "$label: no response from the $2 container (is the environment running?)"
		return
	fi
	info "$label: WordPress $(value WP) / PHP $(value PHP) / WooCommerce $(value WC) / HPOS=$(value HPOS)"
	[ "$(value WC_ACTIVE)" = "yes" ] && pass "$label: WooCommerce is active" || fail "$label: WooCommerce is NOT active"
	[ "$(value SELF_ACTIVE)" = "yes" ] && pass "$label: plugin '$SLUG' is active" || fail "$label: plugin '$SLUG' is NOT active (fatal on load, or an unmet 'Requires Plugins' dependency?)"
	[ "$(value FATALS)" = "0" ] && pass "$label: no PHP Fatal in wp-content/debug.log" || fail "$label: $(value FATALS) PHP Fatal line(s) in wp-content/debug.log"
	if [ -n "$(value INACTIVE)" ]; then
		fail "$label: bundled plugin(s) left inactive: $(value INACTIVE)"
	fi
	if [ "$3" = "1" ]; then
		[ "$(value CURRENCY)" = "JPY" ] && pass "$label: provisioning applied (currency JPY, $(value PRODUCTS) product(s))" || fail "$label: provisioning did not run (currency=$(value CURRENCY)) — check lifecycleScripts.afterStart output"
	fi
	# Order storage decides which data store every order query exercises. When the two
	# environments differ, integration tests cover a storage the developer never looks at.
	if [ "$2" = "cli" ]; then
		DEV_HPOS="$(value HPOS)"
		# wp-env hides afterStart output when it succeeds, so a provisioning script that
		# could not enable HPOS is invisible at start time. This is where it surfaces.
		if [ "$DEV_HPOS" != "yes" ]; then
			warn "$label: HPOS is '$DEV_HPOS' but newly installed WooCommerce stores use HPOS — run: npx wp-env run cli wp wc hpos compatibility-info"
		fi
	elif [ -n "$DEV_HPOS" ] && [ "$DEV_HPOS" != "$(value HPOS)" ]; then
		warn "HPOS differs: development=$DEV_HPOS, tests=$(value HPOS) — tests run against a different order storage than the one you develop on"
	fi
}

HAS_SETUP=0
grep -q '"afterStart"' .wp-env.json && HAS_SETUP=1

echo "== development (http://localhost:${PORT}) =="
http_check "site" "http://localhost:${PORT}/"
http_check "wp-login" "http://localhost:${PORT}/wp-login.php"
[ "$PMA_PORT" != "-" ] && http_check "phpMyAdmin" "http://localhost:${PMA_PORT}/"
check_container "development" cli "$HAS_SETUP"

if [ "$DEV_ONLY" = "0" ]; then
	echo "== tests (http://localhost:${TESTS_PORT}) =="
	http_check "site" "http://localhost:${TESTS_PORT}/"
	[ "$TESTS_PMA_PORT" != "-" ] && http_check "phpMyAdmin" "http://localhost:${TESTS_PMA_PORT}/"
	check_container "tests" tests-cli 0
fi

echo
if [ "$FAILED" = "0" ]; then echo "RESULT: all checks passed"; else echo "RESULT: FAILED — see FAIL lines above"; fi
exit "$FAILED"
