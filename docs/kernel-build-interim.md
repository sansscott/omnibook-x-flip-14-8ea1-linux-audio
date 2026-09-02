# Interim: building a kernel with 8EA1 support (only until your distro ships 7.3)

You only need this if your **stock kernel predates the 8EA1 support** (i.e. only
HDMI audio enumerates and there is no SoundWire/`amd_sdw` card). The support is
in mainline **7.3-rc1**, so once your distro's stock `linux` reaches 7.3 this
whole page is obsolete — just install `omnibook-audio-fix` and reboot.

Until then, build a **mainline >= 7.3-rc1 kernel as a SECOND kernel package**,
keeping your stock kernel installed as a fallback. Do **not** replace your
distro's `linux` package.

The notes below are for an Arch-based system with the Limine bootloader, but the
principles port to any distro: build 7.3-rc1+ vanilla, install it alongside
stock, boot it.

## Arch-based (custom `pkgbase`, keep stock kernel)

1. **Get a mainline >= 7.3-rc1 PKGBUILD.** Start from the AUR `linux-mainline`
   PKGBUILD once it tracks >= 7.3-rc1, or copy the Arch `linux` PKGBUILD and
   point `source` at a 7.3-rc1+ tarball. Set a distinct `pkgbase`, e.g.
   `linux-omnibook`, so it installs **alongside** stock `linux`. Do **not** set
   `provides=('linux')`.

2. **Use a local tarball, not a git clone, on a WiFi-only laptop.** A full
   `git clone` of the kernel tree can saturate a marginal WiFi link and make the
   machine unreachable mid-build. Download the tarball on a wired machine and
   copy it over:

   ```bash
   curl -fL -o linux-<ver>.tar.gz \
     https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-<ver>.tar.gz
   ```

   Point the PKGBUILD's `source`/`_srcname` at it and set `sha256sums=SKIP` for
   that entry.

3. **Config:** use a version-matched distro config (the config shipped with the
   mainline PKGBUILD, or `make olddefconfig` from your running config). Ensure
   the audio stack is enabled: `SND_SOC_TAS2783_SDW`, `SND_AMD_ASOC_ACP70`,
   `SND_AMD_ACP_CONFIG`, `SOUNDWIRE_AMD`, `SND_SOC_SDCA`, `SND_SOC_RT712_SDCA`,
   plus whatever your root needs (LUKS/dm-crypt, btrfs, nvme, amdgpu, and
   `CONFIG_RUST=y` if the config expects it).

4. **Confirm the fix is actually in the source before compiling:**

   ```bash
   grep -n '8EA1' sound/soc/amd/acp-config.c
   ```

5. **Build with limited parallelism on a 16 GB laptop:** `MAKEFLAGS="-j4"`
   (not `-j$(nproc)`), and don't run a browser/other heavy compile at the same
   time.

6. **Install the new packages only** (`linux-omnibook` + `-headers`); keep stock
   `linux` installed. Your bootloader should now list both.

7. **Bootloader default:** leave stock as the default until you've confirmed the
   new kernel boots and audio works, then optionally make the new kernel the
   default so you don't pick it every boot. On Limine that's the
   `default_entry:` index in `/boot/limine.conf` (entries are 1-indexed in menu
   order). Keep a backup of `limine.conf` and keep the stock entry selectable.

8. **After first boot into the new kernel:** run `sudo ./install.sh` from this
   repo (firmware symlinks + mic unmute), then reboot once more so the firmware
   symlinks are picked up at probe time.

## Notes / gotchas

- **Kernel signing keys:** fetching the mainline signing key may require WKD:
  `gpg --auto-key-locate wkd --locate-external-key torvalds@kernel.org`.
- **Never** `pacman -R linux` to "clean up" — that removes your fallback kernel.
- **Do not restart `systemd-logind`** on a live graphical session to apply
  anything — it tears down your Wayland/X session and closes your windows. Apply
  such changes via a drop-in that takes effect next boot.
- This custom kernel is **temporary**. Retire it once your distro's stock
  kernel is 7.3.x with the 8EA1 quirk: boot stock, confirm the `amd_sdw` card +
  speakers/mic work, then remove the custom `pkgbase` and restore the stock
  boot default. Keep the two userspace fixes (`install.sh`) — the firmware
  naming and mic-mute defaults are independent of the kernel.
