#!/usr/bin/env bash
# Scenario tests for scan-pii.sh on throwaway files (no network, synthetic addresses only).
# Usage: bash test-scan-pii.sh [path/to/scan-pii.sh]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/scan-pii.sh}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
run() { OUT="$(bash "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }
hasnt() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then bad "$1 (unexpected: $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; else ok "$1"; fi }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }
# blob FILE TEXT...: write the texts separated by binary bytes, like rows in a database page.
blob() { local f="$1"; shift; : >"$f"; for t in "$@"; do printf '\001\002%s\000\003' "$t" >>"$f"; done; }

echo "scan-pii.sh"

# Clean database: allowlisted addresses, including the letter strings glues on --------------------
mkdir -p "$W/clean"
blob "$W/clean/.ht.sqlite" "customer12@example.com" "customer1@example.comz" "guest3@example.org" "admin@localhost.localdomain" "wordpress@site.test"
run "$W/clean"
status "clean database passes" 0
has "says OK" "OK: scanned 1 file(s)"

# A real-looking address fails, and only the domain is printed -------------------------------------
mkdir -p "$W/leak"
blob "$W/leak/.ht.sqlite" "customer12@example.com" "taro.sample@freemail.example-isp.net" "hanako@mail.provider-x.jp"
run "$W/leak/.ht.sqlite"
status "an address outside the allowlist fails" 1
has "reports the domain" "*@freemail.example-isp.net"
has "reports the other domain" "*@mail.provider-x.jp"
hasnt "never prints the local part" "taro.sample"
has "points to find-string.php" "find-string.php"

# The -wal sibling of a SQLite file is scanned too -------------------------------------------------
mkdir -p "$W/wal"
blob "$W/wal/.ht.sqlite" "customer1@example.com"
blob "$W/wal/.ht.sqlite-wal" "leftover@yahoo.example-isp.jp"
run "$W/wal/.ht.sqlite"
status "an address only in the -wal file fails" 1
has "names the -wal file" ".ht.sqlite-wal"

# --allow-domain: the domain and its subdomains pass, look-alikes do not ---------------------------
mkdir -p "$W/allow"
blob "$W/allow/.ht.sqlite" "info@shop.example.jp" "staff@mail.shop.example.jp"
run --allow-domain shop.example.jp "$W/allow"
status "an allowlisted store domain and its subdomain pass" 0
blob "$W/allow/.ht.sqlite" "info@shop.example.jp" "x@shop.example.jp.evil.example-isp.com"
run --allow-domain=shop.example.jp "$W/allow"
status "a look-alike domain that only starts with the allowlisted one fails" 1
has "reports the look-alike" "*@shop.example.jp.evil.example-isp.com"
blob "$W/allow/.ht.sqlite" "Info@SHOP.Example.JP"
run --allow-domain Shop.Example.jp "$W/allow"
status "domains compare case-insensitively" 0

# Exact addresses: a staff address passes without allowing its whole domain ----------------------
mkdir -p "$W/staff"
blob "$W/staff/.ht.sqlite" "owner.private@freemail.example-isp.com" "customer9@freemail.example-isp.com"
run --allow-address Owner.Private@freemail.example-isp.com "$W/staff"
status "a customer at the staff member's mail provider still fails" 1
has "the customer is reported once" "    1 *@freemail.example-isp.com"
blob "$W/staff/.ht.sqlite" "Qx7vKp2LmZowner.private@freemail.example-isp.com" "owner.private@freemail.example-isp.comV"
run --allow-address owner.private@freemail.example-isp.com "$W/staff"
status "an allowlisted address passes with neighbouring bytes glued before or after it" 0
blob "$W/staff/.ht.sqlite" "owner.private@freemail.example-isp.com.attacker.example"
run --allow-address owner.private@freemail.example-isp.com "$W/staff"
status "an allowlisted address followed by a dot and more labels is a different address" 1
printf '# staff and store\nowner.private@freemail.example-isp.com\nshop.example.jp  # store domain\n\n' >"$W/allow.txt"
blob "$W/staff/.ht.sqlite" "owner.private@freemail.example-isp.com" "info@shop.example.jp"
run --allow-file "$W/allow.txt" "$W/staff"
status "--allow-file reads addresses and domains (comments, blanks ignored)" 0
run --allow-file "$W/missing.txt" "$W/staff"
status "--allow-file with a missing file is a usage error" 2

# Generated documents and archives cannot be checked, so they fail ---------------------------------
mkdir -p "$W/uploads/wpo_wcpdf_abc/attachments/document-1" "$W/uploads/2026/09"
printf '%%PDF-1.4 receipt' >"$W/uploads/wpo_wcpdf_abc/attachments/document-1/receipt-1.pdf"
run "$W/uploads"
status "a generated receipt PDF fails" 1
has "explains the receipts" "generated document(s)"
rm -rf "$W/uploads/wpo_wcpdf_abc"
printf '%%PDF-1.4 catalog' >"$W/uploads/2026/09/catalog.pdf"
run "$W/uploads"
status "a directory with nothing scannable is a usage error, not a pass" 2
has "asks to check the path" "check the path"
blob "$W/uploads/2026/09/import.csv" "customer2@example.com"
run "$W/uploads"
status "an ordinary media PDF does not fail" 0
printf 'x' | gzip >"$W/uploads/backup.sql.gz"
run "$W/uploads"
status "a compressed archive fails" 1
has "names the archive" "backup.sql.gz"
rm -f "$W/uploads/backup.sql.gz"

# A SQL backup passed directly -------------------------------------------------------------------
printf "INSERT INTO wp_users VALUES (5,'x','x','x','someone@docomo.example.jp');\n" >"$W/before-pull.sql"
run "$W/before-pull.sql"
status "a SQL backup with an address fails" 1

# Phones are informational -----------------------------------------------------------------------
blob "$W/clean/.ht.sqlite" "customer12@example.com" "090-1234-5678" "000-0000-0000"
run --phones "$W/clean"
status "phones do not change the exit status" 0
has "phones are masked" "090-1234-****"
hasnt "the fake phone is not listed" "000-0000-****"

# Usage errors -----------------------------------------------------------------------------------
run
status "no path is a usage error" 2
run "$W/does-not-exist"
status "a missing path is a usage error" 2
run --nope "$W/clean"
status "an unknown option is a usage error" 2

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
