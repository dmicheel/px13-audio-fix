# PX13 internal audio fix

Restores internal speakers (stereo) on the ASUS ProArt PX13 (dual TAS2783
SoundWire amps) on stock kernels >= 7.2.

## Changes vs the 7.2 `snd-soc-tas2783-sdw` driver

**7.2 fix (still needed):**

- Added `Channel Playback` enum (Off/Left/Right) per amp. The PX13 ACPI tables
  carry no usable SDCA cluster data, so both amps program the same cluster;
  this control lets UCM assign Left/Right for stereo.

**Backported from 7.3 (upstream resume/regcache fixes):**

- `tas2783_writeable_register` — read-only Controls aren't written back on sync.
- `regcache_drop_region` on re-attach — drop the stale cache after a
  power-gated suspend instead of syncing it (the cause of silent speakers
  after s2idle resume).
- `regcache_sync` error handling on resume.
- `tas2783_reg_default[]` sorted + deduplicated.

`tas2783.h` is unmodified upstream.

## Install

Requires `dkms`.

```sh
bash install.sh
```

Runs as a regular user (asks for sudo), installs the DKMS module and the three
UCM configs, and reloads the module stack so no reboot is needed (on a fresh
machine it brings the `amdsoundwire` card up first).

## Verify

```sh
# both channel controls present (expect 2)
amixer -c amdsoundwire controls | grep -c "Channel Playback"

# stereo test tone (Front Left then Front Right)
speaker-test -D pulse -c 2 -l 1 -t wav
```

## Troubleshooting

- **Channels swapped** — swap the two `cset` lines in
  `sof-soundwire_tas2783.conf` (1<->2), then restart PipeWire.
- **No `Channel Playback` control** — the DKMS module isn't loaded; check
  `modinfo snd_soc_tas2783_sdw -F filename` (must point into `updates/dkms/`).

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
