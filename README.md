# PX13 internal audio fix

Restores the internal speakers on the ASUS ProArt PX13 (HN7306EA / HN7306EAC,
AMD Strix Halo / ACP70, dual TAS2783 SoundWire amps) on stock kernels.

Two problems are fixed:

1. **Mono-only output** — the mainline `snd-soc-tas2783-sdw` driver lacks a
   per-amp channel control, and the PX13 ACPI tables carry no usable SDCA
   cluster data, so both amps program the same cluster and only one channel
   renders.
2. **No audio after s2idle/hibernate** — the TAS2783 DSP firmware does not
   survive suspend; the amplifier comes back silent (or the SoundWire card
   wedges WirePlumber's graph and takes Bluetooth audio with it).

Tested on `linux-cachyos 7.1.6-1`.

## What was modified vs upstream

`module/` is mainline `sound/soc/codecs/tas2783-sdw.c` (same revision as in
7.1.6) with these changes:

| Change | Why |
|---|---|
| Added `Channel Playback` enum (Off/Left/Right) per amp, mapped to the SDCA UDMPU cluster-index register | UCM assigns `tas2783-1 = Left`, `tas2783-2 = Right` for stereo on the PX13 |
| Removed `tas25xx_register_misc` / `tas25xx_deregister_misc` calls | No misc class device from this driver |
| Firmware filename `%04X-%1X-0x%1X.bin` (added `0x` before the SDCA unique ID) | Matches the per-device calibration firmware referenced by the PX13 ACPI table |

`tas2783.h` is unmodified upstream.

## How it works

- **Kernel module (DKMS)** — the patched driver above, installed as
  `snd-soc-tas2783-sdw-px13`. DKMS rebuilds it automatically after every
  kernel update.
- **UCM configs** — make the HiFi profile expose a `Speaker` device on the
  `amdsoundwire` card and set the per-amp channel mapping:
  - `px13-longname-override.conf` forces `SpeakerCodec = tas2783` (the card
    is announced without the `spk:tas2783` tag on mainline, which otherwise
    leaves the profile with no Speaker port and PipeWire on a dummy sink).
    It is placed under `conf.d/amd-soundwire/` named after the CardLongName,
    so it is loaded before the default config and owned by no package.
  - `sof-soundwire_tas2783.conf` defines the Speaker device (channel mapping,
    playback PCM/mixer).
  - `codecs_tas2783_init.conf` remaps the two amps' volume controls into one
    Speaker volume and attaches the speaker LED.
- **Resume recovery** — `50-px13-soundwire` (systemd-sleep post hook) starts
  `px13-soundwire-recover.sh` as a detached transient unit (running it inline
  would block resume with the session frozen). The recovery:
  1. unbinds the ACP PCI device and unloads/reloads the SoundWire/ACP module
     stack — the re-probe re-downloads the amp firmware and re-enumerates the
     codecs (waits up to 20 s for `Attached`);
  2. restarts the session `pipewire`/`wireplumber`/`pipewire-pulse`;
  3. restores the HiFi card profile, unmutes the speaker, and makes it the
     default sink only when no other default exists (keeps Bluetooth).

## Install

Requires `dkms` (e.g. `pacman -S dkms`).

```sh
bash install.sh
```

Runs as a regular user (asks for sudo), and installs: the DKMS module, the
three UCM configs, the sleep hook, and the recovery script. A live module
reload is attempted so no reboot is needed; if that fails, reboot.

## Components

| File (repo) | Installed to | Purpose |
|---|---|---|
| `module/` | `/usr/src/snd-soc-tas2783-sdw-px13-1.0` (DKMS) | patched `snd-soc-tas2783-sdw` driver |
| `configs/px13-longname-override.conf` | `/usr/share/alsa/ucm2/conf.d/amd-soundwire/<CardLongName>.conf` | forces the tas2783 speaker codec |
| `configs/sof-soundwire_tas2783.conf` | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Speaker device + channel mapping |
| `configs/codecs_tas2783_init.conf` | `/usr/share/alsa/ucm2/codecs/tas2783/init.conf` | stereo volume remap, LED |
| `50-px13-soundwire` | `/usr/lib/systemd/system-sleep/` | post-resume hook, dispatches recovery detached |
| `px13-soundwire-recover.sh` | `/usr/local/lib/` | module reload + audio stack restart + HiFi restore |

## Verify

```sh
# both channel controls present (expect 2)
amixer -D hw:0 controls | grep -c "Channel Playback"

# codecs attached
for d in /sys/bus/soundwire/devices/sdw:0:1:*; do
  echo "$(basename "$d"): $(cat "$d/status")"
done

# stereo test tone (Front Left then Front Right)
speaker-test -D pulse -c 2 -l 1 -t wav
```

## Troubleshooting

- **No audio after suspend/hibernate** — run `sudo /usr/local/lib/px13-soundwire-recover.sh`; recovery logs to `/var/log/px13-soundwire-resume.log`.
- **Channels swapped** — swap the two `cset` lines in `sof-soundwire_tas2783.conf` (1<->2), then `systemctl --user restart pipewire wireplumber`.
- **No `Channel Playback` control** — the DKMS module is not loaded; check `modinfo snd_soc_tas2783_sdw -F filename` (must point into `updates/dkms/`).

## Credits

- **ftoleedo** — original fix guide this repo builds on for stock kernels >= 7.1
- **nealstar** — original 16-patch series, including the channel-selection control this module carries
- **fecet** — CachyOS packaging (`linux-cachyos-px13`, `asus-proart-px13-quirks`) for the < 7.1 era
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from the upstream driver).

## AI notice

Parts of this repository (scripts, UCM configs, and this README) were written
or revised with assistance from an AI coding tool, validated by hands-on
testing on the PX13. Review before use on other hardware.
