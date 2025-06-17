Here’s a **single-file Bash script** that works on

* **macOS** (Intel & Apple-silicon – requires `sudo` for live watts)
* **Linux** (kernels with `/proc` and Intel RAPL for watts)
* **WSL / Windows Git-Bash** (CPU & RAM only – watts not available)

Save it as `record.sh`, make it executable (`chmod +x record.sh`) and run it (`./record.sh`).
A new file with the run summary lands in:

```
~/Desktop/resource-recorder/runs/summary_<UTC-timestamp>.txt
```

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE="$HOME/Desktop/resource-recorder"
RUNS="$BASE/runs"
mkdir -p "$RUNS"

case "$(uname)" in
  Darwin*)
    CORES=$(sysctl -n hw.logicalcpu)
    cpu() { ps -A -o %cpu | awk -v c=$CORES 'NR>1{s+=$1} END{print s/c}'; }
    ram() { vm_stat | awk '/page size/ {pg=$8}
                           /^Pages free/ {free=$3}
                           /^Pages speculative/ {spec=$3}
                           /^Pages inactive/ {ina=$3}
                           /^Pages active/ {act=$3}
                           END{print (act+ina+spec)*pg/1048576}'; }
    watts() {
      command -v powermetrics >/dev/null || return
      sudo -n powermetrics -n1 -i200 -f json 2>/dev/null |
        awk '/"CPU Power"/ {gsub(/[^0-9.]/,"",$3);print $3;exit}'
    }
    BOOT_SEC=$(echo "$(date +%s) - $(sysctl -n kern.boottime | awk -F'[ ,]' '{print $5}')" | bc)
    ;;
  Linux*)
    CORES=$(nproc)
    read_stat() { awk '{for(i=2;i<=NF;i++) s+=$i; print s,$5}' /proc/stat; }
    PRE=($(read_stat))
    cpu() {
      CUR=($(read_stat)); sleep 0.05
      T=$((CUR[0]-PRE[0])); I=$((CUR[1]-PRE[1])); PRE=("${CUR[@]}")
      awk -v t=$T -v i=$I -v c=$CORES 'BEGIN{print (1-i/t)*100}'
    }
    ram() { awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print (t-a)/1024}' /proc/meminfo; }
    rapl() { local e=0; for f in /sys/class/powercap/intel-rapl:*/energy_uj; do [ -f "$f" ] && read v <"$f" && e=$((e+v)); done; echo $e; }
    R0=$(rapl); T0=$(date +%s%N)
    watts() {
      R1=$(rapl); T1=$(date +%s%N); ((R1>R0)) || { echo; return; }
      awk -v dE=$((R1-R0)) -v dT=$((T1-T0)) 'BEGIN{print (dE/1e6)/(dT/1e9)}'
      R0=$R1; T0=$T1
    }
    BOOT_SEC=$(awk '{print int($1)}' /proc/uptime)
    ;;
  *)
    cpu() { top -bn2 | grep "Cpu(s)" | tail -1 | awk '{print $2+$4}'; }
    ram() { echo 0; }
    watts() { echo; }
    BOOT_SEC=0
    ;;
esac

fmt() { printf "%.1f" "$1"; }

UP="$(awk -v S=$BOOT_SEC 'BEGIN{
  d=int(S/86400); S-=d*86400; h=int(S/3600); S-=h*3600; m=int(S/60);
  printf "%dd %02dh %02dm\n",d,h,m}')"

echo "--------- Starting resource recording software ---------"
echo "Uptime      : $UP"
echo "Press Ctrl+C to stop and save summary."
echo "--------------------------------------------------------"

trap 'STOP=1' INT
min_c=1000 max_c=0 sum_c=0
min_r=1e9  max_r=0 sum_r=0
min_w=1e9  max_w=0 sum_w=0 cnt_w=0
cnt=0; START=$(date -u +%Y-%m-%d_%H-%M-%S); NOW=$(date +%s)

while [[ -z ${STOP:-} ]]; do
  C=$(cpu); R=$(ram); W=$(watts || echo)
  (( $(echo "$C < $min_c" | bc -l) )) && min_c=$C
  (( $(echo "$C > $max_c" | bc -l) )) && max_c=$C
  (( $(echo "$R < $min_r" | bc -l) )) && min_r=$R
  (( $(echo "$R > $max_r" | bc -l) )) && max_r=$R
  sum_c=$(echo "$sum_c+$C" | bc); sum_r=$(echo "$sum_r+$R" | bc)
  if [[ -n $W ]]; then
    (( $(echo "$W < $min_w" | bc -l) )) && min_w=$W
    (( $(echo "$W > $max_w" | bc -l) )) && max_w=$W
    sum_w=$(echo "$sum_w+$W" | bc); ((cnt_w++))
  fi
  ((cnt++)); sleep 1
done

END=$(date -u +%Y-%m-%d_%H-%M-%S)
DUR=$(( $(date +%s) - NOW ))
avg_c=$(echo "$sum_c/$cnt" | bc -l)
avg_r=$(echo "$sum_r/$cnt" | bc -l)
if ((cnt_w)); then avg_w=$(echo "$sum_w/$cnt_w" | bc -l); else min_w=max_w=avg_w="N/A"; fi

OUT=$(cat <<EOF
Run started : $START
Run ended   : $END
Duration    : ${DUR}s
OS          : $(uname -sr)

CPU usage % : min $(fmt $min_c) · max $(fmt $max_c) · avg $(fmt $avg_c)
RAM used MB : min $(fmt $min_r) · max $(fmt $max_r) · avg $(fmt $avg_r)
Watts       : min ${min_w:-N/A} · max ${max_w:-N/A} · avg ${avg_w:-N/A}
EOF
)

echo "$OUT"
FILE="$RUNS/summary_${START}.txt"
echo "$OUT" > "$FILE"
echo "Saved → $FILE"
```
