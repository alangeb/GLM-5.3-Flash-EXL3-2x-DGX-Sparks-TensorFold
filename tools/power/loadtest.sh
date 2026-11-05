#!/usr/bin/env bash
# loadtest.sh — short GPU + P-core load so caps can be verified under load (idle SM can read high).
# Run in one shell; in another: nvidia-smi --query-gpu=clocks.sm --format=csv,noheader and
# cat /sys/devices/system/cpu/cpu17/cpufreq/scaling_cur_freq   (must sit at/below 1800 MHz / 3000 MHz).
set -euo pipefail
T=${1:-8}
IMAGE=${IMAGE:-tensorfold-glm53-spark:74e19a63a9a5}
docker run --rm --gpus all "$IMAGE" python -c "
import time, torch
a = torch.randn(8192, 8192, device='cuda')
t0 = time.time()
while time.time() - t0 < $T:
    for _ in range(20): a @ a
    torch.cuda.synchronize()
" &
DLP=$!
yes > /dev/null & YP=$!
sleep "$((T + 2))"
kill $YP 2>/dev/null || true; wait $DLP 2>/dev/null || true
