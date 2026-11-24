#!/usr/bin/env bash
# rx-affinity.sh <iface> [--live [sec]]
# Print MSI-X vector CPU affinity (cpuset) and per-RX-queue RPS mask for <iface>.
set -euo pipefail

IFACE="${1:?usage: $0 <iface> [--live [sec]]}"
shift || true
LIVE=0; LIVE_SEC=2
if [[ "${1:-}" == "--live" ]]; then LIVE=1; LIVE_SEC="${2:-2}"; fi

[[ -d "/sys/class/net/$IFACE" ]] || { echo "error: $IFACE not found" >&2; exit 1; }

# ---------- helpers ----------

compress_cpus() {           # [1 2 3 5 6 10] -> "1-3,5-6,10"
    local -a nums=("$@")
    local n=${#nums[@]}
    if (( n == 0 )); then printf ''; return; fi
    local out="" start="${nums[0]}" prev="${nums[0]}" i c
    for (( i=1; i<n; i++ )); do
        c="${nums[i]}"
        if (( c == prev + 1 )); then
            prev=$c
        else
            [[ -n "$out" ]] && out+=","
            if (( start == prev )); then out+="$start"; else out+="$start-$prev"; fi
            start=$c; prev=$c
        fi
    done
    [[ -n "$out" ]] && out+=","
    if (( start == prev )); then out+="$start"; else out+="$start-$prev"; fi
    printf '%s' "$out"
}

hex_to_cpuset() {           # MSB-first hex bitmap -> cpuset
    local hex="$1"
    hex="${hex//,/}"; hex="${hex//./}"; hex="${hex// /}"
    hex="${hex#"${hex%%[!0]*}"}"          # trim leading zeros
    if [[ -z "$hex" ]]; then printf ''; return; fi
    local -a cpus=()
    local len=${#hex} bitpos=0 i c v b
    for (( i=len-1; i>=0; i-- )); do
        c="${hex:$i:1}"; v=$((16#$c))
        for b in 0 1 2 3; do
            if (( (v >> b) & 1 )); then cpus+=($((bitpos + b))); fi
        done
        bitpos=$((bitpos + 4))
    done
    if (( ${#cpus[@]} == 0 )); then printf ''; else compress_cpus "${cpus[@]}"; fi
}

irq_label() {               # label column from /proc/interrupts
    local irq="$1"
    awk -v want="$irq" '
        /^[[:space:]]*[0-9]+:/ {
            n=$1; sub(":","",n)
            if (n+0 == want) {
                line=$0
                sub(/^[[:space:]]*[0-9]+:[[:space:]]*/, "", line)
                while (line ~ /^[0-9]+[[:space:]]+/) sub(/^[0-9]+[[:space:]]+/, "", line)
                print line; exit
            }
        }' /proc/interrupts
}

queue_idx_from_label() {    # mlx5_comp12 -> 12 ; i40e-...-TxRx-3 -> 3 ; ...-rx-5 -> 5
    local label="$1"
    if   [[ "$label" =~ mlx5_comp([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
    if   [[ "$label" =~ TxRx-([0-9]+)      ]]; then echo "${BASH_REMATCH[1]}"; return; fi
    if   [[ "$label" =~ (^|[^a-zA-Z0-9])rx-?([0-9]+) ]]; then echo "${BASH_REMATCH[2]}"; return; fi
    echo ""
}

enumerate_irqs() {
    local iface="$1"
    if [[ -d "/sys/class/net/$iface/device/msi_irqs" ]]; then
        ls "/sys/class/net/$iface/device/msi_irqs/" | sort -n; return 0
    fi
    if [[ -r "/sys/class/net/$iface/irq" ]]; then
        local i; i=$(cat "/sys/class/net/$iface/irq" 2>/dev/null || echo 0)
        if [[ "$i" != "0" ]]; then echo "$i"; fi; return 0
    fi
    awk -v name="$iface" '
        /^[[:space:]]*[0-9]+:/ { if (index($0, name) > 0) { n=$1; sub(":","",n); print n } }
    ' /proc/interrupts | sort -n
}

snapshot_irqs() {           # "<irq> <sum-of-counters>" from /proc/interrupts
    awk '/^[[:space:]]*[0-9]+:/ {
        n=$1; sub(":","",n); s=0
        for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+$/) s+=$i
        print n, s
    }' /proc/interrupts
}

# ---------- IRQs ----------
echo "Interface: $IFACE"
echo

IRQS=()
mapfile -t IRQS < <(enumerate_irqs "$IFACE")

if (( ${#IRQS[@]} == 0 )); then
    echo "IRQs: none found"
else
    echo "MSI-X vectors (affinity in cpuset notation):"
    printf "  %-7s %-28s %-6s %s\n" "IRQ" "affinity" "queue" "label"
    for irq in "${IRQS[@]}"; do
        aff="(unreadable)"
        if [[ -r "/proc/irq/$irq/smp_affinity_list" ]]; then
            aff=$(tr -d '[:space:]' < "/proc/irq/$irq/smp_affinity_list")
        fi
        label=$(irq_label "$irq" || true)
        q=$(queue_idx_from_label "$label")
        printf "  %-7s %-28s %-6s %s\n" "$irq" "$aff" "${q:--}" "$label"
    done

    if (( LIVE )); then
        echo
        echo "Live vector deltas over ${LIVE_SEC}s:"
        declare -A before=() after=()
        while read -r irq total; do before["$irq"]=$total; done < <(snapshot_irqs)
        sleep "$LIVE_SEC"
        while read -r irq total; do after["$irq"]=$total; done < <(snapshot_irqs)
        active=""
        for irq in "${IRQS[@]}"; do
            b="${before[$irq]:-0}"; a="${after[$irq]:-0}"; d=$((a - b))
            printf "  IRQ %-7s delta=%s\n" "$irq" "$d"
            if (( d > 0 )); then active+="$irq "; fi
        done
        echo "  Active (delta>0): ${active:-none}"
        unset before after
    fi
fi

echo

# ---------- RPS ----------
QDIR="/sys/class/net/$IFACE/queues"
if [[ ! -d "$QDIR" ]]; then echo "RPS: $QDIR not found"; exit 0; fi
shopt -s nullglob
rps_glob=("$QDIR"/rx-*/rps_cpus)
shopt -u nullglob
if (( ${#rps_glob[@]} == 0 )); then echo "RPS: no rx-*/rps_cpus under $QDIR"; exit 0; fi

mapfile -t RPS_FILES < <(printf '%s\n' "${rps_glob[@]}" | sort -V)
echo "RPS (per RX queue):"
printf "  %-7s %-28s %s\n" "queue" "rps_cpus" "raw"
for f in "${RPS_FILES[@]}"; do
    qname=$(basename "$(dirname "$f")")
    hex=$(cat "$f" 2>/dev/null || echo "?")
    if [[ "$hex" == "?" ]]; then
        cpuset="(unreadable)"
    elif [[ "$hex" =~ ^[0,]+$ ]]; then
        cpuset="(disabled)"
    else
        cpuset=$(hex_to_cpuset "$hex")
        if [[ -z "$cpuset" ]]; then cpuset="(disabled)"; fi
    fi
    printf "  %-7s %-28s %s\n" "$qname" "$cpuset" "$hex"
done
