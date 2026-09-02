#!/usr/bin/env bash
#
# omnibook-audio-fix — userspace fixes for internal audio on the
# HP OmniBook X Flip 14 (DMI board 8EA1): TAS2783 speaker amps + RT712
# mic/jack on AMD ACP SoundWire.
#
# This script applies the two USERSPACE fixes that are still needed on top of
# a kernel that already supports this board (mainline >= 7.3-rc1, where the
# 8EA1 DMI quirk + ACP70 SoundWire topology landed):
#
#   1. TAS2783 firmware filename symlinks (driver requests 3-field names,
#      linux-firmware ships 4-field names) — otherwise the speakers get no
#      firmware and stay silent.
#   2. RT712 SDCA capture-switch unmute — the internal DMIC defaults to muted,
#      so the mic records digital silence until these switches are enabled.
#
# It does NOT build a kernel. If you are on kernel < 7.3 and the board is not
# yet supported (only HDMI audio enumerates), see docs/kernel-build-interim.md.
#
# Idempotent. Safe to re-run.
#
set -euo pipefail

EXPECTED_BOARD="8EA1"
FW_DIR="/usr/lib/firmware"
TAS_SUBDIR="ti/audio/tas2783"

log()  { printf '  %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh) — it writes to $FW_DIR and ALSA state"

# ---------------------------------------------------------------------------
# 0. Sanity: right board, right kernel era
# ---------------------------------------------------------------------------
board="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
if [[ "$board" != "$EXPECTED_BOARD" ]]; then
  warn "DMI board is '$board', not '$EXPECTED_BOARD'."
  warn "This fix is written for the OmniBook X Flip 14 (8EA1). Continuing anyway,"
  warn "but the firmware names below may not match your hardware."
fi

kver="$(uname -r)"
log "kernel: $kver"
if ! aplay -l 2>/dev/null | grep -qiE 'sof|soundwire|amd_sdw|SmartAmp|tas2783'; then
  warn "No SoundWire/SOF playback device is enumerated yet."
  warn "Your kernel probably predates 8EA1 support (needs mainline >= 7.3-rc1)."
  warn "See docs/kernel-build-interim.md before this fix can help. Continuing to"
  warn "lay down the firmware symlinks anyway (harmless)."
fi

# ---------------------------------------------------------------------------
# 1. TAS2783 firmware filename symlinks (3-field -> 4-field)
#
# The driver requests e.g.  <BOARD>-0-0x9.bin  /  <BOARD>-0-0xC.bin
# linux-firmware ships       <BOARD>-0-0-0x9.bin.zst / ...-0-0-0xC.bin.zst
# Create the 3-field name as a symlink to the shipped 4-field blob.
# ---------------------------------------------------------------------------
log ""
log "[1/2] TAS2783 firmware symlinks"
made=0
shopt -s nullglob
for blob in "$FW_DIR/$TAS_SUBDIR/${board}"-*-*-0x*.bin.zst; do
  base="$(basename "$blob")"                     # e.g. 8EA1-0-0-0x9.bin.zst
  # strip the third numeric field:  A-B-C-0xD  ->  A-B-0xD
  short="$(sed -E 's/^([0-9A-Fa-f]+-[0-9]+)-[0-9]+-(0x[0-9A-Fa-f]+\.bin\.zst)$/\1-\2/' <<<"$base")"
  [[ "$short" != "$base" ]] || continue
  link="$FW_DIR/$short"
  target="$TAS_SUBDIR/$base"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    log "already linked: $short"
  else
    ln -sfn "$target" "$link"
    log "linked: $short -> $target"
    made=$((made+1))
  fi
done
shopt -u nullglob
if [[ $made -gt 0 ]]; then
  ok "firmware symlinks created ($made new) — reboot needed (firmware is only requested at boot-time probe)"
else
  ok "firmware symlinks already in place"
fi

# ---------------------------------------------------------------------------
# 2. RT712 SDCA capture-switch unmute (the internal-mic fix)
#
# Resolve the SoundWire card by name and unmute the capture switches by
# CONTROL NAME (numids are not stable across machines/kernels).
# ---------------------------------------------------------------------------
log ""
log "[2/2] RT712 capture unmute (internal mic)"
card=""
for i in $(seq 0 6); do
  if [[ -r /proc/asound/card$i/id ]] && grep -qiE 'soundwire|amd_sdw' "/proc/asound/card$i/id" 2>/dev/null; then
    card=$i; break
  fi
done
[[ -n "$card" ]] || card="$(aplay -l 2>/dev/null | grep -iE 'soundwire|amd_sdw|SmartAmp' | grep -oE 'card [0-9]+' | head -1 | grep -oE '[0-9]+' || true)"

if [[ -z "$card" ]]; then
  warn "could not find the SoundWire card — skipping mic unmute."
  warn "(re-run after booting a kernel that enumerates the amd-soundwire card)"
else
  log "SoundWire card: $card ($(cat /proc/asound/card$card/id 2>/dev/null))"
  # Enable every rt712 capture switch; set the boost volumes if present.
  changed=0
  while IFS= read -r numid; do
    amixer -c "$card" cset numid="$numid" on >/dev/null 2>&1 && changed=$((changed+1)) || true
  done < <(amixer -c "$card" controls 2>/dev/null | grep -iE "rt712.*Capture Switch" | grep -oE 'numid=[0-9]+' | cut -d= -f2)
  while IFS= read -r numid; do
    amixer -c "$card" cset numid="$numid" 1 >/dev/null 2>&1 || true
  done < <(amixer -c "$card" controls 2>/dev/null | grep -iE "rt712.*Boost Volume" | grep -oE 'numid=[0-9]+' | cut -d= -f2)
  ok "unmuted $changed rt712 capture switch(es)"

  # Persist so it survives reboot (alsa-restore).
  if command -v alsactl >/dev/null 2>&1; then
    alsactl store >/dev/null 2>&1 && ok "saved ALSA state (alsactl store)" || warn "alsactl store failed — enable alsa-restore.service"
  else
    warn "alsactl not found — install alsa-utils so the unmute persists across reboot"
  fi
fi

log ""
ok "done."
log "If speakers were just given firmware for the first time, reboot once."
log "Set your PipeWire default source to the internal DMIC (the SmartMic /"
log "rt712 capture node) in your audio settings if it isn't already."
log ""
log "Known open issue on some units: the RIGHT speaker can be silent after a"
log "cold boot even when firmware + mixer look correct. See docs/DIAGNOSIS.md"
log "(section 'Right-amp cold-boot') and experimental/ for a work-in-progress"
log "wake helper — currently UNVERIFIED, off by default."
