#!/usr/bin/env bash
# swap-run.sh — Run a command while the files that differ from a git ref are temporarily put
# back to that ref's version, then restore them byte for byte (also on failure, Ctrl-C or
# kill). Use it to measure the "before" state of a site whose code is the working tree
# (for example a theme symlinked into a local WordPress site).
#
# Usage:
#   swap-run.sh --ref <git-ref> [--path <pathspec>]... [--allow-dirty] [--repo <dir>] -- <command> [args...]
#
# The swapped set is every file that differs between <ref> and the working tree under the
# pathspecs (modified files get the ref's content, files missing at the ref are moved aside,
# files deleted since the ref come back), plus untracked files under them (moved aside).
# Files with uncommitted changes (including untracked files) are refused unless --allow-dirty;
# with it they are backed up and restored exactly. The backup directory is printed first and
# exported as SWAP_RUN_BACKUP, so it can be recovered by hand if the process is killed with -9.
#
# Exit: the command's exit status; 2 usage error, unknown ref, nothing differs, or dirty files
# refused; 3 the files could not be restored exactly (the backup is kept); 130/143 interrupted.
set -uo pipefail

REF=""
REPO="."
ALLOW_DIRTY=0
PATHS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--ref) [ $# -ge 2 ] || { echo "swap-run: --ref needs a value" >&2; exit 2; }; REF="$2"; shift 2 ;;
	--path) [ $# -ge 2 ] || { echo "swap-run: --path needs a value" >&2; exit 2; }; PATHS+=("$2"); shift 2 ;;
	--repo) [ $# -ge 2 ] || { echo "swap-run: --repo needs a value" >&2; exit 2; }; REPO="$2"; shift 2 ;;
	--allow-dirty) ALLOW_DIRTY=1; shift ;;
	-h | --help) sed -n '2,21p' "$0"; exit 0 ;;
	--) shift; break ;;
	*) echo "swap-run: unknown argument $1 (put the command after --)" >&2; exit 2 ;;
	esac
done
[ -n "$REF" ] || { echo "swap-run: --ref is required" >&2; exit 2; }
[ $# -gt 0 ] || { echo "swap-run: give the command to run after --" >&2; exit 2; }

cd "$REPO" 2>/dev/null || { echo "swap-run: cannot cd to $REPO" >&2; exit 2; }
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "swap-run: $REPO is not in a git repository" >&2; exit 2; }
cd "$TOP" || exit 2
git rev-parse --verify --quiet "${REF}^{commit}" >/dev/null || { echo "swap-run: unknown ref $REF" >&2; exit 2; }

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

FILES=()
while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(
	{
		git diff --no-renames --name-only "$REF" -- ${PATHS[@]+"${PATHS[@]}"}
		git ls-files --others --exclude-standard -- ${PATHS[@]+"${PATHS[@]}"}
	} | sort -u
)
if [ ${#FILES[@]} -eq 0 ]; then
	echo "swap-run: no file under ${PATHS[*]:-the repository} differs from $REF — nothing to swap" >&2
	exit 2
fi

DIRTY=()
for f in "${FILES[@]}"; do
	[ -n "$(git status --porcelain -- "$f")" ] && DIRTY+=("$f")
done
if [ ${#DIRTY[@]} -gt 0 ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
	echo "swap-run: these files have uncommitted changes (or are untracked); refusing so they are not lost:" >&2
	printf '   %s\n' "${DIRTY[@]}" >&2
	echo "   commit them, or pass --allow-dirty to back them up and restore them exactly" >&2
	exit 2
fi

BK="$(mktemp -d "${TMPDIR:-/tmp}/swap-run.XXXXXX")" || exit 2
export SWAP_RUN_BACKUP="$BK"
echo "swap-run: backup of the ${#FILES[@]} swapped file(s): $BK" >&2
: >"$BK/manifest"
for f in "${FILES[@]}"; do
	if [ -e "$f" ] || [ -L "$f" ]; then
		mkdir -p "$BK/files/$(dirname "$f")"
		cp -p "$f" "$BK/files/$f" || { echo "swap-run: cannot back up $f; nothing was changed" >&2; exit 2; }
		printf 'E\t%s\t%s\n' "$(sha "$f")" "$f" >>"$BK/manifest"
	else
		printf 'N\t-\t%s\n' "$f" >>"$BK/manifest"
	fi
done

RESTORED=0
restore() {
	[ "$RESTORED" -eq 1 ] && return 0
	RESTORED=1
	local kind sum f bad=0 n=0
	while IFS="$(printf '\t')" read -r kind sum f; do
		n=$((n + 1))
		if [ "$kind" = "E" ]; then
			mkdir -p "$(dirname "$f")"
			rm -f "$f"
			cp -p "$BK/files/$f" "$f" 2>/dev/null
			if [ ! -f "$f" ] || [ "$(sha "$f")" != "$sum" ]; then
				echo "swap-run: $f does not match its backup" >&2
				bad=1
			fi
		else
			rm -f "$f"
			[ -e "$f" ] && { echo "swap-run: could not remove $f" >&2; bad=1; }
		fi
	done <"$BK/manifest"
	if [ "$bad" -eq 0 ]; then
		rm -rf "$BK"
		echo "swap-run: restored $n file(s)" >&2
		return 0
	fi
	echo "swap-run: RESTORE FAILED — the original files are kept in $BK" >&2
	return 3
}

CHILD=""
# shellcheck disable=SC2329 # called from the traps below
on_signal() {
	local code="$1"
	[ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null && wait "$CHILD" 2>/dev/null
	restore || code=3
	exit "$code"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'restore || exit 3' EXIT

while IFS="$(printf '\t')" read -r _ _ f; do
	if git cat-file -e "${REF}:${f}" 2>/dev/null; then
		mkdir -p "$(dirname "$f")"
		rm -f "$f"
		git show "${REF}:${f}" >"$f"
		[ "$(git ls-tree "$REF" -- "$f" | cut -d' ' -f1)" = "100755" ] && chmod +x "$f"
		echo "   swapped to $REF: $f" >&2
	else
		rm -f "$f"
		echo "   moved aside (not in $REF): $f" >&2
	fi
done <"$BK/manifest"

"$@" &
CHILD=$!
wait "$CHILD"
RC=$?
CHILD=""
trap - EXIT
restore || exit 3
exit "$RC"
