# PX13 internal audio fix

Restores internal speakers (stereo) on the ASUS ProArt PX13 (dual TAS2783
SoundWire amps) on stock kernels >= 7.3. The 7.3 driver already splits the
stereo stream across the two amps and survives s2idle; this repo adds what
the kernel and alsa-ucm-conf still lack: the UCM speaker configs and a udev
rule for the RT721 jack codec.

The optional 20-band speaker EQ that used to live here is now a separate
repo, [px13-audio-tunings](https://github.com/dmicheel/px13-audio-tunings).
It needs the working speaker sink this repo provides.

## Install

```sh
bash install.sh
```

Runs as a regular user (asks for sudo), installs the UCM configs and the
udev rule, and reloads the module stack if needed, so no reboot is needed
(on a fresh machine it brings the `amdsoundwire` card up first). It also
removes the 7.2 DKMS module and resume hook of older versions of this repo.

## What it installs

- **UCM configs** (`/usr/share/alsa/ucm2/`): the `Speaker` device of the
  HiFi profile and a single hardware volume over both amps. alsa-ucm-conf
  has no PX13 speaker config, so without them PipeWire shows no speaker.
- **RT721 udev rule** (`/etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules`):
  keeps the headphone-jack codec out of runtime suspend. On 7.3 (also
  CachyOS; the resume path is unchanged in linux-next as of 2026-10-23) it
  suspends 3 s after probe and its runtime resume fails in `regcache_sync()`
  (`-ENODATA`), so
  every later open fails with `rt721-sdca ... ASoC error (-61)`. PipeWire
  needs every HiFi mapping to open, so if it probes the card after that
  (late login, PipeWire restart) the whole HiFi profile goes, Speaker
  included, and only Pro Audio is left. The cost is the codec staying
  powered.

The UCM configs use their own `px13-speaker` names: alsa-ucm-conf releases
after 1.2.16.1 ship `sof-soundwire/tas2783.conf` and `codecs/tas2783/init.conf`
for other tas2783 boards, and files of ours at those paths would block the
package upgrade. The installer removes such files left by older versions of
this repo unless a package owns them.

### Kernel 7.2

7.2 lacks the upstream stereo split and the tas2783/sdw_utils resume fixes.
Older versions of this repo carried them as a DKMS backport; use a 7.3
kernel instead.

## Verify

```sh
# should print "on" and "active"
cat /sys/bus/soundwire/devices/sdw:*:025d:0721:*/power/{control,runtime_status}

# stereo test tone (Front Left then Front Right)
speaker-test -D pulse -c 2 -l 1 -t wav
```

## Troubleshooting

- **Only the Pro Audio profile, no speaker** — the RT721 codec died before
  the rule was applied (`ASoC error (-61)` in `dmesg`). Re-run
  `bash install.sh` or reboot.
- **Channels swapped** — the side each amp plays follows the codec order of
  the DAI link (upstream behaviour, tested on the PX13). Report it, and swap
  in PipeWire meanwhile (`audio.position = [ FR FL ]` on the speaker sink).
- **`tas2783 ... port 2 not supported for TX` at login** — PipeWire probes
  the amps' capture PCM for its Pro Audio profile; HiFi does not use that
  PCM.

## Layout

```text
install.sh            UCM configs + RT721 udev rule
configs/              UCM configs, udev rule
```

## Credits

- **ftoleedo** — original fix guide this repo builds on, and the RT721
  runtime-PM diagnosis and udev rule
- **nealstar** — original 16-patch series, including the channel-selection control earlier versions carried
- **Andrey Golovko / Bartosz Juraszewski** — upstream tas2783 resume/regcache fixes (7.3)
- **Antoine Monnet / Robin Everaars** — upstream tas2783 stereo split (7.3)
- **fecet** — CachyOS packaging (`linux-cachyos-px13`, `asus-proart-px13-quirks`) for the < 7.1 era
- **TI / Niranjan H Y, Baojun Xu, Kevin Lu** — upstream tas2783 driver

## License

Guide, install script and udev rule: CC0. UCM configs: BSD-3-Clause like
alsa-ucm-conf, text in `configs/LICENSE.alsa-ucm-conf`. Details in `LICENSE`.

## AI notice

Parts of this repository (scripts, UCM configs, and this README) were written
or revised with assistance from an AI coding tool, validated by hands-on
testing on the PX13. Review before use on other hardware.
