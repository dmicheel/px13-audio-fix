#!/usr/bin/env bash
# ProArt PX13 internal audio driver fix (TAS2783).
# Stock kernels >= 7.2. Run as a regular user; requests sudo when required.
#   bash install-drivers.sh
#
# 7.2.x: DKMS backport of the 7.3 stereo + resume fixes, plus UCM.
# 7.3+:  the stock driver already has the fixes; only UCM is installed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCM=/usr/share/alsa/ucm2
PCARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
DKMS_NAME=snd-soc-tas2783-sdw-px13
DKMS_VER=2.0
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

IFS=. read -r KMAJ KMIN _ <<< "$KREL"
KMIN="${KMIN%%[!0-9]*}"
if (( KMAJ < 7 || (KMAJ == 7 && KMIN < 2) )); then
  echo "Error: kernel $KREL is too old; this fix needs >= 7.2." >&2
  exit 1
fi
NEED_DKMS=0
(( KMAJ == 7 && KMIN == 2 )) && NEED_DKMS=1

echo "==> 1/7 Kernel modules (requires sudo)"
if [ "$NEED_DKMS" = 1 ]; then
  command -v dkms >/dev/null 2>&1 || { echo "    Error: dkms is required (e.g. pacman -S dkms)" >&2; exit 1; }
fi
sudo rm -f "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
sudo rm -f /usr/lib/systemd/system-sleep/50-px13-soundwire \
           /usr/local/lib/px13-soundwire-recover.sh
if command -v dkms >/dev/null 2>&1; then
  for ver in $(dkms status -m "$DKMS_NAME" 2>/dev/null |
      sed -nE "s|^$DKMS_NAME/([^,:]+)[,:].*|\1|p" | sort -u); do
    [ "$ver" = "$DKMS_VER" ] && continue
    sudo dkms remove "$DKMS_NAME/$ver" --all
    sudo rm -rf "/usr/src/$DKMS_NAME-$ver"
    echo "    Removed old DKMS version $ver"
  done
fi
if [ "$NEED_DKMS" = 1 ]; then
  sudo rm -rf "/usr/src/$DKMS_NAME-$DKMS_VER"
  sudo mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
  sudo cp -r "$REPO/module/Makefile" "$REPO/module/dkms.conf" \
             "$REPO/module/codecs" "$REPO/module/sdw_utils" \
             "/usr/src/$DKMS_NAME-$DKMS_VER/"
  sudo dkms install --force "$DKMS_NAME/$DKMS_VER" -k "$KREL"
  sudo depmod -a "$KREL"
  echo "    Installed through DKMS (rebuilds for 7.2.x kernel updates only)"
else
  echo "    Kernel $KREL ships the stereo and resume fixes; no DKMS module needed"
fi

echo "==> 2/7 Activating the modules"
# The loaded module must be the file modprobe resolves to now (the DKMS
# build on 7.2, the stock one otherwise).
modules_active() {
  local m loaded want
  [ -n "$(find_card)" ] || return 1
  for m in $MODULES; do
    loaded="$(cat "/sys/module/$m/srcversion" 2>/dev/null)" || return 1
    want="$(modinfo -k "$KREL" -F srcversion "$m" 2>/dev/null)" || return 1
    [ "$loaded" = "$want" ] || return 1
  done
}
if ! modules_active; then
  if [ -n "$(find_card)" ]; then
    echo "    card present but old modules loaded; reloading the stack..."
  else
    echo "    amdsoundwire card not present; (re)loading SoundWire/ACP stack..."
  fi
  PCI="0000:c4:00.5"
  DRV="/sys/bus/pci/drivers/snd_pci_ps"
  if [ -e "/sys/bus/pci/devices/$PCI/driver" ]; then
    sudo sh -c "echo '$PCI' > '$DRV/unbind'" 2>/dev/null || true
    sleep 1
  fi
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
  if [ ! -e "/sys/bus/pci/devices/$PCI/driver" ]; then
    sudo sh -c "echo '$PCI' > '$DRV/bind'" 2>/dev/null || true
  fi
  for _ in $(seq 1 40); do sleep 0.5; modules_active && break; done
fi
NEED_REBOOT=0
CARD="$(find_card)"
if [ -z "$CARD" ]; then
  NEED_REBOOT=1
  echo "    Card did not come up yet; a reboot will bring it up"
elif ! modules_active; then
  NEED_REBOOT=1
  echo "    New modules still not active (in use?); a reboot will load them"
else
  for m in $MODULES; do
    echo "    $m: $(modinfo -k "$KREL" -F filename "$m")"
  done
fi

echo "==> 3/7 UCM configuration (requires sudo)"
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

echo "==> 4/7 Validating UCM parsing (should list 'Speaker')"
if [ -n "$CARD" ]; then
  alsaucm -c "hw:$CARD" list _devices/HiFi | sed 's/^/    /' || true
else
  echo "    (skipped: no amdsoundwire card yet)"
fi

echo "==> 5/7 Restarting PipeWire and selecting the HiFi profile"
systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
sleep 3
if [ -n "$CARD" ]; then
  pactl set-card-profile "$PCARD" HiFi 2>/dev/null || echo "    Profile switch failed; check 'pactl list cards'"
  sleep 2
fi

echo "==> 6/7 Status (expected: Attached, Speaker sink)"
for d in /sys/bus/soundwire/devices/sdw:*; do
  echo "    $(basename "$d"): $(cat "$d/status" 2>/dev/null)"
done
wpctl status | sed -n '/Sinks:/,/Sources:/p' | sed 's/^/    /'
SPK=$(pactl list short sinks 2>/dev/null | awk '/amd_sdw/ && /[Ss]peaker/{print $2; exit}')
if [ -n "${SPK:-}" ]; then
  wpctl set-default "$(pactl list short sinks | awk -v s="$SPK" '$2==s{print $1; exit}')" 2>/dev/null || true
  echo "    Default sink = $SPK"
fi

echo "==> 7/7 Saving ALSA state"
sudo alsactl store || true

echo
if [ "$NEED_REBOOT" = 1 ]; then
  echo "==> REBOOT the computer, then run: speaker-test -D pulse -c2 -l1 -t wav"
else
  echo "==> SOUND TEST (stereo: 'Front Left' on the left, 'Front Right' on the right):"
  speaker-test -D pulse -c2 -l1 -t wav 2>/dev/null | grep Front || true
fi
