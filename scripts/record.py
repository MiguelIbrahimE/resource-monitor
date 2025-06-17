#!/usr/bin/env python3
import datetime as dt, statistics as st, signal, subprocess, time, pathlib, platform, psutil

DEST = pathlib.Path.home() / "Desktop" / "resource-recorder" / "data"
DEST.mkdir(parents=True, exist_ok=True)

def ts(): return dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")

def energy_uj_linux():
    try:
        p = next(pathlib.Path("/sys/class/powercap").rglob("energy_uj"))
        return int(p.read_text())
    except Exception:
        return None

def energy_percent_mac():
    if platform.system() != "Darwin": return None
    try:
        for line in subprocess.check_output(["pmset", "-g", "batt"]).decode().splitlines():
            if "%" in line:
                return int(line.split()[2].strip(";"))
    except Exception:
        return None
    return None

read_energy = energy_uj_linux if platform.system()=="Linux" else energy_percent_mac

print("--------- Starting resource recording software ---------")
print(f"Uptime: {subprocess.getoutput('uptime')}")
print("Press Ctrl+C to stop and save summary.")
print("--------------------------------------------------------")

start_ts   = ts()
e_prev     = read_energy()
cpu_vals, mem_vals, watt_vals = [], [], []
t_prev     = time.time()

signal.signal(signal.SIGINT, lambda s, f: (_ for _ in ()).throw(KeyboardInterrupt()))

try:
    while True:
        cpu_vals.append(psutil.cpu_percent(interval=1))
        mem_vals.append(psutil.virtual_memory().used/2**20)
        e_now = read_energy()
        t_now = time.time()
        if e_prev is not None and e_now is not None and platform.system()=="Linux":
            watt = (e_now - e_prev) / 1e6 / (t_now - t_prev)
            watt_vals.append(max(watt, 0))
        e_prev, t_prev = e_now, t_now
except KeyboardInterrupt:
    pass

secs = len(cpu_vals)
cpu_stats  = (min(cpu_vals), max(cpu_vals), st.mean(cpu_vals))
mem_stats  = (min(mem_vals), max(mem_vals), st.mean(mem_vals))
watt_stats = ("N/A", "N/A", "N/A")
if watt_vals:
    watt_stats = (f"{min(watt_vals):.2f}", f"{max(watt_vals):.2f}", f"{st.mean(watt_vals):.2f}")

summary = [
    f"Run started : {start_ts}",
    f"Run ended   : {ts()}",
    f"Duration    : {secs} s",
    "",
    f"CPU usage % : min {cpu_stats[0]:.1f} · max {cpu_stats[1]:.1f} · avg {cpu_stats[2]:.1f}",
    f"RAM used MB : min {mem_stats[0]:.1f} · max {mem_stats[1]:.1f} · avg {mem_stats[2]:.1f}",
    f"Watts       : min {watt_stats[0]} · max {watt_stats[1]} · avg {watt_stats[2]}",
]

outfile = DEST / f"summary_{start_ts}.txt"
outfile.write_text("\n".join(summary), encoding="utf-8")
print("\n".join(summary))
print(f"\nSummary written to: {outfile}")
