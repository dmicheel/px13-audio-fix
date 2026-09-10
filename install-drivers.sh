#!/usr/bin/env bash
# ProArt PX13 internal audio driver fix (TAS2783).
# Stock kernels >= 7.2. Run as a regular user; requests sudo when required.
#   bash install-drivers.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCM=/usr/share/alsa/ucm2
PCARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
DKMS_NAME=snd-soc-tas2783-sdw-px13
DKMS_VER=1.0
KREL="$(uname -r)"

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

echo "==> 1/7 Kernel module with 'Channel Playback' control (requires sudo)"
command -v dkms >/dev/null 2>&1 || { echo "    Error: dkms is required (e.g. pacman -S dkms)" >&2; exit 1; }
sudo rm -f "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
sudo mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
sudo cp -f "$REPO/module/tas2783-sdw.c" "$REPO/module/tas2783.h" \
           "$REPO/module/Makefile" "$REPO/module/dkms.conf" \
           "/usr/src/$DKMS_NAME-$DKMS_VER/"
sudo dkms install --force "$DKMS_NAME/$DKMS_VER" -k "$KREL"
sudo depmod -a "$KREL"
echo "    Installed through DKMS (automatically rebuilds after kernel updates)"

sudo rm -f /usr/lib/systemd/system-sleep/50-px13-soundwire \
           /usr/local/lib/px13-soundwire-recover.sh

echo "==> 2/7 Activating the corrected module"
control_active() {
  local c; c="$(find_card)"
  [ -n "$c" ] && amixer -D "hw:$c" controls 2>/dev/null | grep -q 'Channel Playback'
}
if ! control_active; then
  if [ -n "$(find_card)" ]; then
    echo "    card present but stock driver bound; reloading stack to activate patched module..."
  else
    echo "    amdsoundwire card not present; (re)loading SoundWire/ACP stack..."
  fi
  PCI="0000:c4:00.5"
  DRV="/sys/bus/pci/drivers/snd_pci_ps"
  if [ -e "/sys/bus/pci/devices/$PCI/driver" ]; then
    sudo sh -c "echo '$PCI' > '$DRV/unbind'" 2>/dev/null || true
    sleep 1
  fi
  sudo bash -c 'for m in snd_acp_sdw_legacy_mach snd_acp_sdw_mach snd_soc_rt721_sdca \
    snd_soc_tas2783_sdw snd_ps_sdw_dma snd_pci_ps snd_sof_amd_acp70 \
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
  for _ in $(seq 1 40); do sleep 0.5; control_active && break; done
fi
NEED_REBOOT=0
CARD="$(find_card)"
if [ -z "$CARD" ]; then
  NEED_REBOOT=1
  echo "    Card did not come up yet; a reboot will bring it up"
elif ! control_active; then
  NEED_REBOOT=1
  echo "    Corrected module still not active; a reboot will load it"
else
  echo "    Channel Playback control present (corrected module is active)"
fi

echo "==> 3/7 UCM configuration (requires sudo)"
if [ -n "$CARD" ]; then
  LONG="$(amixer -D "hw:$CARD" info 2>/dev/null | head -1 | awk -F"'" '{print $4}')"
fi
[ -n "${LONG:-}" ] || LONG="ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC"
sudo install -Dm644 "$REPO/configs/sof-soundwire_tas2783.conf"  "$UCM/sof-soundwire/tas2783.conf"
sudo install -Dm644 "$REPO/configs/codecs_tas2783_init.conf"    "$UCM/codecs/tas2783/init.conf"
sudo install -Dm644 "$REPO/configs/px13-longname-override.conf" "$UCM/conf.d/amd-soundwire/$LONG.conf"
echo "    Installed unowned override in conf.d/amd-soundwire (survives updates)"

echo "==> 4/7 Validating UCM parsing (should list 'Speaker')"
if [ -n "$CARD" ]; then
  alsaucm -c "$CARD" list _devices/HiFi | sed 's/^/    /' || true
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

echo "==> 6/7 Status (expected: Attached, channels 1/2, Speaker sink)"
for d in /sys/bus/soundwire/devices/sdw:*; do
  echo "    $(basename "$d"): $(cat "$d/status" 2>/dev/null)"
done
if [ -n "$CARD" ]; then
  for n in 1 2; do
    amixer -D "hw:$CARD" cget name="tas2783-$n Channel Playback" 2>/dev/null | tail -1 | sed "s/^/    tas2783-$n:/"
  done
fi
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
  echo
  echo "If the channels are reversed, swap the two csets in"
  echo "  $UCM/sof-soundwire/tas2783.conf (1<->2), then run: systemctl --user restart pipewire wireplumber"
fi
