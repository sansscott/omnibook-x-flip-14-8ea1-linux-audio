# Diagnosis — internal audio on the HP OmniBook X Flip 14 (board 8EA1)

This documents *why* internal audio is broken out of the box on this laptop and
exactly what fixes each piece, so you can verify each step rather than
cargo-culting commands.

## Hardware

- **Board:** `8EA1` (`/sys/class/dmi/id/board_name`). The 16-inch sibling is
  `8EA2`.
- **SoC:** AMD Ryzen AI (Strix Point), **ACP 7.0** audio co-processor.
- **Speakers:** two **TI TAS2783** smart amps on **SoundWire link 0**
  (unique IDs `0x9` and `0xC`).
- **Mic + headphone jack:** **Realtek RT712** (SDCA) on **SoundWire link 1**;
  the internal DMIC is exposed as an rt712 capture path.

## The three problems and their layers

| Symptom | Layer | Fix |
|---|---|---|
| Only HDMI audio; no speakers, no jack, mic is a railed bitstream | **kernel** | board not scanned for SoundWire until the 8EA1 support that landed in mainline **7.3-rc1** |
| Speakers still silent after the kernel is fixed; dmesg shows `Direct firmware load for 8EA1-0-0xC.bin failed` | **firmware filename** | symlink 3-field → 4-field names (`install.sh` step 1) |
| Internal mic records digital silence (rms 0) | **mixer default** | rt712 SDCA capture switches default to **muted**; unmute + save (`install.sh` step 2) |

### 1. Kernel — the board wasn't scanned (fixed upstream in 7.3-rc1)

On kernels before this support, `snd_amd_acp_find_config()` returns the ACPI
"legacy DMIC only" flag for board 8EA1, so the SoundWire links are **never
scanned**. Result: the TAS2783 amps never bind (no Speaker/Headphone PCM), the
SOF/SoundWire modules load but never bind, and a legacy ACP PDM card exposes a
**railed** (pinned at ±full-scale) fake mic. This is one root cause for both no
output *and* the broken mic.

The support (DMI quirk for `8EA1`/`8EA2` + the ACP70 SoundWire topology for the
TAS2783 pair on link 0 and RT712 on link 1) is in:

- `sound/soc/amd/acp-config.c` — DMI table entry for `8EA1`
- `sound/soc/amd/acp/amd-acp70-acpi-match.c` — the ACP70 topology / machine row
- `sound/soc/codecs/tas2783-sdw.c` — TAS2783 SDCA codec

It merged for **Linux 7.3-rc1**. Confirm your tree actually has it before
building:

```bash
grep -n '8EA1' sound/soc/amd/acp-config.c
```

If you are on a distro kernel older than 7.3 and only HDMI enumerates, you
need a newer kernel first — see [kernel-build-interim.md](kernel-build-interim.md).
Once Linux 7.3 ships in your distro's stock kernel, no custom kernel is needed
at all — only the two userspace fixes below.

### 2. Firmware filename mismatch (speakers)

`linux-firmware` ships the TAS2783 blobs for this board as **4-field** names:

```
/usr/lib/firmware/ti/audio/tas2783/8EA1-0-0-0x9.bin.zst
/usr/lib/firmware/ti/audio/tas2783/8EA1-0-0-0xC.bin.zst
```

but the driver requests **3-field** names at boot-time probe:

```
8EA1-0-0x9.bin   /   8EA1-0-0xC.bin
```

so the first boot logs `Direct firmware load for 8EA1-0-0xC.bin failed` and the
amps run "playback without fw download" → silence. The fix is a symlink from
the requested (3-field) name to the shipped (4-field) blob:

```
/usr/lib/firmware/8EA1-0-0x9.bin.zst -> ti/audio/tas2783/8EA1-0-0-0x9.bin.zst
/usr/lib/firmware/8EA1-0-0xC.bin.zst -> ti/audio/tas2783/8EA1-0-0-0xC.bin.zst
```

Firmware is only requested at the **boot-time probe** — rebinding the codec does
not re-trigger it, so you must **reboot** after creating the symlinks.
`install.sh` creates these; they live in `/usr/lib/firmware`, so a
`linux-firmware` package update can remove them — re-run `install.sh` if the
speakers go silent after an update.

### 3. Internal mic defaults to muted (SDCA capture switch)

Even with the kernel and firmware right, the internal DMIC records **digital
silence** (rail fraction ~0, rms 0) because the rt712 **SDCA capture switches
default to muted**. Unmute them and save:

```bash
# names, not numids (numids differ across machines/kernels):
#   'rt712 FU1E Capture Switch'  -> on   (the DMIC path)
#   'rt712 FU0F Capture Switch'  -> on   (headset/mic2 path)
#   'rt712 FU15 Boost Volume'    -> 1
#   'rt712 FU44 Boost Volume'    -> 1
alsactl store   # persist via alsa-restore
```

Then set your PipeWire default **source** to the internal DMIC node (SmartMic /
rt712 capture), not the legacy PDM card if it still appears.

## Right-amp cold-boot (OPEN / UNVERIFIED)

On at least one unit, after the kernel + firmware + mixer fixes, the **left**
speaker plays but the **right** TAS2783 amp appears **acoustically silent from a
cold boot** — while the ALSA mixer state for the right amp is *identical* to the
left (both `Right/Left Spk Switch` = on, both `Speaker Volume` = 200, both
`Amp Volume` = 9). Because the mixer state is identical, whatever differs is
below the ALSA control layer (SoundWire port-prepare / codec cache-on-reattach),
not something a saved mixer captures.

A previously-suspected fix — bouncing the right `Speaker Volume` control 0→full —
did **not** reliably restore output in controlled mic-loopback testing, so it is
**not** shipped as a fix. `experimental/omnibook-amp-wake.sh` tries a broader
set of control bounces but is **unverified**; enable it only if it demonstrably
works for you, and please report back.

**Caveat when testing this yourself:** keep the playback sink volume fixed
between measurements — a volume change mid-test reads exactly like a dead
speaker. `scripts/verify-speakers.py` pins the sink volume before every play for
this reason. Also: isolating one amp by muting the other *bounces* the amp under
test, which can mask the very state you are trying to observe — prefer a
single-channel tone with both amps untouched.

## How to verify objectively (no ears)

See `scripts/verify-speakers.py` — it plays a left-only then right-only tone,
records the internal mic, and reports the tone energy per channel via a Goertzel
filter. **It plays audible tones.**

Mic check without playing anything:

```bash
arecord -D hw:<card>,<dmic> -f S16_LE -c2 -r48000 -d2 /tmp/m.wav
# rms should be well above zero with ambient sound; a railed/zero stream = mic still broken
```
