#!/usr/bin/env bash
# Continuously print cgroup cpu.stat rate of change every second
# Usage: ./cgroup_cpu_rate.sh /sys/fs/cgroup/.../cpu.stat

set -euo pipefail

CGROUP_STAT="${1:-}"

if [[ -z "$CGROUP_STAT" || ! -f "$CGROUP_STAT" ]]; then
    echo "Usage: $0 <path/to/cpu.stat>"
    exit 1
fi

read_stat() {
    declare -A s
    while read -r key val; do
        s["$key"]=$val
    done < "$CGROUP_STAT"
    echo "${s[usage_usec]:-0} ${s[user_usec]:-0} ${s[system_usec]:-0} ${s[nr_periods]:-0} ${s[nr_throttled]:-0} ${s[throttled_usec]:-0}"
}

# Initial sample
read -r u_prev us_prev sy_prev p_prev t_prev th_prev <<< "$(read_stat)"

echo "time                  usage/s    user/s     sys/s      periods/s  throttled/s  throttled_us/s  cores"
echo "-----------------------------------------------------------------------------------------------"

while true; do
    sleep 1
    read -r u us sy p t th <<< "$(read_stat)"

    du=$((u - u_prev))
    dus=$((us - us_prev))
    dsy=$((sy - sy_prev))
    dp=$((p - p_prev))
    dt=$((t - t_prev))
    dth=$((th - th_prev))

    cores=$(awk "BEGIN {printf \"%.3f\", $du / 1000000}")

    printf "%s  %'10d %'10d %'10d %'10d %'12d %'15d  %s\n" \
        "$(date '+%H:%M:%S')" \
        "$du" "$dus" "$dsy" "$dp" "$dt" "$dth" "$cores"

    # Update previous
    u_prev=$u
    us_prev=$us
    sy_prev=$sy
    p_prev=$p
    t_prev=$t
    th_prev=$th
done
