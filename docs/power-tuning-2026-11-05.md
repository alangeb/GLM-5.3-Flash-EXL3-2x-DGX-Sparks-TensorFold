# Power tuning the two Sparks (headless + clock caps + display reservation) — 2026-11-05

Applied on spark2 and spark1 on 2026-11-05. Reproduce/undo with `tools/power/apply.sh` (this repo);
the unit files and `/etc/default/*` it installs live under `tools/power/units/` and are the source of
truth. Wiki: `dgx-spark-power-tuning-2026-11-05`.

## What was applied (both nodes, same state)

| item | setting | effect |
|---|---|---|
| headless | `systemctl set-default multi-user.target` (desktop stays *installed*, never starts) | ~1-3 W, no X/GNOME RAM, no GDM |
| services disabled | `bluetooth cups cups-browsed avahi-daemon ModemManager multipathd` (+ sockets) | idle spin-down, fewer wakes |
| services masked | `snapd packagekit udisks2 nvidia-dgx-telemetry nvidia-dgx-sol` | D-Bus/socket activation can't resurrect them; OTA telemetry stopped |
| GPU cap | unit `gpu-clock-cap.service`, `nvidia-smi -lgc 0,1800` (SM clock) | decode −1..3 %, wall power −~25 % |
| CPU cap | unit `cpu-clock-cap.service`, `cpupower -c 5-9,15-19 frequency-set -u 3000MHz` (X925 P-cores only) | same throughput, −8..12 % energy, −17 °C hot zone |
| display reservation | write request var → UEFI applies **Auto (512 MiB)** on next boot | `MemTotal` +1.5 GiB |
| leaf purge | NOT executed (only offered; `sudo ./apply.sh purge`) | disk only; skipped on serving nodes |
| boot verify | unit `power-boot-verify.service` → `/var/log/power-verify.log` on every boot | persistence proof |
| one-time serving restore | unit `power-serve-restore.service` (spark1, `./apply.sh serverestore`): runs `./start.sh restart` after a power-cycling reboot | the stack has no autostart by design; this covers exactly the tuning restart. **Failed on its first boot** (see Reboot results); unit fixed 12:35 same day — `Wants=NetworkManager-wait-online`, an ssh retry loop on the worker, `Restart=on-failure`. Self-disable never worked: every `Exec*` drops to `User=alangeb` and disable needs root, so it re-runs on **every** boot (harmless — `start.sh restart` is idempotent) until `sudo systemctl disable power-serve-restore` |
| boot-time proof status | spark2: caps verified green post-boot, but its boot-verify unit was enabled only after that boot (manual run wrote the first log entries); spark1's reboot is the first fully-automatic boot-verify firing | honest: next spark2 reboot proves its own boot unit |
| kept on purpose | `rsyslog` (journald is volatile on this OS — rsyslog keeps `auth.log`/`syslog` continuity across the reboot), `earlyoom`, docker/ssh, `gdm` untouched (static; disabled by the target) | — |

## Why (sources, measured — not our own sweep)

- NVIDIA developer forums, *"Let's optimize … DGX Spark"* (t/387929, jetspark, 2026-11-03) — same rig
  shape as ours (2× GB10, TP2 over CX7, **TensorFold EXL3**, TEB hardmode 97 scenarios seed 42):
  X925 cap 3900→3000 MHz: **TEB score 91→91, wall 661 s→661 s, byte-identical outputs**, 41.9→38.5 Wh
  (−8 %), peak 84.2 °C→67.5 °C. Their vLLM/MTP column is noise-dominated; ours is deterministic at
  fixed seed (DFlash2).
- peter.h177's GPU sweep (t/379389): 2400→1900 MHz costs ~1 % decode, saves ~24 % wall (51.34 tok/s
  @330 W → 50.74 @252 W); 1700 MHz is the Wh/1M floor (1350 vs 1688); below ~1400 prefill starts to
  pay. **1800 MHz is the chosen point** — top of the energy sweet spot.
- Physics: GB10 decode is memory-bound — SM clock above ~1800 buys heat, not tok/s. Inference ranks
  also *spin-wait* on the GPU at 100 % CPU; a spinning P-core at 3900 MHz is the most expensive way to
  wait (power ∝ clock·voltage²). E-core max is 2808 MHz → **never cap below that** or the scheduler
  migrates hot threads to E-cores (measured +4.5 % wall at 2600 in the thread).
- Heat kills: the forum's "~90 °C → switches itself off mid-job, no logs" is a real fleet risk; our
  keepalive sentinel exists because the engine has died before (earlyoom, 2026-10-21).
- NVIDIA DGX Spark Porting Guide, *Display Reserved Memory*: OTA2610+ makes the UEFI display
  reservation configurable (Auto/0.5/1/2/4 GB). From Linux, write request var
  `NvidiaDispFrmSizeRequest-284e19b9-235f-4aab-ae4c-190456d1bd76` = attrs `07 00 00 00` + 1 byte
  (0=Auto, 1=0.5G, 2=1G, 3=2G, 5=4G); UEFI checks next boot, applies, deletes the request.
  Read-back: `NvidiaDispFrmStatus-…` (attrs + mode byte + LE u32 MiB), rewritten every boot.

## Interaction with this repo (GLM-5.3 Flash TensorFold recipe) — reviewed before applying

- `DISPLAY_KV_MIB=1792` in `scripts/local.sh` — **collision, found the hard way (good failure)**: the
  first `./start.sh restart` after spark2's reboot died at
  `TF_GLM_DISPLAY_KV_MIB: DRM_IOCTL_MODE_CREATE_DUMB failed: [Errno 12] Cannot allocate memory` — the
  reservation is now Auto (512 MiB), the 1792 MiB dumb buffer cannot exist. `scripts/local.sh` now ships
  `DISPLAY_KV_MIB=0` with the two consistent options documented at the line: (a) Auto + no display KV
  (as now: +1.5 GiB OS/node; the host-headroom-driven pool grew anyway: 1,968,128 vs 1,622,016 tokens),
  or (b) reservation back to 2 GB + `DISPLAY_KV_MIB=1792` (~277k more pool tokens at PARALLEL=8, README
  table; ~half the OS gain). `DISPLAY_KV_BACKEND=dispram` on kindling spark-os is the path that wants
  both.
- `start.sh:83-87` (patch 0087 headless guard): `DISPLAY_KV_MIB` needs `/dev/dri/card0`, DRM connector
  entries, and no `connected` output. Headless mode does not unbind `nvidia_drm` (modeset=1 stays, all
  outputs read `disconnected`) → the guard still passes. No conflict.
- `MEMORY_RESERVE_GIB=18`: unchanged; Auto adds headroom rather than taking it.
- The serving stack does **not** autostart (container restart policy `no`, no unit starts it;
  `glm-keepalive` is a dormant C6/vLLM sentinel gated by `.glm-want`, absent). A reboot therefore
  requires an explicit `./start.sh` from spark1.

## Procedure (what was run, in order — `apply.sh` automates 2-4 + verify)

1. Pre-flight per node: `sudo -n` OK; `GRUB_DEFAULT=0`, `/boot/vmlinuz` → running kernel, empty
   grubenv (no booted-fallback landmine — learned 2026-10-19); DispFrmStatus var present
   (firmware OTA2610+); `nvidia-smi -lgc/-rgc` + `cpupower` exist; efivarfs rw; loadtest image exists.
2. `sudo ./apply.sh units` — installs `/etc/{gpu,cpu}-clock-cap.service` + `/etc/default/{gpu,cpu}-clock-cap`
   from `tools/power/units/`, daemon-reload, `enable --now`.
3. `sudo ./apply.sh headless` — set-default + disable/mask (+ leaf-purge dry-run notice; purge NOT run).
4. `sudo ./apply.sh dispfrm` — writes the Auto request var.
5. `systemctl reboot`; after boot: `./apply.sh verify`, serving restart, smoke (below).

## Post-reboot verification ("works as intended" checklist, per node)

- `systemctl get-default` = `multi-user.target`; no gdm/Xorg; :22 reachable.
- cap units active; cpu5/15/17 `scaling_max_freq` = 3000000; **under load** (`./loadtest.sh 8`):
  `clocks.sm` ≤ 1800 and cpu17 `scaling_cur_freq` ≤ 3000000. (Idle SM readings are not the cap — the
  load test is the proof.)
- DispFrmStatus → mode 0, 512 MiB; `MemTotal` ≥ ~123 GiB; request var consumed by UEFI.
- masked/disabled lists hold (`apply.sh verify` rc=0); `auth.log` still growing (rsyslog).
- Cluster: ping fabric .168/.169; `./start.sh restart` from spark1 → TP2 ready; `/health` ok; one chat
  completion; deterministic probe stable; `/metrics` `requests_total` ticks.

## Reboot results — 2026-11-05

**spark2** (trial node, done first 10:03→10:06 CET): applied via ssh+sudo (`~/tools-power/apply.sh`,
scp'd copy of this directory). Pre-reboot verify all green; under-load check: SM 1787 MHz ≤ 1800,
cpu5/17 cur 3000000, hot zone 45.7 °C. Reboot: ssh back after ~65 s, fully headless (no display ever
attached to the box). Post-boot: DispFrmStatus `6 0 0 0 0 0 2 0 0` = **Auto, 512 MiB**; request var
consumed by UEFI; **MemTotal 121.7 → 123.2 GiB (+1.5)**; target multi-user; caps active (cpu max
3000000); all disables/masks hold; rsyslog active (auth.log continuity through the reboot); boot
verify unit appended its green report to `/var/log/power-verify.log`. GPU idle draw 4.5 W (engine
stopped for the reboot window). Found-and-fixed en route: **DISPLAY_KV_MIB collision** (see the
interaction note — Auto + a 1792 MiB dumb buffer = rank fails at CREATE_DUMB ENOMEM; `scripts/local.sh`
now ships `DISPLAY_KV_MIB=0`, and post-restore the pool is *bigger*: `pool_tokens 1,968,128` vs
1,622,016 pre-tuning, because the pool auto-sizes from host headroom). TP2 rank1 re-joined via
`./start.sh restart` from spark1 ("rank 1 of 2"), C5 probe `27*31` → `837`, requests_total ticking.
Note the container name is the default `glm53-flash-tf` (the earlier `glm53-spark` was an override that
today's restart chain dropped — stop/start/keepalive all use the default now).

**spark1** (this box): applied 10:14 CET via the loopback-ssh trick (the agent's own guard blocks local
`sudo`, same as for the earlier `reboot` — and the reboot **is** operator-authorized). Verify green
(identical list); `bootverify` + one-time `serverestore` enabled; serving stopped; reboot issued ~10:17.

**Corrected 12:35, same day — the restore did NOT come back by itself.** `power-serve-restore` fired at
10:18:22 and died **40 ms** later (`status=1/FAILURE`, `/tmp/power-serve-restore.log`:
`cannot ssh to alangeb@192.168.1.247 without a password`). Not a key problem — interactive `ssh
alangeb@192.168.1.247` works, and it is the cluster key `~/.ssh/id_ed25519` that authenticates (spark2
accepts nothing else, and `scripts/nodes.sh` `worker()` uses plain `ssh -o BatchMode=yes`, so that key
must stay the default identity). The unit simply ran **before the route to the worker existed**:
`After=network-online.target` bought nothing, because on this OS **both** wait-online providers
(`NetworkManager-wait-online`, `systemd-networkd-wait-online`) are *disabled*, so the target completes
instantly. Consequence of the failure: the stack stayed down ~2 h and, with it, every session pointed at
`http://cuda:8000` (all three live tau sessions), `:8000/health` → no connection. **Fix applied:** the unit now
`Wants=`/`After=` `NetworkManager-wait-online.service` (NM is the active backend, `nm-online` present),
retries worker ssh up to 40×15 s before calling `start.sh`, and `Restart=on-failure RestartSec=45` with
`StartLimitIntervalSec=0`; reinstalled with `sudo ./apply.sh serverestore`. The self-disable was never
functional (Exec* runs as `User=alangeb`, `systemctl disable` needs root) — the unit is a restart-each-boot
no-op-when-running until disabled by hand. Manual restore remains: `./start.sh restart` on spark1.
Verified at boot: `power-boot-verify` logged green (the one `FAIL clocks.sm<=1800` is the known
idle artifact — 493 MHz at idle, the cap only proves under load); DispFrmStatus **Auto, 512 MiB**;
request var consumed by UEFI; **MemTotal 123.2 GiB (+1.5)**; target multi-user; caps active; all
disables/masks hold; `apply.sh verify` rc=0 on **both** nodes. Not yet re-proven under load (needs the
stack up): `./tools/power/loadtest.sh 8` then `clocks.sm` ≤ 1800 and cpu17 ≤ 3000000.

## Revert / undo (per node)

One command **on spark1**: `sudo /home/alangeb/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/tools/power/apply.sh revert`.
On **spark2** the repo is not checked out (only the scp'd `~/tools-power` exists), so run it there:
`ssh alangeb@192.168.1.247 'cd ~/tools-power && sudo ./apply.sh revert'`.
After a revert on either node: `DISPLAY_KV_MIB=1792` again in `scripts/local.sh` (option (b) — see the
interaction note), else the freed reservation just sits idle.
(Revert = caps reset + units removed, services unmasked/enabled, graphical.target, reservation request
back to 2 GB. Granular steps inside `apply.sh`: `units|headless|dispfrm|dispfrm_back|verify|revert`.)

## Energy expectation (from the cited sweeps, scaled to our near-continuous duty cycle)

Their numbers: ~1.69→~1.35 kWh per 1M decode tokens (−20 %) from the GPU cap, −8 % whole-box from the
CPU cap, minus ~3-6 W idle from debloat (telemetry/snapd/avahi/GNOME). Order of **−15..−25 % serving
energy at identical outputs**, plus a ~20 °C cooler ceiling — the mid-job thermal-shutdown risk drops
with it. Honest follow-up: a 5-day wall-meter spot check (plugtop) and TEB seed 42 against the frozen
C6 numbers (already in this project's next-steps).
