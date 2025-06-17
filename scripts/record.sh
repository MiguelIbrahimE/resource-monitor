#!/usr/bin/env bash
set -euo pipefail

# ──────────────── paths ────────────────
DESKTOP="$HOME/Desktop"
BASE_DIR="$DESKTOP/resource-recorder"
DATA_DIR="$BASE_DIR/data"
mkdir -p "$DATA_DIR"

# ──────────────── helpers ──────────────
now()           { date '+%Y-%m-%d_%H-%M-%S'; }
read_cpu()      { awk '/^cpu /{for(i=1;i<=NF;i++) sum+=$i; print sum}' /proc/stat; }
read_idle()     { awk '/^cpu /{print $5+$6}' /proc/stat; }
mem_used_mb()   { awk '/MemTotal|MemAvailable/{a[$1]=$2} END{print (a["MemTotal:"]-a["MemAvailable:"])/1024}' /proc/meminfo; }

ENERGY_FILE="$(find /sys/class/powercap -name energy_uj | head -n1 || true)"
read_energy()   { [[ -n "$ENERGY_FILE" ]] && cat "$ENERGY_FILE" || echo 0; }

# ──────────────── initialise ───────────
echo "--------- Starting resource recording software ---------"
echo "Uptime: $(uptime -p)"
echo "Press Ctrl+C to stop and save summary."
echo "--------------------------------------------------------"

start_ts=$(now)
start_cpu_total=$(read_cpu)
start_cpu_idle=$(read_idle)
start_energy=$(read_energy)

samples=0
cpu_sum=0 cpu_min=1000 cpu_max=0         # %
mem_sum=0 mem_min=100000 mem_max=0       # MB

# ──────────────── main loop ────────────
trap 'break' INT TERM

while :; do
    sleep 1
    samples=$((samples+1))

    cpu_total_new=$(read_cpu)
    cpu_idle_new=$(read_idle)

    cpu_delta=$((cpu_total_new-start_cpu_total))
    idle_delta=$((cpu_idle_new-start_cpu_idle))
    cpu_used=$(( (100*(cpu_delta-idle_delta))/cpu_delta ))

    mem_now=$(mem_used_mb)

    # update stats
    cpu_sum=$((cpu_sum+cpu_used))
    (( cpu_used<cpu_min )) && cpu_min=$cpu_used
    (( cpu_used>cpu_max )) && cpu_max=$cpu_used

    mem_sum=$((mem_sum+mem_now))
    (( mem_now<mem_min )) && mem_min=$mem_now
    (( mem_now>mem_max )) && mem_max=$mem_now

    start_cpu_total=$cpu_total_new
    start_cpu_idle=$cpu_idle_new
done

# ──────────────── summarise ────────────
end_ts=$(now)
end_energy=$(read_energy)
energy_used_kwh=$(awk -v s="$start_energy" -v e="$end_energy" 'BEGIN{printf "%.5f",(e-s)/3.6e9}')

cpu_avg=$(awk -v s="$cpu_sum" -v n="$samples" 'BEGIN{printf "%.2f",s/n}')
mem_avg=$(awk -v s="$mem_sum" -v n="$samples" 'BEGIN{printf "%.2f",s/n}')

outfile="$DATA_DIR/summary_${start_ts}.txt"

{
    echo "Run started : $start_ts"
    echo "Run ended   : $end_ts"
    echo
    echo "CPU usage % : min $cpu_min · max $cpu_max · avg $cpu_avg"
    echo "RAM used MB : min $mem_min · max $mem_max · avg $mem_avg"
    [[ -n "$ENERGY_FILE" ]] && echo "Energy (kWh): $energy_used_kwh" || echo "Energy (kWh): n/a – power sensor not found"
} > "$outfile"

echo -e "\nSummary written to: $outfile"
