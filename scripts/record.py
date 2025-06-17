#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Universal “resource-recorder”
–––––––––––––––––––––––––––––
• Streams   CPU %, RAM (MB) and, when possible, instantaneous Watts
• Adapts    automatically to Linux, macOS or Windows
• Stores    one plain-text summary per run inside
            ~/Desktop/resource-recorder/runs/
"""

from __future__ import annotations

import json
import os
import platform
import signal
import statistics as stats
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional, Sequence

# ───────────────────────── prerequisites ─────────────────────────
try:
    import psutil                # tiny, pure-python – install once with pip
except ImportError:
    print("Please run:  pip install --user psutil")
    sys.exit(1)

# ───────────────────────── output folders ────────────────────────
BASE_DIR = Path.home() / "Desktop" / "resource-recorder"
RUN_DIR  = BASE_DIR / "runs"
RUN_DIR.mkdir(parents=True, exist_ok=True)

# ───────────────────────── helpers ───────────────────────────────
def fmt(n: float | str, unit: str = "", nd: int = 1) -> str:
    if isinstance(n, str):
        return n
    return f"{n:.{nd}f} {unit}".rstrip()

def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M-%S")

def human_uptime(seconds: int) -> str:
    d, seconds = divmod(seconds, 86_400)
    h, seconds = divmod(seconds, 3_600)
    m, s       = divmod(seconds, 60)
    parts = []
    if d: parts.append(f"{d}d")
    if h: parts.append(f"{h}h")
    if m: parts.append(f"{m}m")
    parts.append(f"{s}s")
    return " ".join(parts)

# ─────────────────────── power back-ends ─────────────────────────
def _rapl_joules_linux() -> Optional[int]:
    """Current RAPL package energy in µJ summed over all sockets."""
    base = Path("/sys/class/powercap")
    if not base.exists():
        return None
    total = 0
    for pkg in base.glob("intel-rapl:*"):
        try:
            total += int((pkg / "energy_uj").read_text())
        except Exception:
            continue
    return total or None

# --- replace the whole _powermetrics_watts_mac function -----------------
def _powermetrics_watts_mac() -> Optional[float]:
    """
    Instantaneous package Watts on macOS.

    • Tries `--samplers smc -f json` (newer macOS/Apple Silicon).
    • If that fails, falls back to plain-text parsing.
      Works on both Intel and Apple Silicon, needs sudo rights.
    """
    base_cmd = ["sudo", "-n", "powermetrics", "-n1", "-i200"]

    # 1) JSON path (fast, self-contained)
    try:
        out = subprocess.check_output(
            base_cmd + ["--samplers", "smc", "-f", "json"],
            stderr=subprocess.DEVNULL,
            timeout=1.0,
            text=True,
            )
        data = json.loads(out[out.find("{"):])
        return float(data["smc"]["package_watts"])
    except Exception:
        pass  # fall through to text parsing

    # 2) Plain-text parsing (works on older CLI or missing JSON flag)
    try:
        out = subprocess.check_output(
            base_cmd + ["--samplers", "smc"],
            stderr=subprocess.DEVNULL,
            timeout=1.0,
            text=True,
            )
        for line in out.splitlines():
            line = line.strip()
            if not line or "W" not in line:
                continue
            if any(key in line.lower() for key in
                   ("cpu power", "processor power", "package power", "pkg power")):
                # first number that looks like “3.12” or “3120”
                for token in line.split():
                    try:
                        return float(token.replace("W", ""))
                    except ValueError:
                        continue
    except Exception:
        pass

    return None

def _battery_watts_windows() -> Optional[float]:
    """
    Rough power draw on Windows laptops from battery discharge rate.
    Needs a battery and may be 0 when on mains; returns None if unsupported.
    """
    try:
        batt = psutil.sensors_battery()
        if not batt or batt.power_plugged or batt.secsleft in (psutil.POWER_TIME_UNLIMITED, psutil.POWER_TIME_UNKNOWN):
            return None
        capacity_wh =  batt._asdict().get("energy_full", None)    # on some builds
        if capacity_wh is None:
            return None
        # W ≈ remaining Wh / secsleft
        return capacity_wh * (batt.percent / 100) / (batt.secsleft / 3600)
    except Exception:
        return None

def make_watts_reader() -> Callable[[], Optional[float]]:
    sysname = platform.system()
    if sysname == "Linux":
        last_j = _rapl_joules_linux()
        last_t = time.time()

        def _linux() -> Optional[float]:
            nonlocal last_j, last_t
            j = _rapl_joules_linux()
            if j is None or last_j is None:
                return None
            t = time.time()
            w = max((j - last_j) / (t - last_t) / 1e6, 0.0)   # µJ → W
            last_j, last_t = j, t
            return w
        return _linux

    if sysname == "Darwin":
        return _powermetrics_watts_mac

    if sysname == "Windows":
        return _battery_watts_windows

    return lambda: None        # fallback

get_watts = make_watts_reader()

# ───────────────────────── main loop ─────────────────────────────
cpu_hist: list[float] = []
ram_hist: list[float] = []
w_hist  : list[float] = []

start_ts = timestamp()
boot_s   = int(time.time() - psutil.boot_time())

print("--------- Starting resource recording software ---------")
print(f"Uptime      : {human_uptime(boot_s)}")
print("Press Ctrl+C to stop and save summary.")
print("--------------------------------------------------------")

running = True
def _stop(_sig, _frm):
    global running
    running = False
signal.signal(signal.SIGINT, _stop)

while running:
    cpu_hist.append(psutil.cpu_percent(interval=0.8))
    ram_hist.append(psutil.virtual_memory().used / 1024**2)     # MB
    w = get_watts()
    if w is not None:
        w_hist.append(w)

# ───────────────────────── summarise ────────────────────────────
end_ts  = timestamp()
duration_s = int(
    datetime.strptime(end_ts,   "%Y-%m-%d_%H-%M-%S").timestamp() -
    datetime.strptime(start_ts, "%Y-%m-%d_%H-%M-%S").timestamp()
)

def _stats(xs: Sequence[float]) -> tuple[str, str, str]:
    return fmt(min(xs)), fmt(max(xs)), fmt(stats.mean(xs))

cpu_min, cpu_max, cpu_avg = _stats(cpu_hist)
ram_min, ram_max, ram_avg = _stats(ram_hist)
if w_hist:
    w_min,  w_max,  w_avg  = _stats(w_hist)
else:
    w_min = w_max = w_avg = "N/A"

summary = f"""\
Run started : {start_ts}
Run ended   : {end_ts}
Duration    : {duration_s} s
OS          : {platform.system()} {platform.release()}

CPU usage % : min {cpu_min} · max {cpu_max} · avg {cpu_avg}
RAM used MB : min {ram_min} · max {ram_max} · avg {ram_avg}
Watts       : min {w_min} · max {w_max} · avg {w_avg}
"""

print("\n" + summary.strip())

file_path = RUN_DIR / f"summary_{start_ts}.txt"
file_path.write_text(summary, encoding="utf-8")
print(f"Saved → {file_path}")
