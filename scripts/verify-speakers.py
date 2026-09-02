#!/usr/bin/env python3
"""
verify-speakers.py — objectively check whether EACH internal speaker produces
sound, using the internal microphone as the measurement device (no ears
needed). Plays a short left-only tone, then a right-only tone, records the
internal DMIC, and reports the tone energy for each via a Goertzel filter.

  !!  THIS PLAYS AUDIBLE TEST TONES  !!  Don't run it next to a sleeping baby.

Why mic-loopback instead of ears: on laptops the two speakers are close
together, so ear-localisation is unreliable, and a "left/right channel" test in
software can't tell a dead amp from an unrouted channel. Measuring the acoustic
output of each channel through the mic is the objective check.

IMPORTANT gotcha this tool controls for: the playback sink volume must stay
fixed between the two measurements, or you will misread a volume change as a
dead speaker. It pins the sink volume before every play.

Requires: pipewire (pw-play), alsa-utils (arecord), python3.
"""
import math, struct, subprocess, os, wave, tempfile, time, sys, re

SR = 48000
DUR = 2.0
FREQ = 1000.0
AMP = 12000
TONE_ENERGY_FLOOR = 50.0   # below this = effectively silent


def sh(*a, **k):
    return subprocess.run(a, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True, **k).stdout


def find_soundwire_card():
    for i in range(7):
        try:
            with open(f"/proc/asound/card{i}/id") as fh:
                if re.search(r"soundwire|amd_sdw", fh.read(), re.I):
                    return i
        except OSError:
            pass
    return None


def find_dmic_device(card):
    # internal DMIC capture PCM on the soundwire card (SmartMic / rt712 aif3)
    out = sh("arecord", "-l")
    m = re.search(rf"card {card}:.*device (\d+):.*(SmartMic|rt712|DMIC|aif3)",
                  out, re.I)
    if m:
        return f"hw:{card},{m.group(1)}"
    return f"hw:{card},4"   # common default on this board


def find_speaker_sink():
    out = sh("wpctl", "status")
    # first SmartAmp / playback sink id
    for line in out.splitlines():
        if re.search(r"SmartAmp|PLAYBACK", line, re.I):
            m = re.search(r"(\d+)\.", line)
            if m:
                return m.group(1)
    return None


def make_tone(fn, chan):
    n = int(SR * DUR)
    w = wave.open(fn, "w")
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    fr = bytearray()
    for i in range(n):
        s = int(AMP * math.sin(2 * math.pi * FREQ * i / SR))
        l = s if chan == "L" else 0
        r = s if chan == "R" else 0
        fr += struct.pack("<hh", l, r)
    w.writeframes(bytes(fr)); w.close()


def goertzel(samples):
    n = len(samples)
    if not n:
        return 0.0
    k = int(0.5 + n * FREQ / SR)
    wv = 2 * math.pi * k / n
    c = 2 * math.cos(wv)
    s1 = s2 = 0.0
    for x in samples:
        s0 = x + c * s1 - s2
        s2 = s1; s1 = s0
    return ((s1 * s1 + s2 * s2 - c * s1 * s2) ** 0.5) / n


def measure(sink, dmic, wavfn):
    if sink:
        subprocess.run(["wpctl", "set-volume", sink, "1.0"],
                       stderr=subprocess.DEVNULL)
    rf = tempfile.mktemp(suffix=".wav")
    rec = subprocess.Popen(["arecord", "-q", "-D", dmic, "-f", "S16_LE",
                            "-c", "2", "-r", str(SR), "-d", "3", rf])
    time.sleep(0.4)
    play = ["pw-play"]
    if sink:
        play += ["--target", sink]
    play += [wavfn]
    subprocess.run(play, stderr=subprocess.DEVNULL)
    rec.wait()
    w = wave.open(rf)
    raw = w.readframes(w.getnframes())
    w.close(); os.unlink(rf)
    a = struct.unpack("<%dh" % (len(raw) // 2), raw)
    return goertzel(a[::2])   # left mic channel is enough


def main():
    card = find_soundwire_card()
    if card is None:
        sys.exit("No SoundWire card found — is the board supported by your "
                 "kernel? (needs mainline >= 7.3-rc1 on board 8EA1)")
    dmic = find_dmic_device(card)
    sink = find_speaker_sink()
    print(f"card={card}  dmic={dmic}  speaker-sink={sink or '(default)'}")
    print("Playing test tones (audible)...")
    make_tone("/tmp/_toneL.wav", "L")
    make_tone("/tmp/_toneR.wav", "R")
    eL = measure(sink, dmic, "/tmp/_toneL.wav")
    eR = measure(sink, dmic, "/tmp/_toneR.wav")
    print(f"LEFT  speaker  energy: {eL:9.2f}  {'OK' if eL > TONE_ENERGY_FLOOR else 'SILENT'}")
    print(f"RIGHT speaker  energy: {eR:9.2f}  {'OK' if eR > TONE_ENERGY_FLOOR else 'SILENT'}")
    if eL > TONE_ENERGY_FLOOR and eR > TONE_ENERGY_FLOOR:
        print("VERDICT: both speakers produce sound.")
    elif eL > TONE_ENERGY_FLOOR and eR <= TONE_ENERGY_FLOOR:
        print("VERDICT: RIGHT speaker silent (see docs/DIAGNOSIS.md, "
              "'Right-amp cold-boot').")
    elif eR > TONE_ENERGY_FLOOR and eL <= TONE_ENERGY_FLOOR:
        print("VERDICT: LEFT speaker silent.")
    else:
        print("VERDICT: neither channel measured — check the default sink, "
              "volume, and that firmware loaded (dmesg | grep tas2783).")


if __name__ == "__main__":
    main()
