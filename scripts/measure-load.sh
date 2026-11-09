#!/usr/bin/env bash
# Sample whole-machine load every 5 seconds for 30 seconds: CPU (user + sys),
# GPU utilization, and memory in use. Whole-machine numbers compare setups fairly
# when the video app (e.g. Chrome running Meet) is part of both.
#
#   scripts/measure-load.sh   # while a video app shows the camera
set -euo pipefail

echo "cpu_user% cpu_sys% gpu% mem_used"
for _ in 1 2 3 4 5 6; do
  # The second sample of `top -l 2` covers the interval; the first is since boot.
  cpu="$(top -l 2 -s 1 -n 0 | grep "CPU usage" | tail -1)"
  user="$(echo "$cpu" | grep -oE '[0-9.]+% user' | grep -oE '[0-9.]+')"
  sys="$(echo "$cpu" | grep -oE '[0-9.]+% sys' | grep -oE '[0-9.]+')"
  mem="$(top -l 1 -n 0 | grep PhysMem | grep -oE '[0-9]+[MG] used' | grep -oE '[0-9]+[MG]')"
  gpu="$(ioreg -r -d 1 -c IOAccelerator | grep -oE '"Device Utilization %"=[0-9]+' | head -1 | grep -oE '[0-9]+$')"
  echo "$user $sys ${gpu:-?} $mem"
  sleep 4
done
