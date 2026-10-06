#!/usr/bin/env bash
# Scenario tests for verify-ports.sh with stubbed docker / curl / npx and fake lsof output
# (no Docker, no network). Usage: bash test-verify-ports.sh [path/to/verify-ports.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/verify-ports.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
expect_exit() { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (exit $2, want $3)"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi }
expect_has() { if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (missing: $2)"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi }
expect_not() { if printf '%s' "$OUT" | grep -qF -- "$2"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi }

ROOT="$W/dev"
STUB="$W/stub"
mkdir -p "$ROOT/alpha" "$ROOT/stranger" "$STUB/ports"
echo '{ "plugins": [ "." ] }' > "$ROOT/alpha/.wp-env.json"
echo '{ "plugins": [ "." ] }' > "$ROOT/stranger/.wp-env.json"
cat > "$W/ledger.json" <<'EOF'
{
	"repos": [
		{ "slot": 1, "repo": "alpha" }
	]
}
EOF

# ---- stubs: each reads its answers from files under $STUB
cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
# docker ps --filter name=^<instance>-<service>-1$ --format ...
# Containers exist only for the instance named in $STUB_DIR/instance (default: stubhash).
inst="$(cat "$STUB_DIR/instance" 2>/dev/null || echo stubhash)"
for a in "$@"; do
	case "$a" in name=*) svc="${a#name=^${inst}-}"; svc="${svc%-1\$}" ;; esac
done
[ -f "$STUB_DIR/ports/$svc" ] && cat "$STUB_DIR/ports/$svc"
exit 0
EOF
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
# Answers from $STUB_DIR/http: "<url> <code> <redirect>"; unknown URLs get no response (000).
fmt="" url=""
while [ $# -gt 0 ]; do
	case "$1" in -w) fmt="$2"; shift ;; http*) url="$1" ;; esac
	shift
done
line="$(awk -v u="$url" '$1 == u' "$STUB_DIR/http" | head -1)"
case "$fmt" in
	*http_code*) code="$(echo "$line" | awk '{print $2}')"; printf '%s' "${code:-000}" ;;
	*redirect_url*) echo "$line" | awk '{printf "%s", $3}' ;;
esac
EOF
cat > "$STUB/npx" <<'EOF'
#!/usr/bin/env bash
# npx wp-env install-path | npx wp-env status --json | npx wp-env run <cli|tests-cli> wp option get siteurl
# $STUB_DIR/install-path and $STUB_DIR/status hold what those two commands print. A missing file
# means no output, which is how @wordpress/env 11.16 answers install-path.
case "$2" in
	install-path) [ -f "$STUB_DIR/install-path" ] && cat "$STUB_DIR/install-path" ;;
	status) [ -f "$STUB_DIR/status" ] && cat "$STUB_DIR/status" ;;
	run) f="$STUB_DIR/siteurl-$3"; [ -f "$f" ] && { echo "ℹ Starting 'wp option get siteurl' on the $3 container."; cat "$f"; } ;;
esac
exit 0
EOF
chmod +x "$STUB/docker" "$STUB/curl" "$STUB/npx"

# ---- a healthy instance on slot 01 (10010-10013); scenarios change one thing at a time
healthy() {
	echo "/home/me/.wp-env/stubhash" > "$STUB/install-path"
	rm -f "$STUB/status" "$STUB/instance"
	printf '0.0.0.0:10010->80/tcp, [::]:10010->80/tcp\n' > "$STUB/ports/wordpress"
	printf '0.0.0.0:10011->80/tcp, [::]:10011->80/tcp\n' > "$STUB/ports/tests-wordpress"
	printf '0.0.0.0:10012->80/tcp, [::]:10012->80/tcp\n' > "$STUB/ports/phpmyadmin"
	printf '0.0.0.0:10013->80/tcp, [::]:10013->80/tcp\n' > "$STUB/ports/tests-phpmyadmin"
	cat > "$STUB/http" <<'EOF'
http://127.0.0.1:10010/wp-login.php 200
http://localhost:10010/wp-login.php 200
http://127.0.0.1:10011/ 200
http://localhost:10011/ 200
http://localhost:10010/wp-admin/ 302 http://localhost:10010/wp-login.php?redirect_to=x&reauth=1
http://localhost:10010/wp-json/ 200
http://localhost:10010/?rest_route=/ 200
http://localhost:10012/ 200
http://localhost:10013/ 200
EOF
	echo "http://localhost:10010" > "$STUB/siteurl-cli"
	echo "http://localhost:10011" > "$STUB/siteurl-tests-cli"
	cat > "$W/lsof.txt" <<'EOF'
COMMAND              PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
com.docker.backend 12345 me    100u  IPv6 0x1      0t0  TCP *:10010 (LISTEN)
com.docke          12345 me    101u  IPv6 0x2      0t0  TCP *:10011 (LISTEN)
com.docker.backend 12345 me    102u  IPv6 0x3      0t0  TCP *:10012 (LISTEN)
com.docker.backend 12345 me    103u  IPv6 0x4      0t0  TCP *:10013 (LISTEN)
Studio             23456 me     50u  IPv6 0x5      0t0  TCP [::1]:100100 (LISTEN)
EOF
}
run() { # [repo] [args...]
	local repo="${1:-alpha}"
	shift || true
	OUT="$(cd "$ROOT/$repo" && STUB_DIR="$STUB" DEV_ENV_DOCKER="$STUB/docker" DEV_ENV_CURL="$STUB/curl" DEV_ENV_NPX="$STUB/npx" \
		DEV_ENV_LSOF_OUTPUT="$W/lsof.txt" bash "$SCRIPT" --root "$ROOT" --ledger "$W/ledger.json" "$@" 2>&1)"
	RC=$?
}

echo "healthy"
healthy; run
expect_exit "all checks pass → exit 0" $RC 0
expect_has "names the slot" "INFO  ledger: slot 01 → dev 10010 / tests 10011"
expect_has "containers match the slot" "PASS  development container publishes 10010"
expect_has "phpMyAdmin tests container matches" "PASS  phpMyAdmin (tests) container publishes 10013"
expect_has "localhost reaches the site" "PASS  development: wp-login via localhost → 200"
expect_has "redirect stays on the port" "PASS  development: /wp-admin/ redirects to its own port"
expect_has "siteurl matches" "PASS  tests: siteurl is http://localhost:10011"
expect_has "truncated com.docke counts as the runtime" "PASS  port 10011 is held only by the container runtime (com.docke)"
expect_not "a listener on 100100 is not mistaken for 10010" "port 10010 is also held by"
expect_not "no FAIL lines" "FAIL  "

echo "failures"
healthy; printf '0.0.0.0:8895->80/tcp\n' > "$STUB/ports/wordpress"; run
expect_exit "container on the old port → exit 1" $RC 1
expect_has "names both ports" "development container publishes 8895, but slot 01 says 10010"

healthy
sed -i.bak 's#^http://localhost:10010/wp-admin/ .*#http://localhost:10010/wp-admin/ 302 http://woo-demo.wp.local/wp-login.php#' "$STUB/http"
printf 'Studio             23456 me     50u  IPv6 0x5      0t0  TCP [::1]:10010 (LISTEN)\n' >> "$W/lsof.txt"
run
expect_exit "Studio answering on [::1] → exit 1" $RC 1
expect_has "the foreign redirect is reported" "FAIL  development: /wp-admin/ redirects to 'http://woo-demo.wp.local/wp-login.php'"
expect_has "the foreign listener is named" "FAIL  port 10010 is also held by: Studio"

# The same hijack when lsof cannot see the other process (another user's): the redirect alone must fail.
healthy
sed -i.bak 's#^http://localhost:10010/wp-admin/ .*#http://localhost:10010/wp-admin/ 302 http://woo-demo.wp.local/wp-login.php#' "$STUB/http"
run
expect_exit "foreign redirect without lsof evidence → exit 1" $RC 1
expect_has "the redirect check fails on its own" "FAIL  development: /wp-admin/ redirects to"

healthy; echo "http://localhost:8895" > "$STUB/siteurl-cli"; run
expect_exit "stale siteurl → exit 1" $RC 1
expect_has "stale siteurl is shown" "development: siteurl is 'http://localhost:8895', expected http://localhost:10010"

healthy; grep -v '^http://localhost:10011/ ' "$STUB/http" > "$STUB/http.new" && mv "$STUB/http.new" "$STUB/http"; run
expect_exit "tests site down on localhost → exit 1" $RC 1
expect_has "no response is reported" "FAIL  tests: site via localhost → 000"

healthy; rm "$STUB/ports/tests-phpmyadmin"; run
expect_exit "phpMyAdmin only in development → exit 1" $RC 1
expect_has "explains the shared port" "set env.tests.phpmyadminPort"

healthy; rm "$STUB/ports/wordpress"; run
expect_exit "nothing running → exit 1" $RC 1
expect_has "says how to start" "start it with: npx wp-env start"
expect_not "stops before the HTTP checks" "wp-login via"

run stranger
expect_exit "repository not in the ledger → exit 1" $RC 1
expect_has "points at assign" "FAIL  ledger: stranger is not in the ledger"

echo "instance lookup"
# @wordpress/env 11.16: install-path prints nothing, status --json carries the path, and the
# instance is named wp-env-<directory>-<hash8>.
healthy; rm "$STUB/install-path"
echo "wp-env-alpha-1a2b3c4d" > "$STUB/instance"
printf '%s\n' '{"status":"running","runtime":"docker","installPath":"/home/me/.wp-env/wp-env-alpha-1a2b3c4d"}' > "$STUB/status"
run
expect_exit "status --json names the instance when install-path is silent → exit 0" $RC 0
expect_has "uses the instance from status --json" "INFO  instance: wp-env-alpha-1a2b3c4d"
expect_has "finds that instance's containers" "PASS  development container publishes 10010"

healthy; rm "$STUB/install-path"; run
expect_exit "neither command names the instance → exit 1" $RC 1
expect_has "reports the unknown instance" "instance '?'"

healthy; rm "$STUB/install-path"; echo "not json" > "$STUB/status"; run
expect_exit "unparseable status output → exit 1" $RC 1
expect_has "still says how to start" "start it with: npx wp-env start"

echo "warnings and options"
healthy; sed -i.bak 's#^http://localhost:10010/wp-json/ 200#http://localhost:10010/wp-json/ 404#' "$STUB/http"; run
expect_exit "plain permalinks only warn → exit 0" $RC 0
expect_has "suggests the permalink fix" "WARN  development: REST answers only as ?rest_route="

healthy; rm "$STUB/ports/phpmyadmin" "$STUB/ports/tests-phpmyadmin"; run
expect_exit "no phpMyAdmin is fine → exit 0" $RC 0
expect_has "reports phpMyAdmin as not configured" "INFO  phpMyAdmin: not configured"
expect_not "does not probe phpMyAdmin ports" "port 10012"

healthy; rm "$STUB/ports/tests-wordpress" "$STUB/ports/tests-phpmyadmin"; run alpha --dev-only
expect_exit "--dev-only ignores the tests environment → exit 0" $RC 0
expect_not "--dev-only skips tests checks" "tests:"
expect_has "--dev-only still checks phpMyAdmin (development)" "PASS  phpMyAdmin on 10012 → 200"

echo "usage"
OUT="$(cd "$W" && bash "$SCRIPT" 2>&1)"; RC=$?
expect_exit "outside a repository → exit 2" $RC 2
OUT="$(cd "$ROOT/alpha" && bash "$SCRIPT" --frob 2>&1)"; RC=$?
expect_exit "unknown argument → exit 2" $RC 2
OUT="$(bash "$SCRIPT" --help 2>&1)"; RC=$?
expect_exit "--help → exit 0" $RC 0
expect_has "--help prints the header" "prove a running wp-env answers on its ledger slot"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
