#!/usr/bin/env bash
#
# EXPERIMENTAL / UNVERIFIED — right-amp cold-boot wake.
#
# On some units the RIGHT TAS2783 amp is acoustically silent after a cold boot
# even though firmware loaded and the mixer state (switches on, volumes up) is
# identical to the working left amp. This helper attempts to "wake" the right
# amp by bouncing its controls after the audio stack is up.
#
# STATUS: the simplest bounce (toggling the right Speaker Volume 0 -> full) has
# NOT been reliably shown to fix it in controlled testing. This script tries a
# few things in sequence; treat it as a starting point, not a proven fix. If it
# works for you, please open an issue describing your exact hardware + kernel.
#
# It plays NO audio. It only toggles mixer controls.
#
set -euo pipefail

find_card() {
  local i
  for i in $(seq 0 6); do
    if [[ -r /proc/asound/card$i/id ]] && grep -qiE 'soundwire|amd_sdw' "/proc/asound/card$i/id" 2>/dev/null; then
      echo "$i"; return 0
    fi
  done
  return 1
}

card="$(find_card || true)"
[[ -n "$card" ]] || { echo "no soundwire card" >&2; exit 0; }

numid_by_name() { amixer -c "$card" controls 2>/dev/null | grep -iF "name='$1'" | grep -oE 'numid=[0-9]+' | cut -d= -f2 | head -1; }

# Right-amp controls (names are stable across boots on a given kernel; numids
# are resolved fresh each run so this survives kernel updates).
rvol="$(numid_by_name 'tas2783-2 Speaker Volume')"
ramp="$(numid_by_name 'tas2783-2 Amp Volume')"
rsw1="$(numid_by_name 'Right Spk Switch')"
rsw2="$(numid_by_name 'Right Spk2 Switch')"

bounce_int() { local id="$1" hi="$2"; [[ -n "$id" ]] || return 0; amixer -c "$card" cset numid="$id" 0 >/dev/null 2>&1 || true; sleep 0.3; amixer -c "$card" cset numid="$id" "$hi" >/dev/null 2>&1 || true; }
bounce_sw()  { local id="$1"; [[ -n "$id" ]] || return 0; amixer -c "$card" cset numid="$id" off >/dev/null 2>&1 || true; sleep 0.2; amixer -c "$card" cset numid="$id" on >/dev/null 2>&1 || true; }

bounce_sw  "$rsw1"
bounce_sw  "$rsw2"
bounce_int "$ramp" 9
bounce_int "$rvol" 200

echo "omnibook-amp-wake: bounced right-amp controls (card $card)"
