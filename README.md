# HP OmniBook X Flip 14 (board 8EA1) — Linux audio fix

**Internal audio (speakers + mic) on the HP OmniBook X Flip 14 (DMI board `8EA1`) under Linux.**

Out of the box on this laptop, Linux gives you **HDMI audio only** — the
internal speakers are silent, the headphone jack is dead, and the internal mic
records a railed/garbage stream. The speaker amps are TI **TAS2783** and the
mic/jack is a Realtek **RT712**, both on AMD ACP **SoundWire**, which mainline
didn't support for this board until **Linux 7.3-rc1**.

This repo collects the pieces needed to get everything working, and — just as
importantly — **documents which piece fixes what**, so you can verify each step
instead of pasting commands blindly. See [`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md).

> **TL;DR**
> - On **Linux ≥ 7.3** (kernel already supports the board): run `sudo ./install.sh`, reboot. Done.
> - On an **older kernel** (only HDMI audio shows up): you need a newer kernel first — see [`docs/kernel-build-interim.md`](docs/kernel-build-interim.md) — then run `install.sh`.

## Symptoms / error messages

If you're here from a search, these are the symptoms this repo fixes on the
OmniBook X Flip 14 (board `8EA1`):

- **No sound from the internal speakers**, and the **headphone jack is dead**.
- `aplay -l` lists **HDMI outputs only** — no speaker/SoundWire playback device.
- The **internal microphone records garbage / digital silence** (a railed
  bitstream pinned at full-scale), so Whisper/voice tools transcribe nothing.
- `dmesg` shows the speaker firmware failing to load:

  ```
  Direct firmware load for 8EA1-0-0xC.bin failed with error -2
  ... error playback without fw download
  ```

That combination is the AMD SoundWire / TAS2783 + RT712 support gap addressed
below.

## Is this your machine?

This is written for the **HP OmniBook X Flip 14** whose DMI **board is `8EA1`**
(the 16-inch sibling is `8EA2`). Confirm with one command:

```bash
cat /sys/class/dmi/id/board_name     # must print: 8EA1
```

Exact hardware this was developed against:

| | |
|---|---|
| Model | HP OmniBook X Flip Laptop **14-kc0xxx** |
| Product family | `103C_5335M8 HP OmniBook X` |
| **DMI board** | **`8EA1`** (16" sibling = `8EA2`) |
| SoC | AMD **Ryzen AI 5 430** w/ Radeon 840M (Strix Point) |
| Audio co-processor | AMD **ACP 7.0** — PCI `1022:15e2` (rev 72) |
| Speaker amps | 2× TI **TAS2783** on SoundWire **link 0**, UIDs **`0x9`** and **`0xC`** (`sdw:0:0:0102:0000:01:9` / `…:c`) |
| Mic + headphone jack | Realtek **RT712** (SDCA) on SoundWire **link 1** (`sdw:0:1:025d:0712:01`) |
| BIOS (tested) | `F.06` (2026-04-17) |
| Tested kernel | mainline **7.3-rc1** |
| Tested firmware | `linux-firmware` 20260810 |

**Broken fingerprint (before any fix):** `aplay -l` shows **HDMI only**; the
internal mic (a legacy ACP PDM card, e.g. `acp-pdm-mach`) records a **railed**
bitstream (samples pinned at ±full-scale).

**Working fingerprint (after fix, kernel ≥ 7.3-rc1):** a `amd-soundwire` card
appears with —

```
card 1: amdsoundwire [amd-soundwire], device 2: SDW0-PIN1-PLAYBACK-SmartAmp   (speakers)
card 1: amdsoundwire [amd-soundwire], device 4: SDW1-PIN5-CAPTURE-SmartMic    (internal mic)
card 1: amdsoundwire [amd-soundwire], device 0: SDW1-PIN0-PLAYBACK-SimpleJack (headphone jack)
```

Other `14-kc0xxx` / `8EA1` units should match; different board strings (e.g.
`8EA2`) may need different firmware names — file an issue with your
`board_name`, `uname -r`, `linux-firmware` version, and `aplay -l`/`arecord -l`.

## What actually needs fixing

Three separate layers, three separate fixes:

| Symptom | Layer | Handled by |
|---|---|---|
| Only HDMI audio; speakers/jack dead; mic railed | **kernel** | mainline **≥ 7.3-rc1** (8EA1 DMI quirk + ACP70 SoundWire topology, merged upstream) |
| Speakers still silent; dmesg: `Direct firmware load for 8EA1-0-0xC.bin failed` | **firmware filename** | `install.sh` — symlinks the 3-field name the driver asks for to the 4-field blob `linux-firmware` ships |
| Internal mic records digital silence | **mixer default** | `install.sh` — unmutes the RT712 SDCA capture switches and saves the state |

The kernel part is upstream, so once your distro ships Linux 7.3 you need **no
custom kernel** — only the two userspace fixes in `install.sh`.

## Requirements

- HP OmniBook X Flip 14 (`cat /sys/class/dmi/id/board_name` → `8EA1`).
- Linux **≥ 7.3** stock, *or* a self-built mainline ≥ 7.3-rc1 kernel
  (see [`docs/kernel-build-interim.md`](docs/kernel-build-interim.md)).
- `linux-firmware` (ships the TAS2783 blobs), `alsa-utils` (`amixer`,
  `alsactl`). PipeWire/WirePlumber for routing.

## Install

```bash
git clone https://github.com/sansscott/omnibook-x-flip-14-8ea1-linux-audio
cd omnibook-x-flip-14-8ea1-linux-audio
sudo ./install.sh
sudo reboot        # firmware is only requested at boot-time probe
```

`install.sh` is idempotent and:

1. Creates the TAS2783 **firmware symlinks** (3-field → 4-field names) so the
   amps get their firmware.
2. **Unmutes** the RT712 SDCA capture switches (the internal-mic fix) and
   `alsactl store`s the state so it survives reboot.

It resolves the sound card and controls **by name**, not by fragile numeric IDs,
and it warns (rather than breaking) if the board or kernel isn't what it expects.

After reboot, set your PipeWire default **source** to the internal DMIC
(SmartMic / rt712 capture node) if it isn't already.

> Note: the firmware symlinks live in `/usr/lib/firmware`, so a `linux-firmware`
> package update can wipe them. If the speakers go silent after an update, just
> re-run `sudo ./install.sh`.

## Verify

`scripts/verify-speakers.py` measures each speaker **objectively** through the
internal mic (Goertzel tone detection) — useful because the two speakers are too
close together to judge by ear.

```bash
python3 scripts/verify-speakers.py     # ⚠ plays audible test tones
```

Mic-only check (silent):

```bash
arecord -D hw:<card>,<dmic> -f S16_LE -c2 -r48000 -d2 /tmp/m.wav
# rms well above zero with ambient sound = mic works; railed/zero = still broken
```

## Known open issue — right speaker silent after cold boot (UNVERIFIED)

On at least one unit, the **left** speaker works but the **right** TAS2783 amp
is silent from a cold boot, even though firmware loaded and its mixer state is
*identical* to the (working) left amp. Because the mixer state matches, the cause
is below the ALSA control layer (SoundWire port-prepare / codec reattach).

A simple volume-bounce did **not** reliably fix it in controlled testing, so no
"fix" is shipped for this. `experimental/omnibook-amp-wake.sh` +
`systemd/omnibook-amp-wake.service` try a broader set of control bounces at
login but are **unverified** — enable only if it demonstrably helps you, and
please open an issue with your kernel + findings. Details and the correct way to
test (pin the sink volume; don't isolate-by-mute) are in
[`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md#right-amp-cold-boot-open--unverified).

## Contributing

Issues and PRs welcome — especially data points on the right-amp cold-boot
behavior across different units, kernels, and firmware versions. Please include
`uname -r`, `cat /sys/class/dmi/id/board_name`, the `linux-firmware` version,
and `verify-speakers.py` output.

## License

MIT — see [LICENSE](LICENSE).

## Credits

The kernel support for this board (8EA1 DMI quirk + ACP70 SoundWire topology +
TAS2783 SDCA codec work) was done by the upstream Linux audio developers and
merged for Linux 7.3-rc1. This repo only packages the remaining userspace
workarounds and documents the diagnosis.
