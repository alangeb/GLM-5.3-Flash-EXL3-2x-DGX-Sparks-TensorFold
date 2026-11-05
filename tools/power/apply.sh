#!/usr/bin/env bash
# apply.sh — headless debloat + GPU/CPU clock caps + display-reservation Auto, reproducibly, on one DGX Spark.
#
# WHY: decode on GB10 is memory-bound; above ~1800 MHz SM clock you buy only heat, and a P-core
# spinning at 3900 MHz is the most expensive way to wait for the GPU. Measurements + reasoning:
# docs/power-tuning-2026-11-05.md (repo root). Sources: NVIDIA forums t/387929 "Let's optimize ...
# DGX Spark" (jetspark) + peter.h177's wall sweep t/379389 + NVIDIA porting guide (Display Reserved Memory).
# Upgrade-proof: the caps are static local systemd units + EnvironmentFiles; headless is a default
# target + unit states (apt never rewrites those); the leaf purge has NO --auto-remove (that dry-run
# wanted 1078 packages: nvidia-system-station-core depends on ubuntu-desktop -> platform cascade).
#
# Usage (from this directory):
#   sudo ./apply.sh            full apply + verify
#   sudo ./apply.sh units      install/replace cap units only
#   sudo ./apply.sh headless   multi-user.target + disable/mask list (+ leaf-purge dry-run notice)
#   sudo ./apply.sh purge      execute the leaf purge (dry-run reviewed; NO autoremove by design)
#   sudo ./apply.sh dispfrm    request display reservation Auto (UEFI applies next boot)
#   ./apply.sh verify          check everything, exit 0/1 (mostly no sudo)
#   sudo ./apply.sh revert     undo: units removed + caps reset, services unmasked/enabled, graphical, 2GB
# Idempotent; re-run after an OTA that re-enables services to restore the intended state.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
UNITS=(gpu-clock-cap.service cpu-clock-cap.service)
ENVF=(gpu-clock-cap cpu-clock-cap)
GUID=284e19b9-235f-4aab-ae4c-190456d1bd76
STATUS_VAR="/sys/firmware/efi/efivars/NvidiaDispFrmStatus-$GUID"
REQUEST_VAR="/sys/firmware/efi/efivars/NvidiaDispFrmSizeRequest-$GUID"
DISABLE_LIST=(bluetooth cups cups-browsed avahi-daemon ModemManager multipathd)   # rsyslog DELIBERATELY kept: journald is volatile here, rsyslog keeps auth.log/syslog continuity
MASK_LIST=(snapd packagekit udisks2 nvidia-dgx-telemetry nvidia-dgx-sol)
LEAF_APPS=(aisleriot gnome-mahjongg gnome-mines gnome-sudoku rhythmbox totem cheese simple-scan
  transmission-gtk gnome-maps gnome-weather gnome-contacts gnome-music gnome-clocks
  nvidia-system-station-games nvidia-system-station-apps)
SUDO() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
# od -An -tu1 fields: $1-$4 attrs, $5 mode/size-request, $6-$9 size MiB little-endian
disp_read() { od -An -tu1 "$1" 2>/dev/null | awk 'NF>=5{printf "%s %s", $5, $6+$7*256; exit}'; }   # -> "mode mib"

units() {
  for f in "${ENVF[@]}"; do SUDO install -m 0644 "units/$f" "/etc/default/$f"; done
  for f in "${UNITS[@]}"; do SUDO install -m 0644 "units/$f" "/etc/systemd/system/$f"; done
  SUDO systemctl daemon-reload
  SUDO systemctl enable "${UNITS[@]}"
  SUDO systemctl restart "${UNITS[@]}"   # restart (not --now): re-run after editing /etc/default must take effect
  echo "units: $(systemctl is-active "${UNITS[@]}" | paste -sd' ')"
}
headless() {
  SUDO systemctl set-default multi-user.target
  for u in "${DISABLE_LIST[@]}"; do
    SUDO systemctl disable --now "$u.service" 2>/dev/null || true
    SUDO systemctl disable --now "$u.socket" 2>/dev/null || true   # avahi/snapd are socket-activated too
  done
  for u in "${MASK_LIST[@]}"; do SUDO systemctl stop "$u" 2>/dev/null || true; SUDO systemctl mask "$u" 2>/dev/null || true; done
  local dry; dry=$(SUDO apt-get -s purge 'libreoffice*' "${LEAF_APPS[@]}" 2>/dev/null || true)
  if grep -qE "nvidia-spark-|dgxstation-|ubuntu-desktop" <<<"$dry"; then
    echo "SKIP leaf purge: dry-run lists platform packages — do NOT purge (t/387929 warning)"
  elif grep -qE "The following packages will be REMOVED" <<<"$dry"; then
    echo "leaf purge available — run: sudo ./apply.sh purge"
  else echo "leaf purge: nothing installed to remove"; fi
}
purge() {   # leaf packages only; NO --auto-remove, NO autoremove (cascade risk, documented)
  SUDO apt-get purge -y 'libreoffice*' "${LEAF_APPS[@]}" || true
}
dispfrm() {
  [[ -e $STATUS_VAR ]] || { echo "no NvidiaDispFrmStatus var — firmware pre-OTA2610: nothing to do"; return 0; }
  local m mib; read -r m mib <<<"$(disp_read "$STATUS_VAR")"
  local req=""; [[ -e $REQUEST_VAR ]] && req=$(disp_read "$REQUEST_VAR" | awk '{print $1}')
  if [[ "$m" == 0 && -z "$req" ]]; then echo "reservation already Auto ($mib MiB)"; return 0; fi
  SUDO chattr -i "$REQUEST_VAR" 2>/dev/null || true
  printf '\x07\x00\x00\x00\x00' | SUDO tee "$REQUEST_VAR" >/dev/null
  echo "requested Auto (status was mode=$m size=${mib}MiB); UEFI applies on next boot"
}
dispfrm_back() {
  SUDO chattr -i "$REQUEST_VAR" 2>/dev/null || true
  printf '\x07\x00\x00\x00\x03' | SUDO tee "$REQUEST_VAR" >/dev/null
  echo "requested 2 GB (stock); applies on next boot"
}
verify() {
  local rc=0
  chk() { local n=$1 w=$2 g=$3; if [[ "$g" == "$w" ]]; then echo "  ok   $n: $g"; else echo "  FAIL $n: want '$w' got '$g'"; rc=1; fi; }
  echo "verify $(hostname) $(date -u +%FT%TZ):"
  chk default-target multi-user.target "$(systemctl get-default)"
  for u in "${UNITS[@]}"; do chk "$u active" active "$(systemctl is-active "$u" 2>/dev/null || true)"; done
  for c in 5 15; do chk "cpu$c scaling_max_freq" 3000000 "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq)"; done
  local sm; sm=$(nvidia-smi --query-gpu=clocks.sm --format=csv,noheader,nounits | tr -d ' ')
  chk "clocks.sm<=1800 (run loadtest.sh + nvidia-smi for the under-load check)" 1 "$([[ $sm -le 1800 ]] && echo 1 || echo 0)"
  if [[ -e $STATUS_VAR ]]; then
    local mm m mib rq; mm=$(disp_read "$STATUS_VAR"); m=${mm%% *}; mib=${mm##* }
    rq=""; [[ -e $REQUEST_VAR ]] && rq=$(disp_read "$REQUEST_VAR" | awk '{print $1}')
    if [[ "$m" != 0 && "$rq" == 0 ]]; then
      echo "  ok   dispfrm: Auto requested (status still mode=$m size=${mib}MiB until the next boot)"
    else
      chk dispfrm-mode-Auto 0 "$m"; chk dispfrm-size-MiB 512 "$mib"
    fi
  else echo "  info no NvidiaDispFrmStatus var (pre-OTA2610 firmware)"; fi
  local s
  for u in "${DISABLE_LIST[@]}"; do s=$(systemctl is-enabled "$u" 2>/dev/null || true); [[ "$s" == disabled || -z "$s" || "$s" == "masked" ]] && echo "  ok   disabled $u" || { echo "  FAIL $u: $s"; rc=1; }; done
  for u in "${MASK_LIST[@]}"; do chk "masked $u" masked "$(systemctl is-enabled "$u" 2>/dev/null || true)"; done
  awk '/MemTotal/{printf "  info MemTotal: %.1f GiB (+1.5 GiB after the dispfrm boot)\n", $2/1048576}' /proc/meminfo
  return $rc
}
revert() {
  SUDO systemctl disable --now gpu-clock-cap.service cpu-clock-cap.service 2>/dev/null || true
  SUDO nvidia-smi -rgc 2>/dev/null || true
  SUDO /usr/bin/cpupower -c 5-9,15-19 frequency-set -u 3900MHz 2>/dev/null || true
  SUDO systemctl disable power-boot-verify.service power-serve-restore.service 2>/dev/null || true
  SUDO rm -f /etc/systemd/system/gpu-clock-cap.service /etc/systemd/system/cpu-clock-cap.service /etc/systemd/system/power-boot-verify.service /etc/systemd/system/power-serve-restore.service /etc/default/gpu-clock-cap /etc/default/cpu-clock-cap
  SUDO systemctl daemon-reload
  local u
  for u in "${DISABLE_LIST[@]}"; do SUDO systemctl unmask "$u" 2>/dev/null || true; SUDO systemctl enable --now "$u.service" 2>/dev/null || true; done
  for u in "${MASK_LIST[@]}"; do SUDO systemctl unmask "$u" 2>/dev/null || true; done
  SUDO systemctl set-default graphical.target
  dispfrm_back
}
case "${1:-all}" in
  units) units; verify || true;;
  headless) headless; verify || true;;
  purge) purge;;
  dispfrm) dispfrm;;
  # The counterpart to dispfrm: option (b) of the display carve-out (see the doc). Only `revert`
  # called it until now, so the documented `apply.sh dispfrm_back` was not dispatchable.
  dispfrm_back) dispfrm_back;;
  bootverify)   # one-shot unit running verify on EVERY boot into /var/log/power-verify.log (proof of persistence)
    SUDO install -m 0644 "units/power-boot-verify.service" /etc/systemd/system/power-boot-verify.service
    [[ -x $HOME/tools-power/apply.sh ]] || echo "note: the unit expects the scp-able copy at $HOME/tools-power/apply.sh"
    SUDO systemctl daemon-reload && SUDO systemctl enable power-boot-verify.service && echo "boot verify enabled" ;;
  verify) verify;;
  serverestore)   # one-shot: brings the TP2 stack back up after a power-cycling restart (self-disables on success)
    SUDO install -m 0644 units/power-serve-restore.service /etc/systemd/system/power-serve-restore.service
    SUDO systemctl daemon-reload && SUDO systemctl enable power-serve-restore.service
    echo "serving restore enabled (runs once on the next boot; disable: sudo systemctl disable power-serve-restore)" ;;
  revert) revert;;
  all) units; headless; dispfrm; verify || true;;
  *) echo "usage: sudo ./apply.sh [all|units|headless|purge|dispfrm|dispfrm_back|verify|bootverify|serverestore|revert]"; exit 2;;
esac
