# PX13 internal audio fix

Restores the internal speakers on the ASUS ProArt PX13 (HN7306EA / HN7306EAC,
AMD Strix Halo / ACP70, dual TAS2783 SoundWire amps) on stock kernels >= 7.2.

Two problems are fixed:

1. **Mono-only output** — the mainline `snd-soc-tas2783-sdw` driver lacks a
   per-amp channel control, and the PX13 ACPI tables carry no usable SDCA
   cluster data, so both amps program the same cluster and only one channel
   renders.
2. **No audio after s2idle/hibernate** — the driver re-downloads the TAS2783
   DSP firmware on resume but then syncs back a stale register cache, so later
   register writes are skipped and the amp stays silent. Fixed by the
   backported regcache fix below.

Tested on `linux-cachyos 7.2.0-1`.

## What was modified vs upstream

`module/` is mainline `sound/soc/codecs/tas2783-sdw.c` (7.2) with these changes:

| Change | Why |
|---|---|
| Added `Channel Playback` enum (Off/Left/Right) per amp, mapped to the SDCA UDMPU cluster-index register | UCM assigns `tas2783-1 = Left`, `tas2783-2 = Right` for stereo on the PX13 |
| Backported 3 suspend/resume fixes from 7.3 | See below |

Backported from the 7.3 driver (these landed upstream after 7.2):

- **`tas2783_writeable_register`** — marks latency-control / power-state /
  protection registers read-only so `regcache_sync()` doesn't write them back
  and abort the sync.
- **`regcache_drop_region` on re-attach** — after a power-gated suspend the
  device loses register/DSP state; the stale cache is dropped instead of being
  synced back (which would corrupt subsequent read-modify-write updates and
  leave the amp silent after resume).
- **`regcache_sync` error handling on resume** — if the sync fails, the cache
  is marked dirty and the error is propagated instead of being ignored.

The other two fixes carried by earlier versions of this module are now handled
upstream as of 7.2 and were dropped:

- **misc class device removal** — upstream removed the
  `tas25xx_register_misc`/`tas25xx_deregister_misc` calls entirely.
- **firmware `0x` prefix** — upstream now tries `%04X-%1X-0x%1X.bin` first and
  falls back to the non-prefixed name if the calibration firmware is absent.

`tas2783.h` is unmodified upstream (7.2).

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
    Speaker volume.

## Install

Requires `dkms` (e.g. `pacman -S dkms`).

```sh
bash install.sh
```

Runs as a regular user (asks for sudo), and installs: the DKMS module and the
three UCM configs. It does not assume the `amdsoundwire` card already exists:
on a fresh machine it reloads the SoundWire/ACP module stack so the card comes
up, then derives the unit-specific UCM override name from the live card
(falling back to a default if the card is not present yet). A live module
reload is attempted so no reboot is needed; if that fails, reboot.

## Components

| File (repo) | Installed to | Purpose |
|---|---|---|
| `module/` | `/usr/src/snd-soc-tas2783-sdw-px13-1.0` (DKMS) | patched `snd-soc-tas2783-sdw` driver |
| `configs/px13-longname-override.conf` | `/usr/share/alsa/ucm2/conf.d/amd-soundwire/<CardLongName>.conf` | forces the tas2783 speaker codec |
| `configs/sof-soundwire_tas2783.conf` | `/usr/share/alsa/ucm2/sof-soundwire/tas2783.conf` | Speaker device + channel mapping |
| `configs/codecs_tas2783_init.conf` | `/usr/share/alsa/ucm2/codecs/tas2783/init.conf` | stereo volume remap |

## Verify

```sh
# both channel controls present (expect 2)
amixer -c amdsoundwire controls | grep -c "Channel Playback"

# codecs attached
for d in /sys/bus/soundwire/devices/sdw:0:1:*; do
  echo "$(basename "$d"): $(cat "$d/status")"
done

# stereo test tone (Front Left then Front Right)
speaker-test -D pulse -c 2 -l 1 -t wav
```

## Troubleshooting

- **Channels swapped** — swap the two `cset` lines in `sof-soundwire_tas2783.conf` (1<->2), then `systemctl --user restart pipewire wireplumber`.
- **No `Channel Playback` control** — the DKMS module is not loaded; check `modinfo snd_soc_tas2783_sdw -F filename` (must point into `updates/dkms/`).

## Credits

- **ftoleedo** — original fix guide this repo builds on for stock kernels >= 7.1
- **nealstar** — original 16-patch series, including the channel-selection control this module carries
- **Andrey Golovko / Bartosz Juraszewski** — upstream tas2783 regcache resume fixes, backported here for 7.2
- **fecet** — CachyOS packaging (`linux-cachyos-px13`, `asus-proart-px13-quirks`) for the < 7.1 era
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from the upstream driver).

## AI notice

Parts of this repository (scripts, UCM configs, and this README) were written
or revised with assistance from an AI coding tool, validated by hands-on
testing on the PX13. Review before use on other hardware.
