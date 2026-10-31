#!/usr/bin/env bash
#
# net-mbps.sh - per-interface RX/TX throughput in Mbps, mpstat-style output.
#
# Usage:  net-mbps.sh -i eth0,eth1 [interval]
#
# Counters are read with:  ip -s -s link show dev <iface>
# The first sample only establishes a baseline; numbers appear from 2nd tick on.

set -u
export LC_ALL=C

prog=${0##*/}
ifaces_arg=""
interval=1

if (( BASH_VERSINFO[0] < 4 )); then
    echo "$prog: bash >= 4 required (associative arrays)" >&2
    exit 1
fi

usage() {
    cat <<EOF
Usage: $prog -i IFACE[,IFACE...] [INTERVAL]

Periodically print per-interface RX/TX throughput (Mbps), mpstat(1)-style.

  -i IFACE[,IFACE...]   interfaces to monitor (comma-separated, required)
                        may also be given as: -i eth0 -i eth1
  -h                    show this help

  INTERVAL              sampling interval in seconds (default: 1)

Example:
  $prog -i eth0,eth1 0.5
EOF
}

while getopts ":i:h" opt; do
    case $opt in
        i) ifaces_arg="${ifaces_arg:+$ifaces_arg,}$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "$prog: option -$OPTARG requires an argument" >&2; exit 1 ;;
        \?) echo "$prog: unknown option -$OPTARG" >&2; usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -gt 0 ]] && interval=$1

if [[ -z $ifaces_arg ]]; then
    echo "$prog: -i is required" >&2
    usage >&2
    exit 1
fi

if [[ ! $interval =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ $interval =~ ^0+(\.0+)?$ ]]; then
    echo "$prog: invalid interval '$interval'" >&2
    exit 1
fi

command -v ip >/dev/null 2>&1 || { echo "$prog: 'ip' not found" >&2; exit 1; }

# --- interface list --------------------------------------------------------
IFS=',' read -r -a iface_list <<< "$ifaces_arg"
for i in "${!iface_list[@]}"; do
    iface_list[$i]=$(printf '%s' "${iface_list[$i]}" | tr -d '[:space:]')
done

for iface in "${iface_list[@]}"; do
    if [[ -z $iface ]]; then
        echo "$prog: empty interface name in -i list" >&2
        exit 1
    fi
    if ! ip link show dev "$iface" >/dev/null 2>&1; then
        echo "$prog: interface '$iface' not found" >&2
        exit 1
    fi
done

# --- counter reader --------------------------------------------------------
# Echo:  <rx_bytes> <rx_packets> <tx_bytes> <tx_packets>
# The data line directly after "RX:" / "TX:" holds bytes & packets.
get_stats() {
    ip -s -s link show dev "$1" 2>/dev/null | awk -v iface="$1" '
        /^[0-9]+: / {
            name = $2
            sub(/:$/, "", name)
            sub(/@.*/, "", name)
            if (name == iface) found = 1
            next
        }
        !found { next }
        /RX:/ { getline; rx_b = $1; rx_p = $2; next }
        /TX:/ { getline; tx_b = $1; tx_p = $2; exit }
        END   { printf "%d %d %d %d\n", rx_b+0, rx_p+0, tx_b+0, tx_p+0 }
    '
}

# --- mpstat-style banner ---------------------------------------------------
host=$(hostname 2>/dev/null || uname -n)
printf 'Linux %s (%s) \t%s \t_%s_\t(%d NIC)\n\n' \
    "$(uname -r)" "$host" "$(date +%m/%d/%Y)" "$(uname -m)" "${#iface_list[@]}"

printf '%-11s  %-15s  %10s  %10s  %10s  %10s\n' \
    "Time" "IFACE" "RX_Mbps" "TX_Mbps" "RX_pps" "TX_pps"

# --- baseline --------------------------------------------------------------
declare -A p_rxb p_rxp p_txb p_txp
for iface in "${iface_list[@]}"; do
    read -r rxb rxp txb txp <<< "$(get_stats "$iface")"
    p_rxb[$iface]=$rxb
    p_rxp[$iface]=$rxp
    p_txb[$iface]=$txb
    p_txp[$iface]=$txp
done

prev_epoch=$(date +%s.%N)

# --- sampling loop ---------------------------------------------------------
while :; do
    sleep "$interval"

    now=$(date +%s.%N)
    elapsed=$(awk -v a="$prev_epoch" -v b="$now" -v fb="$interval" '
        BEGIN { d = b - a; if (d <= 0) d = fb; printf "%.6f", d }')
    ts=$(date +"%I:%M:%S %p")

    for iface in "${iface_list[@]}"; do
        read -r rxb rxp txb txp <<< "$(get_stats "$iface")"

        drxb=$(( rxb - p_rxb[$iface] )); (( drxb < 0 )) && drxb=0
        drxp=$(( rxp - p_rxp[$iface] )); (( drxp < 0 )) && drxp=0
        dtxb=$(( txb - p_txb[$iface] )); (( dtxb < 0 )) && dtxb=0
        dtxp=$(( txp - p_txp[$iface] )); (( dtxp < 0 )) && dtxp=0

        read -r rx_mbps tx_mbps rx_pps tx_pps < <(awk \
            -v drxb="$drxb" -v dtxb="$dtxb" \
            -v drxp="$drxp" -v dtxp="$dtxp" -v dt="$elapsed" '
            BEGIN {
                printf "%.2f %.2f %.1f %.1f\n",
                       drxb*8/dt/1e6, dtxb*8/dt/1e6, drxp/dt, dtxp/dt
            }')

        printf '%-11s  %-15s  %10s  %10s  %10s  %10s\n' \
            "$ts" "$iface" "$rx_mbps" "$tx_mbps" "$rx_pps" "$tx_pps"

        p_rxb[$iface]=$rxb
        p_rxp[$iface]=$rxp
        p_txb[$iface]=$txb
        p_txp[$iface]=$txp
    done

    prev_epoch=$now
done
