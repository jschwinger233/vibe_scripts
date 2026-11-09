#!/bin/bash
# package_power_msr.bash - 用 dd 读 /dev/cpu/*/msr 监控所有 Package 功耗

# 从指定 CPU 读一个 MSR（返回十进制）
read_msr() {
    local cpu=$1
    local msr=$2
    dd if=/dev/cpu/${cpu}/msr bs=8 count=1 skip=$((msr)) iflag=skip_bytes 2>/dev/null \
        | od -An -tu8 | tr -d ' '
}

# 找出每个 Socket 的第一个 CPU
declare -A SOCKET_CPU
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    cpu=${cpu_dir##*/cpu}
    pkg_file="$cpu_dir/topology/physical_package_id"
    [ -f "$pkg_file" ] || continue
    pkg=$(cat "$pkg_file")
    if [ -z "${SOCKET_CPU[$pkg]}" ]; then
        SOCKET_CPU[$pkg]=$cpu
    fi
done

SOCKET_IDS=($(printf '%s\n' "${!SOCKET_CPU[@]}" | sort -n))
if [ ${#SOCKET_IDS[@]} -eq 0 ]; then
    echo "未找到 CPU 拓扑"
    exit 1
fi

# 读取能量单位（用第一个 socket）
first_cpu=${SOCKET_CPU[${SOCKET_IDS[0]}]}
unit_raw=$(read_msr "$first_cpu" 0x606)
esu=$(( (unit_raw >> 8) & 0x1f ))
energy_unit=$(awk -v e="$esu" 'BEGIN { printf "%.12f", 1/(2^e) }')

echo "检测到 ${#SOCKET_IDS[@]} 个 Socket，能量单位: $energy_unit J"
echo "开始监控 Package 功耗 (Ctrl+C 停止)..."
echo

# 初始化上一次能量值
declare -a PREV_ENERGY
for i in "${!SOCKET_IDS[@]}"; do
    pkg=${SOCKET_IDS[$i]}
    cpu=${SOCKET_CPU[$pkg]}
    PREV_ENERGY[$i]=$(read_msr "$cpu" 0x611)
done

while true; do
    sleep 1
    LINE="$(date +%T)"

    for i in "${!SOCKET_IDS[@]}"; do
        pkg=${SOCKET_IDS[$i]}
        cpu=${SOCKET_CPU[$pkg]}
        curr=$(read_msr "$cpu" 0x611)

        # 处理 32-bit 回绕
        if [ "$curr" -lt "${PREV_ENERGY[$i]}" ]; then
            diff=$(( (curr + 4294967296) - PREV_ENERGY[i] ))
        else
            diff=$(( curr - PREV_ENERGY[i] ))
        fi

        power=$(awk -v d="$diff" -v u="$energy_unit" \
            'BEGIN { printf "%.2f", d * u }')

        LINE="$LINE  Socket $pkg: ${power} W"
        PREV_ENERGY[$i]=$curr
    done

    echo "$LINE"
done
