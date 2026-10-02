# PX13 internal audio fix + speaker EQ

Two independent parts in one repo:

- **Drivers** (`install-drivers.sh`, `module/`, `configs/`) — restores internal
  speakers (stereo) on the ASUS ProArt PX13 (dual TAS2783 SoundWire amps) on
  stock kernels >= 7.2. On 7.2.x it installs a DKMS backport of the 7.3
  driver fixes; on 7.3+ the stock driver already has them and only the UCM
  configs are installed.
- **Tuning** (`install-tuning.sh`, `tunings/`) — optional 20-band speaker EQ
  as a WirePlumber software-DSP replacement. Needs a working speaker sink
  (from the drivers part or a fixed upstream kernel) and WirePlumber 0.5+.

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

Runs as a regular user (asks for sudo), installs the DKMS modules (7.2.x
only) and the three UCM configs, and reloads the module stack so no reboot is
needed (on a fresh machine it brings the `amdsoundwire` card up first).

## Drivers: what the 7.2 DKMS module carries

Do you still need it? Only on 7.2.x. Mainline 7.3 contains every fix below;
`dkms.conf` has `BUILD_EXCLUSIVE_KERNEL="^7\.2\."`, so DKMS skips 7.3+ kernels
and the stock modules load.

The module is stable 7.2.8 `snd-soc-tas2783-sdw` and `snd-soc-sdw-utils`
with these upstream 7.3 commits applied unchanged:

- `tas2783-sdw: split a stereo stream across the two mono amps` — each amp
  takes one channel instead of both playing the same one. This is what
  makes the speakers stereo; no UCM control is involved.
- `tas2783-sdw: power the Function up before preparing the port` — fixes
  silent speakers after s2idle when a stream is re-prepared.
- `sdw_utils: prepare the stream again when resuming` — the same for
  streams restarted with `snd_pcm_resume()` (built as `snd-soc-sdw-utils`).
- `tas2783-sdw: do not treat read-only Controls as writable` — lets
  `regcache_sync()` finish on resume.

The other 7.3 resume/regcache fixes (stale-cache drop on re-attach,
`regcache_sync()` error propagation, sorted register defaults) are already
in stable 7.2.8. 7.2.y stable updates to these two files would be shadowed by
the DKMS copy; compare against `git log v7.2.8.. -- sound/soc/codecs/tas2783-sdw.c
sound/soc/sdw_utils` before relying on a later 7.2.y.

The UCM configs use their own `px13-speaker` names: alsa-ucm-conf releases
after 1.2.16.1 ship `sof-soundwire/tas2783.conf` and `codecs/tas2783/init.conf`
for other tas2783 boards, and files of ours at those paths would block the
package upgrade. The installer removes such files left by older versions of
this repo unless a package owns them.

## Verify (drivers)

```sh
# on 7.2.x both should point into updates/dkms/
modinfo -F filename snd_soc_tas2783_sdw snd_soc_sdw_utils

# stereo test tone (Front Left then Front Right)
speaker-test -D pulse -c 2 -l 1 -t wav
```

## Troubleshooting

- **Channels swapped** — the side each amp plays follows the codec order of
  the DAI link (upstream behaviour, tested on the PX13). Report it, and swap
  in PipeWire meanwhile (`audio.position = [ FR FL ]` on the speaker sink).
- **Mono or silent after resume on 7.2** — the DKMS modules aren't loaded;
  check `modinfo -F filename` above, then re-run `bash install-drivers.sh`
  or reboot.

## Tuning: 20-band speaker EQ (optional)

`tunings/px13/` shapes the internal speakers with a fitted 20-band tonal
correction (~+2 dB bass/mids rolling off above 9 kHz). WirePlumber replaces
the raw ALSA speaker sink with one logical `Built-in Speaker (Tuned)` output,
so the desktop does not show a duplicate raw output. The hardware sink stays
at 100% behind the filter (set through the card's Speaker route with
`configs/px13-speaker-route.lua`, since the hidden sink can't be reached with
`pactl`); the tuned output volume controls the final level.
The audio still reaches the AMD ALSA sink because that is the hardware path to
the amplifiers.

- **Source:** 20 reference band targets at 48 kHz, see
  `tunings/px13/eq_targets.txt`.
- **Content:** the targets fitted as 20 peaking biquads/channel at Q=0.8
  (dense RMS error 0.08 dB vs target, table in `tunings/px13/tuning.conf`),
  plus a brickwall limiter at −1 dBFS. Headphones are untouched.
- **Out of scope, by design:** dialog enhancement, surround virtualization,
  dynamic compression, extra loudness stages.
- **Metadata:** `tunings/px13/tuning.conf` also carries `description` and
  `sink_pattern` lines for downstream auto-install tooling; nothing in this
  repo reads them.

```sh
bash install-tuning.sh              # install + make default
bash install-tuning.sh --uninstall  # remove; restore the raw sink and its old volume
```

A/B against the raw speakers by uninstalling the tuning. Before making the
tuned sink default, the installer plays a quiet 440 Hz probe into it, records
the filter output and checks that the gain matches the EQ curve. If the
replacement fails to start or the probe fails, it restores the previous
configuration and volume. Small EQ tweaks can be made in `filter-chain.conf`
(re-run `install-tuning.sh` afterwards, it installs a copy); the targets live
in `tunings/px13/eq_targets.txt`.
Status: math-verified only — not yet confirmed with a mic measurement.

## Layout

```text
install.sh            both parts (default) / --drivers-only / --tuning-only
install-drivers.sh    DKMS module + UCM configs (standalone)
install-tuning.sh     WirePlumber speaker EQ (standalone, --uninstall supported)
module/               7.2.8 tas2783 + sdw_utils with 7.3 fixes (DKMS, 7.2.x only)
configs/              UCM configs, WirePlumber software-DSP rule + route script
tunings/px13/         filter-chain.conf, tuning.conf, eq_targets.txt
```

## Credits

- **ftoleedo** — original fix guide this repo builds on for stock kernels >= 7.1
- **nealstar** — original 16-patch series, including the channel-selection control earlier versions carried
- **Andrey Golovko / Bartosz Juraszewski** — upstream tas2783 resume/regcache fixes, backported here for 7.2
- **Antoine Monnet / Robin Everaars** — upstream tas2783 stereo split, backported here for 7.2
- **fecet** — CachyOS packaging (`linux-cachyos-px13`, `asus-proart-px13-quirks`) for the < 7.1 era
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver

## License

Guide, scripts and WirePlumber configs: CC0. Kernel modules (`module/`):
GPL-2.0, derived from the Linux kernel, text in `module/COPYING`. UCM configs:
BSD-3-Clause like alsa-ucm-conf, text in `configs/LICENSE.alsa-ucm-conf`.
Tuning data (`tunings/`) is not covered by any license grant in this
repository. Details in `LICENSE`.

## AI notice

Parts of this repository (scripts, UCM configs, and this README) were written
or revised with assistance from an AI coding tool, validated by hands-on
testing on the PX13. Review before use on other hardware.
