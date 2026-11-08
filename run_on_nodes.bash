#!/usr/bin/env bash
# run_on_nodes.sh - run a command on each IP from a file, N-way parallel
#
# Usage:  ./run_on_nodes.sh "<remote-command>"
# Env:    NODEFILE  (default: nodenames)
#         PARALLEL  (default: 100)
#         TIMEOUT   (default: 60)   per-host SSH timeout in seconds
#
# Example:
# NODEFILE=nodenames bash run_on_nodes.bash "sh -c 'turbostat --add msr0x1a0,raw --hide all  --num_iterations 1 -S 2>&1 | grep MSR_IA32_MISC_ENABLE'" > msr_check.output

set -uo pipefail

NODEFILE="${NODEFILE:-nodenames}"
PARALLEL="${PARALLEL:-100}"
TIMEOUT="${TIMEOUT:-60}"

if [ "$#" -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,13p' "$0" >&2
    exit 1
fi

REMOTE_CMD="$*"

# Transport the command as base64 so ssh's argument parsing can't mangle it.
# (Without this, quotes/pipes/$-vars in $REMOTE_CMD get re-parsed by the
# remote login shell before your actual command ever runs.)
B64=$(printf '%s' "$REMOTE_CMD" | base64 | tr -d '\n')
export B64 TIMEOUT

run_one() {
    local ip="$1" out
    out=$(timeout "$TIMEOUT" ssh -q \
              -o BatchMode=yes \
              -o ConnectTimeout=10 \
              -o StrictHostKeyChecking=accept-new \
              "$ip" "printf '%s' '$B64' | base64 -d | sh" 2>&1)
    # Collapse any multi-line output into a single line for "ip: output".
    out=$(printf '%s\n' "$out" \
          | awk 'NF{if(n++)printf " | "; printf "%s", $0}')
    printf '%s: %s\n' "$ip" "$out"
}
export -f run_one

[ -r "$NODEFILE" ] || { echo "cannot read nodefile: $NODEFILE" >&2; exit 1; }

grep -vE '^[[:space:]]*(#|$)' "$NODEFILE" \
  | tr -d '\r' \
  | xargs -r -P "$PARALLEL" -I {} bash -c 'run_one "$1"' _ {}
