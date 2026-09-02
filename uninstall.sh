#!/usr/bin/env bash
#
# omnibook-audio-fix — remove the firmware symlinks this project created.
# The mic-unmute ALSA state is left in place (it is harmless and is your saved
# mixer state); reset it yourself with `alsactl restore` from a fresh boot if
# you really want to revert it.
#
set -euo pipefail

FW_DIR="/usr/lib/firmware"
TAS_SUBDIR="ti/audio/tas2783"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo ./uninstall.sh)" >&2; exit 1; }

board="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo 8EA1)"
removed=0
shopt -s nullglob
for link in "$FW_DIR/${board}"-*-0x*.bin.zst; do
  # only remove symlinks we would have made (3-field name pointing into $TAS_SUBDIR)
  if [[ -L "$link" && "$(readlink "$link")" == "$TAS_SUBDIR/"* ]]; then
    base="$(basename "$link")"
    # skip 4-field names shipped by linux-firmware (A-B-C-0xD)
    if [[ "$base" =~ ^[0-9A-Fa-f]+-[0-9]+-[0-9]+-0x ]]; then continue; fi
    rm -f "$link"; echo "removed $base"; removed=$((removed+1))
  fi
done
shopt -u nullglob
echo "done (removed $removed symlink(s))."
