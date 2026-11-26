#!/usr/bin/env bash
# scan-pii.sh — Gate for a local copy of production: fail if personal data is still on disk.
#
# Usage:
#   scan-pii.sh [--allow-domain DOMAIN]... [--allow-address ADDRESS]... [--allow-file FILE]
#               [--allow-glued-address] [--phones] PATH...
#
# PATH can be a file (a SQLite database, a .sql backup, a log) or a directory. For a SQLite
# file its -wal / -shm siblings are scanned too. For a directory, database files, SQL dumps,
# logs, CSV/JSON/text files are scanned. Generated receipts/invoices (PDFs under wpo_wcpdf_*)
# and compressed archives fail, whether given as PATH or found under one, because they cannot
# be checked here.
#
# An email address passes when its domain is allowlisted (example.com/.org/.net, localhost,
# localdomain, invalid, test, plus --allow-domain), a subdomain of one, or one followed only by
# letters that `strings` glued on from the next bytes (example.comz, but not testcompany.jp).
# --allow-address passes one address (staff, store sender) without allowing its whole domain,
# also with letters glued on after it. With characters glued on BEFORE it, it fails and is
# reported on its own line: bytes of the neighbouring column (in SQLite, user_nicename comes
# right before user_email) cannot be told from a different, longer address (shop@ -> myshop@).
# The local part is read with every character an address may contain (customer=shop@ is one
# address, not shop@), except that a leading apostrophe is the quote of an SQL or JSON value.
# When find-string.php shows that every hit is a staff or store row, pass
# --allow-glued-address. --allow-file reads one entry per line (an entry with @ is an address,
# otherwise a domain; # starts a comment), such as the file pii-inventory.php write-allow=
# writes. Only domains are printed, never full addresses. --phones adds an informational count
# of phone-like numbers (masked); phones do not affect the exit status.
#
# Exit: 0 nothing found; 1 addresses outside the allowlist, allowlisted addresses with
# characters glued on before them, generated documents or archives found; 2 usage error,
# missing path, nothing scannable under the paths, or a file that could not be read (this
# wins over 1: the result says nothing about that file).
set -uo pipefail

ALLOW="example.com example.org example.net localhost localdomain invalid test"
# RFC 5322 atext plus the dot. An apostrophe counts only between them (o'brien@): a leading one
# is the quote around an SQL or JSON value ('admin@example.com').
LOCAL_CHARS='A-Za-z0-9.!#$%&*+/=?^_`{|}~-'
EMAIL_RE="[${LOCAL_CHARS}]+('[${LOCAL_CHARS}]+)*@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
ALLOW_ADDR=""
ALLOW_GLUED=0
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
	--allow-glued-address) ALLOW_GLUED=1; shift ;;
	--phones) PHONES=1; shift ;;
	-h | --help) sed -n '2,32p' "$0"; exit 0 ;;
	--) shift; PATHS+=("$@"); break ;;
	-*) echo "scan-pii: unknown option $1" >&2; exit 2 ;;
	*) PATHS+=("$1"); shift ;;
	esac
done
[ ${#PATHS[@]} -gt 0 ] || { echo "scan-pii: give at least one PATH (see --help)" >&2; exit 2; }
command -v strings >/dev/null 2>&1 || { echo "scan-pii: strings not found (install binutils or the Xcode command line tools)" >&2; exit 2; }

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
		# The same files the directory branch fails on: `strings` cannot read them.
		case "$(lower "$p")" in
		*.gz | *.zip | *.tgz | *.tar | *.wpress | *.bz2 | *.xz)
			echo "== $p: a compressed archive that this scan cannot read — extract and scan it, or delete it"
			FOUND=1
			;;
		*wpo_wcpdf*.pdf)
			echo "== $p: a generated document (receipt/invoice under wpo_wcpdf_*) — it names customers; delete it"
			FOUND=1
			;;
		*) add_file "$p" ;;
		esac
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

# One line per address that does not pass: "outside <domain>", or "glued <domain>" for an
# allowlisted address with characters glued on before it ("glued-ok <domain>" with
# --allow-glued-address, for the informational count). Returns non-zero when the file could
# not be read: empty output must not pass for a clean file.
classify_addresses() {
	LC_ALL=C strings -n 6 "$1" 2>/dev/null |
		LC_ALL=C grep -oiE "$EMAIL_RE" |
		awk -v allow="$ALLOW" -v addrs="$ALLOW_ADDR" -v allow_glued="$ALLOW_GLUED" '
			# What `strings` glues on after a TLD from the next bytes: letters only. Anything
			# with a dot or a digit in it is a longer domain (testcompany.jp, example.com.evil).
			function glue(s) { return s ~ /^[a-z]+$/ }
			BEGIN { n = split(allow, A, " "); m = split(addrs, B, " ") }
			{
				e = tolower($0); d = substr(e, index(e, "@") + 1)
				for (i = 1; i <= n; i++) {
					a = A[i]
					if (d == a) next
					if (length(d) > length(a)) {
						if (substr(d, length(d) - length(a)) == "." a) next
						if (substr(d, 1, length(a)) == a && glue(substr(d, length(a) + 1))) next
					}
				}
				glued = 0
				for (j = 1; j <= m; j++) {
					pos = index(e, B[j])
					if (pos == 0) continue
					tail = substr(e, pos + length(B[j]))
					if (tail != "" && !glue(tail)) continue
					if (pos == 1) next
					# Characters before it: the neighbouring column, or a different, longer
					# address that ends in this one. Bytes alone cannot tell which.
					glued = 1
				}
				if (glued) print (allow_glued ? "glued-ok " : "glued ") d
				else print "outside " d
			}'
	# strings must succeed; grep exits 1 when there is simply no address.
	local status=("${PIPESTATUS[@]}")
	[ "${status[0]}" -eq 0 ] && [ "${status[1]}" -le 1 ] && [ "${status[2]}" -eq 0 ]
}

if [ ${#FILES[@]} -eq 0 ] && [ "$FOUND" -eq 0 ]; then
	echo "scan-pii: no database, SQL, log, CSV, JSON or text files under ${PATHS[*]} — check the path" >&2
	exit 2
fi

TOTAL=0
GLUED=0
UNREAD=0
# by_domain DOMAINS: one "count *@domain" line per domain, most frequent first.
by_domain() { printf '%s\n' "$1" | sort | uniq -c | sort -rn | awk '{ printf "   %5d *@%s\n", $1, $2 }'; }
for f in ${FILES[@]+"${FILES[@]}"}; do
	if ! hits="$(classify_addresses "$f")"; then
		echo "== $f: could not be read (permissions, or strings failed) — nothing is known about it"
		UNREAD=$((UNREAD + 1))
		continue
	fi
	domains="$(printf '%s\n' "$hits" | sed -n 's/^outside //p')"
	glued="$(printf '%s\n' "$hits" | sed -n 's/^glued //p')"
	glued_ok="$(printf '%s\n' "$hits" | sed -n 's/^glued-ok //p')"
	if [ -n "$domains" ]; then
		count="$(printf '%s\n' "$domains" | wc -l | tr -d ' ')"
		TOTAL=$((TOTAL + count))
		echo "== $f: ${count} address(es) outside the allowlist"
		by_domain "$domains"
		FOUND=1
	fi
	if [ -n "$glued" ]; then
		count="$(printf '%s\n' "$glued" | wc -l | tr -d ' ')"
		GLUED=$((GLUED + count))
		echo "== $f: ${count} allowlisted address(es) with characters glued on before them — the neighbouring column, or a different, longer address"
		by_domain "$glued"
		FOUND=1
	fi
	if [ -n "$glued_ok" ]; then
		echo "   (info) $f: $(printf '%s\n' "$glued_ok" | wc -l | tr -d ' ') allowlisted address(es) with characters glued on before them passed (--allow-glued-address)"
	fi
	if [ "$PHONES" -eq 1 ]; then
		LC_ALL=C strings -n 6 "$f" 2>/dev/null |
			LC_ALL=C grep -oE '0[0-9]{1,4}-[0-9]{1,4}-[0-9]{4}' |
			grep -v '^000-0000-0000$' |
			sed -E 's/[0-9]{4}$/****/' | sort | uniq -c | sort -rn | head -10 |
			awk -v f="$f" 'NR == 1 { print "   (info) phone-like numbers in " f ", last 4 digits masked:" } { printf "   %5d %s\n", $1, $2 }'
	fi
done

if [ "$UNREAD" -gt 0 ]; then
	echo "INCOMPLETE: ${UNREAD} of ${#FILES[@]} file(s) could not be read (see above). Fix that and run again — an unread file is not a clean one."
	exit 2
fi
if [ "$FOUND" -eq 0 ]; then
	echo "OK: scanned ${#FILES[@]} file(s); no addresses outside the allowlist ($ALLOW)."
	exit 0
fi
echo "FAIL: ${TOTAL} address(es) outside the allowlist in ${#FILES[@]} scanned file(s). Locate them with: wp eval-file find-string.php '@<domain>' — then add the key to the site config and run anonymize.php again."
if [ "$GLUED" -gt 0 ]; then
	echo "      ${GLUED} allowlisted address(es) had characters glued on before them. Locate them with: wp eval-file find-string.php '<allowlisted address>' — if every hit is a staff or store row, run again with --allow-glued-address."
fi
exit 1
