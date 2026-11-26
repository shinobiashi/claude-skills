#!/usr/bin/env bash
# scan-pii.sh — Gate for a local copy of production: fail if personal data is still on disk.
#
# Usage:
#   scan-pii.sh [--allow-domain DOMAIN]... [--allow-address ADDRESS]... [--allow-file FILE] [--phones] PATH...
#
# PATH can be a file (a SQLite database, a .sql backup, a log) or a directory. For a SQLite
# file its -wal / -shm siblings are scanned too. For a directory, database files, SQL dumps,
# logs, CSV/JSON/text files are scanned, and generated receipts/invoices (PDFs under
# wpo_wcpdf_*) and compressed archives are reported because they cannot be checked here.
#
# An email address passes when its domain is allowlisted (example.com/.org/.net, localhost,
# localdomain, invalid, test, plus --allow-domain), a subdomain of one, or one followed by
# letters that `strings` glued on from the next bytes (example.comz). --allow-address passes one
# address (staff, store sender) without allowing its whole domain — it also passes with bytes of
# the neighbouring columns glued on before or after it; --allow-file reads one
# entry per line (an entry with @ is an address, otherwise a domain; # starts a comment), such as
# the file pii-inventory.php write-allow= writes. Only domains are printed,
# never full addresses. --phones adds an informational count of phone-like numbers (masked);
# phones do not affect the exit status.
#
# Exit: 0 nothing found; 1 addresses outside the allowlist, generated documents or archives
# found; 2 usage error, missing path, or nothing scannable under the paths.
set -uo pipefail

ALLOW="example.com example.org example.net localhost localdomain invalid test"
ALLOW_ADDR=""
PHONES=0
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
PATHS=()

while [ $# -gt 0 ]; do
	case "$1" in
	--allow-domain)
		[ $# -ge 2 ] || { echo "scan-pii: --allow-domain needs a value" >&2; exit 2; }
		ALLOW="$ALLOW $(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
		shift 2
		;;
	--allow-domain=*)
		ALLOW="$ALLOW $(printf '%s' "${1#--allow-domain=}" | tr '[:upper:]' '[:lower:]')"
		shift
		;;
	--allow-address)
		[ $# -ge 2 ] || { echo "scan-pii: --allow-address needs a value" >&2; exit 2; }
		ALLOW_ADDR="$ALLOW_ADDR $(lower "$2")"
		shift 2
		;;
	--allow-file)
		[ $# -ge 2 ] && [ -f "$2" ] || { echo "scan-pii: --allow-file needs an existing file" >&2; exit 2; }
		while IFS= read -r entry || [ -n "$entry" ]; do
			entry="$(printf '%s' "${entry%%#*}" | tr -d '[:space:]')"
			[ -n "$entry" ] || continue
			case "$entry" in
			*@*) ALLOW_ADDR="$ALLOW_ADDR $(lower "$entry")" ;;
			*) ALLOW="$ALLOW $(lower "$entry")" ;;
			esac
		done <"$2"
		shift 2
		;;
	--phones) PHONES=1; shift ;;
	-h | --help) sed -n '2,20p' "$0"; exit 0 ;;
	--) shift; PATHS+=("$@"); break ;;
	-*) echo "scan-pii: unknown option $1" >&2; exit 2 ;;
	*) PATHS+=("$1"); shift ;;
	esac
done
[ ${#PATHS[@]} -gt 0 ] || { echo "scan-pii: give at least one PATH (see --help)" >&2; exit 2; }

FOUND=0
FILES=()
add_file() {
	FILES+=("$1")
	case "$1" in
	*.sqlite | *.sqlite3 | *.db)
		[ -f "$1-wal" ] && FILES+=("$1-wal")
		[ -f "$1-shm" ] && FILES+=("$1-shm")
		;;
	esac
}

for p in "${PATHS[@]}"; do
	if [ -f "$p" ]; then
		add_file "$p"
	elif [ -d "$p" ]; then
		while IFS= read -r f; do add_file "$f"; done < <(find "$p" -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' -o -name '*.sql' -o -name '*.log' -o -name '*.csv' -o -name '*.json' -o -name '*.txt' -o -name '*.htm' \) ! -name '*-wal' ! -name '*-shm' | sort)
		docs="$(find "$p" -type f -iname '*.pdf' -path '*wpo_wcpdf*' | wc -l | tr -d ' ')"
		if [ "$docs" -gt 0 ]; then
			echo "== $p: ${docs} generated document(s) (receipts/invoices under wpo_wcpdf_*) — they name customers; delete them"
			FOUND=1
		fi
		archives="$(find "$p" -type f \( -iname '*.gz' -o -iname '*.zip' -o -iname '*.tgz' -o -iname '*.tar' -o -iname '*.wpress' -o -iname '*.bz2' -o -iname '*.xz' \) | wc -l | tr -d ' ')"
		if [ "$archives" -gt 0 ]; then
			echo "== $p: ${archives} compressed archive(s) that this scan cannot read — extract and scan them, or delete them"
			find "$p" -type f \( -iname '*.gz' -o -iname '*.zip' -o -iname '*.tgz' -o -iname '*.tar' -o -iname '*.wpress' -o -iname '*.bz2' -o -iname '*.xz' \) | sed 's/^/   /' | head -10
			FOUND=1
		fi
	else
		echo "scan-pii: no such file or directory: $p" >&2
		exit 2
	fi
done

# Domains of addresses that are not allowlisted, one per line.
outside_domains() {
	LC_ALL=C strings -n 6 "$1" 2>/dev/null |
		LC_ALL=C grep -oiE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' |
		awk -v allow="$ALLOW" -v addrs="$ALLOW_ADDR" '
			BEGIN { n = split(allow, A, " "); m = split(addrs, B, " ") }
			{
				e = tolower($0); d = substr(e, index(e, "@") + 1); ok = 0
				# An allowlisted address may have bytes of the neighbouring columns glued on
				# before it (local part) or after it (letters after the TLD).
				for (j = 1; j <= m; j++) {
					pos = index(e, B[j])
					if (pos > 0) {
						c = substr(e, pos + length(B[j]), 1)
						if (c == "" || (c != "." && c != "-")) { ok = 1; break }
					}
				}
				if (ok) next
				for (i = 1; i <= n; i++) {
					a = A[i]
					if (d == a) { ok = 1; break }
					if (length(d) > length(a)) {
						if (substr(d, length(d) - length(a)) == "." a) { ok = 1; break }
						if (substr(d, 1, length(a)) == a) {
							c = substr(d, length(a) + 1, 1)
							if (c != "." && c != "-") { ok = 1; break }
						}
					}
				}
				if (!ok) print d
			}'
}

if [ ${#FILES[@]} -eq 0 ] && [ "$FOUND" -eq 0 ]; then
	echo "scan-pii: no database, SQL, log, CSV, JSON or text files under ${PATHS[*]} — check the path" >&2
	exit 2
fi

TOTAL=0
for f in ${FILES[@]+"${FILES[@]}"}; do
	domains="$(outside_domains "$f")"
	if [ -n "$domains" ]; then
		count="$(printf '%s\n' "$domains" | wc -l | tr -d ' ')"
		TOTAL=$((TOTAL + count))
		echo "== $f: ${count} address(es) outside the allowlist"
		printf '%s\n' "$domains" | sort | uniq -c | sort -rn | awk '{ printf "   %5d *@%s\n", $1, $2 }'
		FOUND=1
	fi
	if [ "$PHONES" -eq 1 ]; then
		LC_ALL=C strings -n 6 "$f" 2>/dev/null |
			LC_ALL=C grep -oE '0[0-9]{1,4}-[0-9]{1,4}-[0-9]{4}' |
			grep -v '^000-0000-0000$' |
			sed -E 's/[0-9]{4}$/****/' | sort | uniq -c | sort -rn | head -10 |
			awk -v f="$f" 'NR == 1 { print "   (info) phone-like numbers in " f ", last 4 digits masked:" } { printf "   %5d %s\n", $1, $2 }'
	fi
done

if [ "$FOUND" -eq 0 ]; then
	echo "OK: scanned ${#FILES[@]} file(s); no addresses outside the allowlist ($ALLOW)."
	exit 0
fi
echo "FAIL: ${TOTAL} address(es) outside the allowlist in ${#FILES[@]} scanned file(s). Locate them with: wp eval-file find-string.php '@<domain>' — then add the key to the site config and run anonymize.php again."
exit 1
