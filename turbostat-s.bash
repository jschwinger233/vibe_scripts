#!/bin/bash
# turbostat-summary-filtered-loop.sh
# Continuous summary (every interval) only for the specified CPUs
# Usage: ./turbostat-summary-filtered-loop.sh 32-63,96-127

if [ -z "$1" ]; then
  echo "Usage: $0 <cpu-list>"
  echo "Example: $0 32-63,96-127"
  exit 1
fi

CPUS="$1"
INTERVAL=1
TJMAX=100

SHOW="CPU,Core,Busy%,Bzy_MHz,CoreTmp,PkgTmp,PkgWatt"

echo "CPU	Core	Busy%	Bzy_MHz	CoreTmp	PkgTmp	PkgWatt"
echo "--- summary of $CPUS only (every ${INTERVAL}s) ---"

sudo turbostat --quiet --interval "$INTERVAL" --cpu "$CPUS" \
  --show "$SHOW" -T "$TJMAX" 2>/dev/null | \
awk '
BEGIN {
  sum_busy = 0; sum_bzy_weighted = 0; n = 0
  max_core = 0; max_pkg = 0; sum_pkgwatt = 0; pkgwatt_count = 0
}
function emit() {
  if (n == 0) return
  avg_busy = sum_busy / n
  avg_bzy = (sum_busy > 0) ? sum_bzy_weighted / sum_busy : 0
  avg_pkgwatt = (pkgwatt_count > 0) ? sum_pkgwatt / pkgwatt_count : 0
  printf "-	-	%.2f	%.0f	%.0f	%.0f	%.2f\n", \
    avg_busy, avg_bzy, max_core, max_pkg, avg_pkgwatt
  fflush()
  sum_busy = 0; sum_bzy_weighted = 0; n = 0
  max_core = 0; max_pkg = 0; sum_pkgwatt = 0; pkgwatt_count = 0
}
/^[-]/ {
  emit()
  next
}
/^CPU/ || NF < 4 { next }
{
  busy = $3 + 0
  bzy  = $4 + 0
  coretmp = $5 + 0
  pkgtmp  = $6 + 0
  pkgwatt = ($7 != "" ? $7 + 0 : 0)

  sum_busy += busy
  sum_bzy_weighted += bzy * busy
  if (coretmp > max_core) max_core = coretmp
  if (pkgtmp  > max_pkg)  max_pkg  = pkgtmp
  if (pkgwatt > 0) {
    sum_pkgwatt += pkgwatt
    pkgwatt_count++
  }
  n++
}
END { emit() }
'
