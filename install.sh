#!/usr/bin/env bash
# install.sh — Install (or update) the shared Claude Code skills into ~/.claude/skills/
#
# Usage:
#   bash install.sh                 # install/update every skill in skills/
#   bash install.sh wc-development  # install/update one skill
#   bash install.sh --check         # report drift between skills/ and ~/.claude/skills/ (no changes)
#
# ~/.claude/skills/ is treated as a build output of this repository:
# edit skills here, run install.sh, and never hand-edit the installed copies.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="${REPO_DIR}/skills"
TARGET_DIR="${CLAUDE_SKILLS_DIR:-${HOME}/.claude/skills}"
MODE="install"
SPECIFIC=""

for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) SPECIFIC="$arg" ;;
    esac
done

list_skills() {
    if [ -n "$SPECIFIC" ]; then
        echo "$SPECIFIC"
    else
        for d in "${SKILLS_DIR}"/*/; do basename "$d"; done
    fi
}

install_skill() {
    local skill="$1" src dst
    src="${SKILLS_DIR}/${skill}"
    dst="${TARGET_DIR}/${skill}"
    if [ ! -d "$src" ]; then
        echo "  [skip]    ${skill} — not in skills/"
        return
    fi
    if [ -d "$dst" ]; then
        echo "  [update]  ${skill}"
    else
        echo "  [install] ${skill}"
    fi
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete --exclude .DS_Store "${src}/" "${dst}/"
    else
        rm -rf "${dst:?}"/* && cp -R "${src}/." "${dst}/"
    fi
}

check_skill() {
    local skill="$1" src dst
    src="${SKILLS_DIR}/${skill}"
    dst="${TARGET_DIR}/${skill}"
    if [ ! -d "$dst" ]; then
        echo "  [missing] ${skill} — not installed"
        return 1
    fi
    if diff -rq -x .DS_Store "$src" "$dst" >/dev/null; then
        echo "  [ok]      ${skill}"
    else
        echo "  [DRIFT]   ${skill}"
        diff -rq -x .DS_Store "$src" "$dst" | sed 's/^/            /'
        return 1
    fi
}

mkdir -p "$TARGET_DIR"
echo "skills/ → ${TARGET_DIR} (${MODE})"
echo ""
status=0
while IFS= read -r skill; do
    if [ "$MODE" = "check" ]; then
        check_skill "$skill" || status=1
    else
        install_skill "$skill"
    fi
done < <(list_skills)

if [ "$MODE" = "check" ]; then
    echo ""
    echo "Installed but not in this repo:"
    for d in "${TARGET_DIR}"/*/; do
        n="$(basename "$d")"
        [ -d "${SKILLS_DIR}/${n}" ] || echo "  [extra]   ${n}"
    done
    exit $status
fi

echo ""
echo "Done. Restart Claude Code to pick up new or changed skills."
