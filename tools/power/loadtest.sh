#!/usr/bin/env bash
# loadtest.sh — short GPU + P-core load so caps can be verified under load (idle SM can read high,
# and it can read LOW too: 1787 MHz at 6.5 W is not the cap holding, so this load is the proof).
# Run in one shell; in another: nvidia-smi --query-gpu=clocks.sm --format=csv,noheader and
# cat /sys/devices/system/cpu/cpu17/cpufreq/scaling_cur_freq   (must sit at/below 1800 MHz / 3000 MHz).
#
# 2026-11-05: the original used `docker run … tensorfold-glm53-spark:74e19a63a9a5 python -c …` and died
# at `exec: python: not found` — that build tool image ships no python at all. The load now runs in the
# CONTAINER ALREADY SERVING (it has python3 + torch + the GPU attached), so the load test works on a live
# node and needs no image; pass a container name as $2. If it isn't running, the GPU half is skipped with
# a clear note rather than pretending to have tested.
set -euo pipefail
T=${1:-8}
C=${2:-glm53-flash-tf}
if ! docker inspect "$C" >/dev/null 2>&1; then
  echo "no container $C to load the GPU with (pass its name as \$2; the P-core half still runs)"; C=""
fi
if [[ -n "$C" ]]; then
  docker exec -i "$C" python3 - "$T" <<'PY' &
import sys, time, torch
t = int(sys.argv[1])
a = torch.randn(4096, 4096, device='cuda')
t0 = time.time()
while time.time() - t0 < t:
    for _ in range(20):
        a @ a
    torch.cuda.synchronize()
PY
  DLP=$!
else
  DLP=""
fi
yes > /dev/null & YP=$!
sleep "$((T + 2))"
kill $YP 2>/dev/null || true
[[ -z "$DLP" ]] || { wait $DLP 2>/dev/null || true; }
