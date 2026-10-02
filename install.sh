#!/usr/bin/env bash
# ProArt PX13 internal audio fix (TAS2783).
# Stock kernels >= 7.3. Run as a regular user; requests sudo when required.
#   bash install.sh
#
# The 7.3 driver handles stereo and resume itself. This installs the UCM
# configs for the speaker and a udev rule that keeps the RT721 jack codec
# out of runtime suspend, and removes the 7.2 DKMS module of older versions.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCM=/usr/share/alsa/ucm2
UDEV_RULE=/etc/udev/rules.d/90-px13-rt721-no-autosuspend.rules
PCARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
TUNE_SINK="px13_speaker_tuning"
DKMS_NAME=snd-soc-tas2783-sdw-px13
KREL="$(uname -r)"
MODULES="snd_soc_tas2783_sdw snd_soc_sdw_utils"
# Fallback CardLongNames if the card is not up yet (HN7306EA and HN7306EAC).
LONG_FALLBACK="ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EA-1.0-HN7306EA
ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC"

find_card() {
  local id_path card_id card
  for id_path in /proc/asound/card*/id; do
    [ -r "$id_path" ] || continue
    read -r card_id < "$id_path"
    if [ "$card_id" = "amdsoundwire" ]; then
      card="${id_path#/proc/asound/card}"
      echo "${card%/id}"
      return
    fi
  done
  return 0
}

rt721_dev() {
  local d
  for d in /sys/bus/soundwire/devices/sdw:*:025d:0721:*; do
    [ -e "$d" ] && { echo "$d"; return; }
  done
  return 0
}

# The jack codec is usable: runtime PM forbidden and the device resumed.
rt721_ok() {
  local d
  d="$(rt721_dev)"
  [ -n "$d" ] &&
    [ "$(cat "$d/power/control" 2>/dev/null)" = on ] &&
    [ "$(cat "$d/power/runtime_status" 2>/dev/null)" = active ]
}

# The loaded modules must be the files modprobe resolves to now (stock ones,
# not a leftover DKMS or manually installed copy). After a kernel update
# without reboot there is nothing on disk to compare with.
modules_active() {
  local m loaded want
  [ -n "$(find_card)" ] || return 1
  [ "$KMODS_GONE" = 0 ] || return 0
  for m in $MODULES; do
    loaded="$(cat "/sys/module/$m/srcversion" 2>/dev/null)" || return 1
    want="$(modinfo -k "$KREL" -F srcversion "$m" 2>/dev/null)" || return 1
    [ "$loaded" = "$want" ] || return 1
  done
}

# Removes a file from an older install, unless a package owns it now.
remove_legacy_ucm() {
  local path=$1 marker=$2
  [ -f "$path" ] || return 0
  if command -v pacman >/dev/null 2>&1 && pacman -Qoq "$path" >/dev/null 2>&1; then
    return 0
  fi
  if grep -qF "$marker" "$path"; then
    sudo rm -f -- "$path"
    echo "    Removed old $path"
  fi
}

KMODS_GONE=0
[ -d "/usr/lib/modules/$KREL/kernel" ] || KMODS_GONE=1

IFS=. read -r KMAJ KMIN _ <<< "$KREL"
KMIN="${KMIN%%[!0-9]*}"
if (( KMAJ < 7 || (KMAJ == 7 && KMIN < 3) )); then
  echo "Error: kernel $KREL is too old; this fix needs >= 7.3." >&2
  echo "       (7.2 needs the stereo/resume backport from older versions of this repo.)" >&2
  exit 1
fi

echo "==> 1/7 Removing components of older versions (requires sudo)"
REMOVED_MODULE=0
if command -v dkms >/dev/null 2>&1; then
  for ver in $(dkms status -m "$DKMS_NAME" 2>/dev/null |
      sed -nE "s|^$DKMS_NAME/([^,:]+)[,:].*|\1|p" | sort -u); do
    sudo dkms remove "$DKMS_NAME/$ver" --all
    REMOVED_MODULE=1
    echo "    Removed DKMS module $DKMS_NAME/$ver"
  done
fi
for src in /usr/src/"$DKMS_NAME"-*; do
  [ -d "$src" ] || continue
  sudo rm -rf -- "$src"
  echo "    Removed $src"
done
for ko in /usr/lib/modules/*/updates/snd-soc-tas2783-sdw.ko; do
  [ -e "$ko" ] || continue
  sudo rm -f -- "$ko"
  REMOVED_MODULE=1
  echo "    Removed $ko"
done
[ "$REMOVED_MODULE" = 0 ] || sudo depmod -a "$KREL"
for old in /usr/lib/systemd/system-sleep/50-px13-soundwire /usr/local/lib/px13-soundwire-recover.sh; do
  [ -e "$old" ] || continue
  sudo rm -f -- "$old"
  echo "    Removed $old"
done
echo "    Kernel $KREL ships the stereo and resume fixes; using the stock modules"

echo "==> 2/7 RT721 jack codec udev rule (requires sudo)"
sudo install -Dm644 "$REPO/configs/90-px13-rt721-no-autosuspend.rules" "$UDEV_RULE"
sudo udevadm control --reload
RT721="$(rt721_dev)"
if [ -n "$RT721" ] && [ "$(cat "$RT721/power/control")" != on ]; then
  echo on | sudo tee "$RT721/power/control" >/dev/null
  sleep 1
fi
echo "    Installed $UDEV_RULE"

echo "==> 3/7 Checking the card and the jack codec"
# A jack codec that already went through its broken runtime resume stays
# dead until it is probed again; rebinding the ACP is enough for that.
# Stale or missing modules need the whole stack reloaded.
if ! modules_active || ! rt721_ok; then
  FULL_RELOAD=1
  if [ -z "$(find_card)" ]; then
    echo "    amdsoundwire card not present; (re)loading SoundWire/ACP stack..."
  elif ! modules_active; then
    echo "    card present but old modules loaded; reloading the stack..."
  else
    FULL_RELOAD=0
    echo "    RT721 jack codec failed to resume; re-probing the SoundWire devices..."
  fi
  # Without the running kernel's modules on disk, unloaded ones can't come back.
  if [ "$KMODS_GONE" = 1 ] && [ "$FULL_RELOAD" = 1 ]; then
    FULL_RELOAD=0
    echo "    (kernel updated since boot; only rebinding, not reloading modules)"
  fi
  # PipeWire is socket-activated and would keep the card open.
  systemctl --user stop pipewire.socket pipewire-pulse.socket \
    wireplumber pipewire pipewire-pulse 2>/dev/null || true
  PCI="0000:c4:00.5"
  DRV="/sys/bus/pci/drivers/snd_pci_ps"
  if [ -e "/sys/bus/pci/devices/$PCI/driver" ]; then
    sudo sh -c "echo '$PCI' > '$DRV/unbind'" 2>/dev/null || true
    sleep 1
  fi
  if [ "$FULL_RELOAD" = 1 ]; then
    sudo bash -c 'for m in snd_acp_sdw_legacy_mach snd_acp_sdw_mach snd_soc_sdw_utils \
      snd_soc_rt721_sdca snd_soc_tas2783_sdw snd_ps_sdw_dma snd_pci_ps snd_sof_amd_acp70 \
      snd_sof_amd_acp63 snd_sof_amd_vangogh snd_sof_amd_rembrandt \
      snd_sof_amd_renoir snd_sof_amd_acp soundwire_amd \
      soundwire_generic_allocation; do lsmod | grep -q "^$m " && modprobe -r "$m" 2>/dev/null || true; done'
    sleep 2
    for m in snd_pci_ps snd_soc_rt721_sdca snd_soc_tas2783_sdw snd_ps_sdw_dma snd_acp_sdw_legacy_mach; do
      sudo modprobe "$m" 2>/dev/null || true
    done
    sleep 2
  fi
  if [ ! -e "/sys/bus/pci/devices/$PCI/driver" ]; then
    sudo sh -c "echo '$PCI' > '$DRV/bind'" 2>/dev/null || true
  fi
  for _ in $(seq 1 40); do sleep 0.5; modules_active && rt721_ok && break; done
fi
NEED_REBOOT=0
CARD="$(find_card)"
if [ -z "$CARD" ]; then
  NEED_REBOOT=1
  echo "    Card did not come up yet; a reboot will bring it up"
elif ! modules_active; then
  NEED_REBOOT=1
  echo "    Stock modules still not active (in use?); a reboot will load them"
elif ! rt721_ok; then
  NEED_REBOOT=1
  echo "    RT721 jack codec still not active; a reboot will apply the udev rule"
else
  if [ "$KMODS_GONE" = 0 ]; then
    for m in $MODULES; do
      echo "    $m: $(modinfo -k "$KREL" -F filename "$m")"
    done
  fi
  echo "    RT721 jack codec: runtime PM off, active"
fi
if [ "$KMODS_GONE" = 1 ]; then
  echo "    Note: running kernel $KREL was replaced on disk; reboot into the new one when convenient"
fi

echo "==> 4/7 UCM configuration (requires sudo)"
LONG=""
if [ -n "$CARD" ]; then
  LONG="$(amixer -D "hw:$CARD" info 2>/dev/null | head -1 | awk -F"'" '{print $4}')"
fi
[ -n "$LONG" ] || LONG="$LONG_FALLBACK"
remove_legacy_ucm "$UCM/sof-soundwire/tas2783.conf" "TAS2783 Speaker device for the sof-soundwire HiFi profile"
remove_legacy_ucm "$UCM/codecs/tas2783/init.conf" "TAS2783 codec init: remap the two amps"
sudo rmdir "$UCM/codecs/tas2783" 2>/dev/null || true
sudo install -Dm644 "$REPO/configs/sof-soundwire_px13-speaker.conf" "$UCM/sof-soundwire/px13-speaker.conf"
sudo install -Dm644 "$REPO/configs/codecs_px13-speaker_init.conf"   "$UCM/codecs/px13-speaker/init.conf"
while read -r name; do
  sudo install -Dm644 "$REPO/configs/px13-longname-override.conf" "$UCM/conf.d/amd-soundwire/$name.conf"
done <<< "$LONG"
echo "    Installed px13-speaker files and the card override (owned by no package)"

echo "==> 5/7 Validating UCM parsing (should list 'Speaker')"
if [ -n "$CARD" ]; then
  alsaucm -c "hw:$CARD" list _devices/HiFi | sed 's/^/    /' || true
else
  echo "    (skipped: no amdsoundwire card yet)"
fi

echo "==> 6/7 Restarting PipeWire and selecting the HiFi profile"
systemctl --user start pipewire.socket pipewire-pulse.socket 2>/dev/null || true
systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
sleep 3
if [ -n "$CARD" ]; then
  pactl set-card-profile "$PCARD" HiFi 2>/dev/null || echo "    Profile switch failed; check 'pactl list cards'"
  sleep 2
fi

echo "==> 7/7 Status (expected: Attached, Speaker sink) and saving ALSA state"
for d in /sys/bus/soundwire/devices/sdw:*; do
  echo "    $(basename "$d"): $(cat "$d/status" 2>/dev/null)"
done
wpctl status | sed -n '/Sinks:/,/Sources:/p' | sed 's/^/    /'
SPK=$(pactl list short sinks 2>/dev/null | awk '/amd_sdw/ && /[Ss]peaker/{print $2; exit}')
if [ -n "${SPK:-}" ]; then
  wpctl set-default "$(pactl list short sinks | awk -v s="$SPK" '$2==s{print $1; exit}')" 2>/dev/null || true
  echo "    Default sink = $SPK"
elif pactl list short sinks 2>/dev/null | awk -v s="$TUNE_SINK" '$2==s{f=1} END{exit !f}'; then
  # px13-audio-tunings hides the raw sink behind its EQ sink.
  pactl set-default-sink "$TUNE_SINK" 2>/dev/null || true
  echo "    Speaker EQ (px13-audio-tunings) active; default sink = $TUNE_SINK"
fi
sudo alsactl store || true

echo
if [ "$NEED_REBOOT" = 1 ]; then
  echo "==> REBOOT the computer, then run: speaker-test -D pulse -c2 -l1 -t wav"
else
  echo "==> SOUND TEST (stereo: 'Front Left' on the left, 'Front Right' on the right):"
  speaker-test -D pulse -c2 -l1 -t wav 2>/dev/null | grep Front || true
fi
