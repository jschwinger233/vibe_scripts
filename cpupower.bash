#!/bin/bash

RAPL_BASE="/sys/devices/virtual/powercap/intel-rapl"
SOCKETS=("intel-rapl:0" "intel-rapl:1")

declare -a MAX_ENERGY PREV_ENERGY PREV_TIME

# 初始化每个 socket 的状态
for i in "${!SOCKETS[@]}"; do
    path="$RAPL_BASE/${SOCKETS[$i]}"
    MAX_ENERGY[$i]=$(cat "$path/max_energy_range_uj")
    PREV_ENERGY[$i]=$(cat "$path/energy_uj")
    PREV_TIME[$i]=$(date +%s%N)
done

echo "开始监控 Package 功耗 (Ctrl+C 停止)..."
while true; do
    sleep 1
    LINE="$(date +%T)"
    for i in "${!SOCKETS[@]}"; do
        path="$RAPL_BASE/${SOCKETS[$i]}"
        CURR_ENERGY=$(cat "$path/energy_uj")
        CURR_TIME=$(date +%s%N)

        # 处理计数器溢出
        if [ "$CURR_ENERGY" -lt "${PREV_ENERGY[$i]}" ]; then
            DELTA_ENERGY=$(( (CURR_ENERGY + MAX_ENERGY[$i]) - PREV_ENERGY[$i] ))
        else
            DELTA_ENERGY=$(( CURR_ENERGY - PREV_ENERGY[$i] ))
        fi

        DELTA_TIME_NS=$(( CURR_TIME - PREV_TIME[$i] ))

        if [ "$DELTA_TIME_NS" -gt 0 ]; then
            POWER_W=$(awk -v de="$DELTA_ENERGY" -v dt="$DELTA_TIME_NS" 'BEGIN { printf "%.2f", de * 1000 / dt }')
            LINE="$LINE  Socket $i Power: ${POWER_W} W"
        fi

        PREV_ENERGY[$i]=$CURR_ENERGY
        PREV_TIME[$i]=$CURR_TIME
    done
    echo "$LINE"
done
