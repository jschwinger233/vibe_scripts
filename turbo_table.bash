#!/bin/bash
# turbo_table.sh [cpu]   (needs root, needs python3)
set -e
CPU="${1:-0}"
DEV="/dev/cpu/${CPU}/msr"

[[ -r "$DEV" ]] || { echo "Cannot read $DEV (run as root)" >&2; exit 1; }

read_msr() {           # $1 = MSR address
    dd if="$DEV" bs=8 count=1 skip=$(( $1 )) iflag=skip_bytes 2>/dev/null \
       | od -An -t x8 | tr -d ' \n'
}

R=$(read_msr 0x1AD)
T=$(read_msr 0x1AE)

printf 'CPU %d\n  MSR 0x1AD = 0x%s\n  MSR 0x1AE = 0x%s\n\n' "$CPU" "$R" "$T"

python3 - "$R" "$T" <<'PY'
import sys
r = int(sys.argv[1], 16)
t = int(sys.argv[2], 16)

print(f"{'Core range':>12}  {'Ratio':>5}  {'Freq@100MHz':>12}")
print("-" * 35)

prev = 0
for i in range(8):
    ratio = (r >> (8 * i)) & 0xFF
    cores = (t >> (8 * i)) & 0xFF
    if cores <= prev or cores in (0x00, 0xFF):   # sentinel / unused
        break
    print(f"{prev + 1:5d} - {cores:3d}    {ratio:5d}  {ratio * 100:9d} MHz")
    prev = cores
PY
