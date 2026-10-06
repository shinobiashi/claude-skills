#!/usr/bin/env bash
#
# verify-ports.sh — prove a running wp-env answers on its ledger slot, and that nothing else does.
#
# Usage (from the repository root, with the environment running):
#   bash verify-ports.sh [--dev-only] [--root <dir>] [--ledger <file>]
#
# Checks, against the slot `ports.js get` reports for this repository:
#   - the running containers publish the slot's ports (WordPress, tests, phpMyAdmin when present)
#   - the sites answer on both 127.0.0.1 and localhost: the browser tries ::1 first, where a
#     WordPress Studio site can listen on the same number while wp-env still starts fine
#   - /wp-admin/ redirects to the same port, and siteurl matches it in both environments
#   - the REST API answers (WARN when only ?rest_route= works: plain permalinks)
#   - nothing but a container runtime listens on those ports
#
# --root / --ledger are passed through to ports.js. --dev-only skips the tests environment.
# Prints PASS / FAIL / WARN / INFO lines; exits 1 if anything FAILed, 2 on usage errors.
#
# Test seams: DEV_ENV_DOCKER, DEV_ENV_CURL and DEV_ENV_NPX name substitute commands, and
# DEV_ENV_LSOF_OUTPUT a file of `lsof -iTCP -sTCP:LISTEN` output (see test-verify-ports.sh).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ONLY=0
PORTS_ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--dev-only) DEV_ONLY=1 ;;
		--root | --ledger)
			if [ $# -lt 2 ]; then
				echo "verify-ports: $1 needs a value" >&2
				exit 2
			fi
			PORTS_ARGS+=("$1" "$2")
			shift
			;;
		-h | --help)
			sed -n '3,/^$/s/^# \{0,1\}//p' "$0"
			exit 0
			;;
		*)
			echo "verify-ports: unknown argument: $1 (see --help)" >&2
			exit 2
			;;
	esac
	shift
done

if [ ! -f .wp-env.json ]; then
	echo "verify-ports: .wp-env.json not found — run this from the repository root." >&2
	exit 2
fi

docker_() { "${DEV_ENV_DOCKER:-docker}" "$@"; }
curl_() { "${DEV_ENV_CURL:-curl}" "$@"; }
npx_() { "${DEV_ENV_NPX:-npx}" "$@"; }

FAILED=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }
warn() { echo "WARN  $*"; }
info() { echo "INFO  $*"; }
finish() {
	echo
	if [ "$FAILED" = "0" ]; then echo "RESULT: all checks passed"; else echo "RESULT: FAILED — see FAIL lines above"; fi
	exit "$FAILED"
}

# ---- the slot this repository owns
# (An empty array expands to nothing only from bash 4.4 on under `set -u`; macOS ships 3.2.)
LEDGER_JSON="$(node "$HERE/ports.js" get "$PWD" ${PORTS_ARGS[@]+"${PORTS_ARGS[@]}"} 2>&1)"
if [ $? -ne 0 ]; then
	fail "ledger: ${LEDGER_JSON#ports.js: }"
	finish
fi
read -r SLOT PORT TESTS_PORT PMA TESTS_PMA < <(node -e '
	const j = JSON.parse(process.argv[1]);
	console.log(String(j.slot).padStart(2, "0"), j.port, j.testsPort, j.phpmyadminPort, j.testsPhpmyadminPort);
' "$LEDGER_JSON")
info "ledger: slot $SLOT → dev $PORT / tests $TESTS_PORT / phpMyAdmin $PMA, $TESTS_PMA"

# ---- the containers of this repository's instance (~/.wp-env/<instance>)
# @wordpress/env 11.16.0 has no `install-path` command (it prints nothing and exits 0); there the
# path comes from `wp-env status --json`.
INSTALL_PATH="$(npx_ wp-env install-path </dev/null 2>/dev/null | tail -1)"
if [ -z "$INSTALL_PATH" ]; then
	INSTALL_PATH="$(npx_ wp-env status --json </dev/null 2>/dev/null | node -e '
		let out = "";
		process.stdin.on("data", (d) => (out += d)).on("end", () => {
			const line = out.split("\n").reverse().find((l) => l.trim().startsWith("{"));
			try { console.log(JSON.parse(line).installPath || ""); } catch (e) {}
		});
	')"
fi
HASH="$(basename "$INSTALL_PATH")"
published() { # service -> the host port published for the container's port 80, or nothing
	docker_ ps --filter "name=^${HASH}-$1-1\$" --format '{{.Ports}}' 2>/dev/null |
		sed -nE 's/^[^>]*:([0-9]+)->80\/tcp.*/\1/p' | head -1
}

DEV_PUB="$(published wordpress)"
if [ -z "$HASH" ] || [ -z "$DEV_PUB" ]; then
	fail "no running WordPress container for this repository (instance '${HASH:-?}') — start it with: npx wp-env start"
	finish
fi
info "instance: $HASH"

compare_pub() { # label service expected
	local got
	got="$(published "$2")"
	if [ -z "$got" ]; then
		return 1
	elif [ "$got" = "$3" ]; then
		pass "$1 container publishes $3"
	else
		fail "$1 container publishes $got, but slot $SLOT says $3 — migrate .wp-env.json (ports.js check) or restart wp-env"
	fi
}
compare_pub "development" wordpress "$PORT"
if [ "$DEV_ONLY" = "0" ]; then
	compare_pub "tests" tests-wordpress "$TESTS_PORT" || fail "tests: no running tests-wordpress container"
fi
PMA_PORTS=()
if compare_pub "phpMyAdmin (development)" phpmyadmin "$PMA"; then
	PMA_PORTS+=("$PMA")
	if [ "$DEV_ONLY" = "0" ]; then
		if compare_pub "phpMyAdmin (tests)" tests-phpmyadmin "$TESTS_PMA"; then
			PMA_PORTS+=("$TESTS_PMA")
		else
			fail "phpMyAdmin (tests): no container — set env.tests.phpmyadminPort, or both environments fight over $PMA"
		fi
	fi
else
	info "phpMyAdmin: not configured"
fi
CHECK_PORTS=("$PORT")
[ "$DEV_ONLY" = "0" ] && CHECK_PORTS+=("$TESTS_PORT")
CHECK_PORTS+=(${PMA_PORTS[@]+"${PMA_PORTS[@]}"})

# ---- HTTP, from both address families
code() { curl_ -s -o /dev/null --max-time 20 -w '%{http_code}' "$1" 2>/dev/null; }
redirect() { curl_ -s -o /dev/null --max-time 20 -w '%{redirect_url}' "$1" 2>/dev/null; }
http_ok() { # label url
	local c
	c="$(code "$2")"
	if [ "$c" = "200" ]; then pass "$1 → 200 ($2)"; else fail "$1 → ${c:-no response} ($2)"; fi
}
for host in 127.0.0.1 localhost; do
	http_ok "development: wp-login via $host" "http://$host:$PORT/wp-login.php"
	[ "$DEV_ONLY" = "0" ] && http_ok "tests: site via $host" "http://$host:$TESTS_PORT/"
done

# A Studio site answering on [::1] serves its own login page under another host name.
R="$(redirect "http://localhost:$PORT/wp-admin/")"
case "$R" in
	"http://localhost:$PORT/wp-login.php"*) pass "development: /wp-admin/ redirects to its own port" ;;
	*) fail "development: /wp-admin/ redirects to '${R:-nothing}' — another server may answer on localhost:$PORT (lsof -nP -iTCP:$PORT -sTCP:LISTEN)" ;;
esac

if [ "$(code "http://localhost:$PORT/wp-json/")" = "200" ]; then
	pass "development: REST API at /wp-json/"
elif [ "$(code "http://localhost:$PORT/?rest_route=/")" = "200" ]; then
	warn "development: REST answers only as ?rest_route= (plain permalinks) — URLs registered as /wp-json/… (OAuth callbacks) will not match; fix with: npx wp-env run cli wp rewrite structure '/%postname%/' --hard"
else
	fail "development: REST API does not answer (/wp-json/ nor ?rest_route=/)"
fi

for pma_port in ${PMA_PORTS[@]+"${PMA_PORTS[@]}"}; do
	http_ok "phpMyAdmin on $pma_port" "http://localhost:$pma_port/"
done

siteurl() { npx_ wp-env run "$1" wp option get siteurl </dev/null 2>/dev/null | tr -d '\r' | grep -E '^https?://' | tail -1; }
S="$(siteurl cli)"
[ "$S" = "http://localhost:$PORT" ] && pass "development: siteurl is $S" || fail "development: siteurl is '${S:-unreadable}', expected http://localhost:$PORT"
if [ "$DEV_ONLY" = "0" ]; then
	S="$(siteurl tests-cli)"
	[ "$S" = "http://localhost:$TESTS_PORT" ] && pass "tests: siteurl is $S" || fail "tests: siteurl is '${S:-unreadable}', expected http://localhost:$TESTS_PORT"
fi

# ---- who listens: only the container runtime may hold the slot's ports
# Plain lsof cuts command names at 9 characters (com.docker.backend -> com.docke): ask for the whole name.
if [ -n "${DEV_ENV_LSOF_OUTPUT:-}" ]; then
	LSOF_OUT="$(cat "$DEV_ENV_LSOF_OUTPUT")"
elif command -v lsof >/dev/null 2>&1; then
	LSOF_OUT="$(lsof +c 0 -nP -iTCP -sTCP:LISTEN 2>/dev/null || true)"
else
	LSOF_OUT=""
	warn "lsof is not available: listeners were NOT checked"
fi
if [ -n "$LSOF_OUT" ]; then
	for p in "${CHECK_PORTS[@]}"; do
		holders="$(printf '%s\n' "$LSOF_OUT" | awk -v p=":$p" 'NR > 1 && substr($(NF - 1), length($(NF - 1)) - length(p) + 1) == p { gsub(/\\x20/, " ", $1); print $1 }' | sort -u)"
		others="$(printf '%s\n' "$holders" | grep -viE 'docke|vpnkit|orbstack|colima|lima|podman|rancher|qemu' | grep -v '^$')"
		if [ -n "$others" ]; then
			fail "port $p is also held by: $(echo "$others" | tr '\n' ' ')"
		elif [ -z "$holders" ]; then
			warn "port $p: lsof shows no listener (another user's process is invisible to lsof)"
		else
			pass "port $p is held only by the container runtime ($(echo "$holders" | tr '\n' ' ' | sed 's/ $//'))"
		fi
	done
fi

finish
