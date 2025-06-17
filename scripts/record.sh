#!/usr/bin/env bash
set -euo pipefail
##############################################################################
# helper functions
##############################################################################
fmt() { printf "%.1f" "$1"; }
now() { date -u "+%Y-%m-%d_%H-%M-%S"; }
min() { awk -v a="$1" -v b="$2" 'BEGIN{print (a<b)?a:b}'; }
max() { awk -v a="$1" -v b="$2" 'BEGIN{print (a>b)?a:b}'; }

##############################################################################
# per-OS probes
##############################################################################
case "$(uname -s)" in
##########################################################################
# macOS / Darwin
##########################################################################
Darwin*)
  CORES=$(sysctl -n hw.logicalcpu)

  cpu() { ps -A -o %cpu | awk -v c="$CORES" 'NR>1{s+=$1} END{printf "%.2f",s/c}'; }

  ram() { vm_stat | awk '
      /page size of/      {pg=$8}
      /^Pages active/      {a=$3}
      /^Pages inactive/    {i=$3}
      /^Pages speculative/ {s=$3}
      END{printf "%.2f",(a+i+s)*pg/1048576}' ; }

  watts() {   # returns SoC-level power in W, or empty string on failure
    command -v powermetrics >/dev/null 2>&1 || true
    local total

    # 1️⃣ modern M-series: cpu/gpu/ane/dram samplers (mW → W)
    total=$(powermetrics -s cpu_power,gpu_power,ane_power,dram_power \
                         -n1 -i1000 2>/dev/null |
            awk '/Power:/ && /mW/ {gsub(/[^0-9.]/,""); s+=$3}
                 END{if(s>0) printf "%.2f", s/1000}') || true
    [[ $total ]] && { printf "%s" "$total"; return; }

    # 2️⃣ early M1 wording (Average total power, already W)
    total=$(powermetrics -n1 -i1000 2>/dev/null |
            awk '/Average.*total.*power/ {gsub(/[^0-9.]/,""); print; exit}') || true
    [[ $total ]] && { printf "%.2f" "$total"; return; }

    # 3️⃣ Intel Macs (smc sampler, W)
    total=$(powermetrics -s smc -n1 -i1000 2>/dev/null |
            awk '/CPU Power:/ {gsub(/[^0-9.]/,"",$3); print $3; exit}') || true
    [[ $total ]] && { printf "%.2f" "$total"; return; }

    # 4️⃣ Battery fallback (draw = |current| × voltage, in W)
    total=$(ioreg -rn AppleSmartBattery 2>/dev/null |
            awk '/"Amperage"/{a=$3}/"Voltage"/{v=$3}
                 END{if(a&&v) printf "%.2f", (a<0?-a:a)*v/1000000}') || true
    [[ $total ]] && printf "%s" "$total"
  }

  BOOT_SEC=$(( $(date +%s) \
             - $(sysctl -n kern.boottime | awk -F'[ =,]+' '{print $3}') ))
  ;;

##########################################################################
# Linux
##########################################################################
Linux*)
  CORES=$(nproc)

  read_stat() { awk '{for(i=2;i<=NF;i++) s+=$i; print s,$5}' /proc/stat; }
  PRE=($(read_stat))
  cpu() {
    CUR=($(read_stat)); sleep 0.05
    local T=$((CUR[0]-PRE[0])); local I=$((CUR[1]-PRE[1])); PRE=("${CUR[@]}")
    awk -v i="$I" -v t="$T" 'BEGIN{printf "%.2f",(1-i/t)*100}'
  }

  ram() { awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}
               END{printf "%.2f",(t-a)/1024}' /proc/meminfo; }

  rapl() { local e=0
           for f in /sys/class/powercap/intel-rapl:*/energy_uj; do
             [[ -r $f ]] && read -r v <"$f" && e=$((e+v))
           done; echo "$e"; }
  R0=$(rapl); T0=$(date +%s%N)
  watts() {
    local R1=$(rapl) T1=$(date +%s%N)
    (( R1 > R0 )) || return 1
    awk -v dE="$((R1-R0))" -v dT="$((T1-T0))" \
        'BEGIN{printf "%.2f",(dE/1e6)/(dT/1e9)}'
    R0=$R1; T0=$T1
  }

  BOOT_SEC=$(awk '{print int($1)}' /proc/uptime)
  ;;

##########################################################################
# Unknown OS
##########################################################################
*)  cpu(){ echo 0; }; ram(){ echo 0; }; watts(){ return 1; }; BOOT_SEC=0 ;;
esac

##############################################################################
# banner
##############################################################################
UP_FMT=$(awk -v S="$BOOT_SEC" 'BEGIN{
  d=int(S/86400); S-=d*86400; h=int(S/3600); S-=h*3600; m=int(S/60);
  printf "%dd %02dh %02dm\n",d,h,m}')
echo "--------- Starting resource recording software ---------"
echo "Uptime      : $UP_FMT"
echo "Press Ctrl+C once and wait ~1 s for the summary."
echo "--------------------------------------------------------"

##############################################################################
# main loop
##############################################################################
trap 'STOP=1' INT

min_c=1000 max_c=0 sum_c=0
min_r=1e9  max_r=0 sum_r=0
min_w=1e9  max_w=0 sum_w=0 cnt_w=0
energy_j=0
cnt=0
START=$(now); T0=$(date +%s)

while [[ -z ${STOP:-} ]]; do
  C=$(cpu || echo 0); [[ -z $C ]] && C=0
  R=$(ram || echo 0); [[ -z $R ]] && R=0
  W=$(watts 2>/dev/null || echo)

  min_c=$(min "$min_c" "$C"); max_c=$(max "$max_c" "$C")
  sum_c=$(awk -v s="$sum_c" -v v="$C" 'BEGIN{print s+v}')

  min_r=$(min "$min_r" "$R"); max_r=$(max "$max_r" "$R")
  sum_r=$(awk -v s="$sum_r" -v v="$R" 'BEGIN{print s+v}')

  if [[ $W ]]; then
    min_w=$(min "$min_w" "$W"); max_w=$(max "$max_w" "$W")
    sum_w=$(awk -v s="$sum_w" -v v="$W" 'BEGIN{print s+v}')
    energy_j=$(awk -v e="$energy_j" -v v="$W" 'BEGIN{print e+v}')
    ((cnt_w++))
  fi
  ((cnt++))
  sleep 1 || true
done

END=$(now); DUR=$(( $(date +%s) - T0 ))
avg_c=$(awk -v s="$sum_c" -v n="$cnt"   'BEGIN{print s/n}')
avg_r=$(awk -v s="$sum_r" -v n="$cnt"   'BEGIN{print s/n}')

if ((cnt_w)); then
  avg_w=$(awk -v s="$sum_w" -v n="$cnt_w" 'BEGIN{printf "%.2f", s/n}')
  energy_wh=$(awk -v j="$energy_j" 'BEGIN{printf "%.3f", j/3600}')
  w_min=$(fmt "$min_w"); w_max=$(fmt "$max_w")
else
  avg_w="N/A"; w_min="N/A"; w_max="N/A"; energy_wh="N/A"
fi

##############################################################################
# summary
##############################################################################
cat <<EOF
Run started : $START
Run ended   : $END
Duration    : ${DUR}s
OS          : $(uname -sr)

CPU usage % : min $(fmt "$min_c") · max $(fmt "$max_c") · avg $(fmt "$avg_c")
RAM used MB : min $(fmt "$min_r") · max $(fmt "$max_r") · avg $(fmt "$avg_r")
Power (W)   : min $w_min · max $w_max · avg $avg_w
Energy used : $energy_wh Wh
EOF
