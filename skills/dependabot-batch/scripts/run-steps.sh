#!/usr/bin/env bash
# run-steps.sh — Run CI steps locally and keep going after a failure.
#
# CI stops a job at its first failing step, so one red PR shows one problem at a time. This runs
# them all, so a fix does not have to wait for the next CI round to find the next problem.
#
# Usage:
#   run-steps.sh [--dir DIR] [--log-dir DIR] [--repeat N] [--load] -- 'CMD' ['CMD' ...]
#
#   --dir DIR      where to run (default: the current directory)
#   --log-dir DIR  where each step's output goes (default: a new temp directory)
#   --repeat N     run each step N times and tally the passes, to measure a flaky step
#   --load         keep every CPU busy meanwhile; timing failures tend to need it
#   -h, --help     this text
#
# Each CMD runs in `bash -c` from DIR. With an .nvmrc and nvm installed, the Node it names is used.
# The Node and PHP versions are printed first: a result is only as good as those versions are
# close to CI's, and the report has to say which ones it ran on.
#
# Exit status: 0 every step passed every time; 1 a step failed at least once; 2 a usage error.

set -uo pipefail

DIR="."
LOG_DIR=""
REPEAT=1
LOAD=0
CMDS=()

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "run-steps: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) [ $# -ge 2 ] || die "--dir needs a value"; DIR="$2"; shift 2 ;;
        --log-dir) [ $# -ge 2 ] || die "--log-dir needs a value"; LOG_DIR="$2"; shift 2 ;;
        --repeat) [ $# -ge 2 ] || die "--repeat needs a value"; REPEAT="$2"; shift 2 ;;
        --load) LOAD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do CMDS+=("$1"); shift; done ;;
        *) die "unknown argument: $1 (commands go after --)" ;;
    esac
done

[ "${#CMDS[@]}" -gt 0 ] || { usage >&2; exit 2; }
case "$REPEAT" in ''|*[!0-9]*|0) die "--repeat is a positive number, not: $REPEAT" ;; esac
[ -d "$DIR" ] || die "no such directory: $DIR"
cd "$DIR" || die "cannot enter: $DIR"

[ -n "$LOG_DIR" ] || LOG_DIR="$(mktemp -d)"
mkdir -p "$LOG_DIR" || die "cannot create: $LOG_DIR"

# nvm is a shell function and trips over `set -u`.
if [ -f .nvmrc ] && [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    set +u
    # shellcheck disable=SC1091
    . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1
    nvm use >/dev/null 2>&1 || echo "warning: nvm has no Node for .nvmrc ($(cat .nvmrc)); install it with: nvm install"
    set -u
fi

version_of() { # version_of LABEL CMD...
    local label="$1" out
    shift
    if command -v "$1" >/dev/null 2>&1; then
        out="$("$@" 2>/dev/null | head -1)"
        echo "$label: ${out:-unknown}"
    fi
}
version_of node node -v
[ ! -f .nvmrc ] || echo ".nvmrc: $(cat .nvmrc)"
version_of php php -r 'echo PHP_VERSION;'
echo "logs: $LOG_DIR"

LOAD_PIDS=""
stop_load() {
    # shellcheck disable=SC2086  # a space-separated list of pids
    [ -z "$LOAD_PIDS" ] || kill $LOAD_PIDS 2>/dev/null
    LOAD_PIDS=""
}
trap stop_load EXIT
trap 'stop_load; exit 130' INT TERM

if [ "$LOAD" -eq 1 ]; then
    cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
    i=0
    while [ "$i" -lt "$cpus" ]; do
        yes >/dev/null 2>&1 &
        LOAD_PIDS="$LOAD_PIDS $!"
        i=$((i + 1))
    done
    # The traps do not run when this script is killed outright (SIGKILL, a tool's timeout), so a
    # watchdog stops the load once the script is gone. $$ is this script's pid in the subshell too.
    # shellcheck disable=SC2086  # a space-separated list of pids
    ( while kill -0 $$ 2>/dev/null; do sleep 1; done; kill $LOAD_PIDS 2>/dev/null ) >/dev/null 2>&1 &
    LOAD_PIDS="$LOAD_PIDS $!"
    echo "load: $cpus busy loops"
fi

FAILED=0
step=0
for cmd in "${CMDS[@]}"; do
    step=$((step + 1))
    slug="$(printf '%s' "$cmd" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40)"
    passes=0
    round=1
    start=$SECONDS
    last_fail=""
    while [ "$round" -le "$REPEAT" ]; do
        log="$LOG_DIR/$(printf '%02d' "$step")-$slug.$round.log"
        if bash -c "$cmd" >"$log" 2>&1 </dev/null; then
            passes=$((passes + 1))
        else
            rc=$?
            last_fail="$log (exit $rc)"
        fi
        round=$((round + 1))
    done
    elapsed=$((SECONDS - start))
    if [ "$passes" -eq "$REPEAT" ]; then
        verdict=PASS
    elif [ "$passes" -eq 0 ]; then
        verdict=FAIL
        FAILED=$((FAILED + 1))
    else
        verdict=FLAKY
        FAILED=$((FAILED + 1))
    fi
    printf '%-5s %s/%s  %4ss  %s\n' "$verdict" "$passes" "$REPEAT" "$elapsed" "$cmd"
    [ -z "$last_fail" ] || echo "      log: $last_fail"
done

echo "steps=$step failed=$FAILED"
[ "$FAILED" -eq 0 ]
