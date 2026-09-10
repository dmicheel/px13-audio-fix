# PX13 internal audio fix + speaker EQ

Two independent parts in one repo:

- **Drivers** (`install-drivers.sh`, `module/`, `configs/`) — restores internal
  speakers (stereo) on the ASUS ProArt PX13 (dual TAS2783 SoundWire amps) on
  stock kernels >= 7.2. Required for sound at all.
- **Tuning** (`install-tuning.sh`, `tunings/`) — optional 20-band speaker
  EQ as a PipeWire filter-chain. Needs a working speaker sink (from the
  drivers part or a fixed upstream kernel), nothing else.

## Install

The drivers part requires `dkms` **preinstalled** (install it via your
package manager; the script errors out if it is missing). The tuning part
installs `lsp-plugins-lv2` automatically if needed.

```sh
bash install.sh                 # both (default)
bash install.sh --drivers-only  # speaker fix only, raw flat output
bash install.sh --tuning-only   # EQ only (needs working speakers)
```

Each part also runs standalone: `bash install-drivers.sh`,
`bash install-tuning.sh [--uninstall]`.

Runs as a regular user (asks for sudo), installs the DKMS module and the three
UCM configs, and reloads the module stack so no reboot is needed (on a fresh
machine it brings the `amdsoundwire` card up first).

## Drivers: changes vs the 7.2 `snd-soc-tas2783-sdw` driver

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

## Verify (drivers)

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

## Tuning: 20-band speaker EQ (optional)

`tunings/px13/` shapes the internal speakers with a fitted 20-band tonal
correction (~+2 dB bass/mids rolling off above 9 kHz), as a PipeWire
filter-chain sink (`PX13 Speakers`) in front of the raw speaker sink:

- **Source:** 20 reference band targets at 48 kHz, see
  `tunings/px13/eq_targets.txt`.
- **Content:** the targets fitted as 20 peaking biquads/channel at Q=0.8
  (dense RMS error 0.08 dB vs target, table in `tunings/px13/tuning.conf`),
  plus a brickwall limiter at −1 dBFS. Headphones are untouched (output
  pinned to the speaker sink).
- **Out of scope, by design:** dialog enhancement, surround virtualization,
  dynamic compression, extra loudness stages.
- **Metadata:** `tunings/px13/tuning.conf` also carries `description` and
  `sink_pattern` lines for downstream auto-install tooling; nothing in this
  repo reads them.

```sh
bash install-tuning.sh              # install + make default
bash install-tuning.sh --uninstall  # remove, restore raw default
```

A/B in your desktop audio settings (`PX13 Speakers` vs
`Audio Coprocessor Speaker`). The installer probes the chain with a 440 Hz
sine before making it default and auto-removes on a dirty result.
Small tweaks (a band or two) can be hand-edited straight into
`filter-chain.conf`; the targets live in `tunings/px13/eq_targets.txt`.
Status: math-verified only — not yet confirmed with a mic measurement.

## Layout

```text
install.sh            both parts (default) / --drivers-only / --tuning-only
install-drivers.sh    DKMS module + UCM configs (standalone)
install-tuning.sh     PipeWire speaker EQ (standalone, --uninstall supported)
module/               patched snd-soc-tas2783-sdw source (DKMS)
configs/              UCM Speaker profile + init + card override
tunings/px13/         filter-chain.conf, tuning.conf, eq_targets.txt
```

## Credits

- **ftoleedo** — original fix guide this repo builds on for stock kernels >= 7.1
- **nealstar** — original 16-patch series, including the channel-selection control this module carries
- **Andrey Golovko / Bartosz Juraszewski** — upstream tas2783 regcache resume fixes, backported here for 7.2
- **fecet** — CachyOS packaging (`linux-cachyos-px13`, `asus-proart-px13-quirks`) for the < 7.1 era
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver

## License

Guide and scripts: CC0. Kernel module: GPL-2.0 (derived from the upstream driver).
Tuning data (`tunings/px13/eq_targets.txt`, `filter-chain.conf`): functional
speaker-calibration values fitted for this chassis -- no third-party code,
binaries, blobs, or keys are redistributed.

## AI notice

Parts of this repository (scripts, UCM configs, and this README) were written
or revised with assistance from an AI coding tool, validated by hands-on
testing on the PX13. Review before use on other hardware.
