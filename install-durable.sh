#!/usr/bin/env bash
# Durable ProArt PX13 internal audio installer (TAS2783).
# For stock kernels >= 7.1 with the upstream TAS2783 driver. Run as a regular
# user; the script requests sudo when required.
#   bash install-durable.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCM=/usr/share/alsa/ucm2
# ALSA card numbers are assigned dynamically; find the SoundWire card by its
# stable ID instead of assuming it is card 1 (HDMI often takes that slot).
CARD=""
for id_path in /proc/asound/card*/id; do
  [ -r "$id_path" ] || continue
  read -r card_id < "$id_path"
  if [ "$card_id" = "amdsoundwire" ]; then
    CARD="${id_path#/proc/asound/card}"
    CARD="${CARD%/id}"
    break
  fi
done
[ -n "$CARD" ] || {
  echo "Error: could not find the ALSA SoundWire card (amdsoundwire)" >&2
  exit 1
}

# CardLongName varies by unit (HN7306EA vs HN7306EAC), so derive it at runtime
# to name the override correctly. Fall back to the maintainer's original value.
LONG="$(amixer -D "hw:$CARD" info 2>/dev/null | head -1 | awk -F"'" '{print $4}')"
[ -n "$LONG" ] || LONG="ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC"
PCARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
DKMS_NAME=snd-soc-tas2783-sdw-px13
DKMS_VER=1.0
KREL="$(uname -r)"

echo "==> 1/8 Kernel module with 'Channel Playback' control (requires sudo)"
if command -v dkms >/dev/null 2>&1; then
  # Remove an old manual installation so it cannot compete with DKMS.
  sudo rm -f "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
  sudo mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
  sudo cp -f "$REPO/module/tas2783-sdw.c" "$REPO/module/tas2783.h" \
             "$REPO/module/Makefile" "$REPO/module/dkms.conf" \
             "/usr/src/$DKMS_NAME-$DKMS_VER/"
  sudo dkms install --force "$DKMS_NAME/$DKMS_VER" -k "$KREL"
  echo "    Installed through DKMS (automatically rebuilds after kernel updates)"
else
  echo "    DKMS not found; using a manual build (repeat after every kernel update)"
  ( cd "$REPO/module" && make KVER="$KREL" LLVM=1 )
  sudo install -Dm644 "$REPO/module/snd-soc-tas2783-sdw.ko" \
       "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
  sudo depmod -a "$KREL"
fi

echo "==> 2/8 UCM configuration (requires sudo)"
sudo install -Dm644 "$REPO/configs/sof-soundwire_tas2783.conf"  "$UCM/sof-soundwire/tas2783.conf"
sudo install -Dm644 "$REPO/configs/codecs_tas2783_init.conf"    "$UCM/codecs/tas2783/init.conf"
sudo install -Dm644 "$REPO/configs/px13-longname-override.conf" "$UCM/conf.d/amd-soundwire/$LONG.conf"
echo "    Installed unowned override in conf.d/amd-soundwire (survives updates)"

echo "==> 3/8 SoundWire recovery after s2idle (requires sudo)"
sudo install -Dm755 "$REPO/50-px13-soundwire" \
     "/usr/lib/systemd/system-sleep/50-px13-soundwire"
sudo install -Dm755 "$REPO/px13-soundwire-recover.sh" \
     "/usr/local/lib/px13-soundwire-recover.sh"
echo "    Installed hook that starts recovery in the background after resume"

echo "==> 4/8 Activating the corrected module"
NEED_REBOOT=0
if ! amixer -D "hw:$CARD" controls 2>/dev/null | grep -q 'Channel Playback'; then
  systemctl --user stop wireplumber pipewire pipewire-pulse 2>/dev/null || true
  if sudo modprobe -r snd_soc_tas2783_sdw 2>/dev/null && sudo modprobe snd_soc_tas2783_sdw; then
    echo "    Module reloaded without rebooting"
    sleep 2
  else
    NEED_REBOOT=1
    echo "    Live reload failed; reboot after installation"
  fi
else
  echo "    Control already present (corrected module is loaded)"
fi

echo "==> 5/8 Validating UCM parsing (should list 'Speaker')"
alsaucm -c "$CARD" list _devices/HiFi | sed 's/^/    /' || true

echo "==> 6/8 Restarting PipeWire and selecting the HiFi profile"
systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 3
pactl set-card-profile "$PCARD" HiFi 2>/dev/null || echo "    Profile switch failed; check 'pactl list cards'"
sleep 2

echo "==> 7/8 Status (expected: Attached, channels 1/2, Speaker sink)"
for d in /sys/bus/soundwire/devices/sdw:*; do
  echo "    $(basename "$d"): $(cat "$d/status" 2>/dev/null)"
done
for n in 1 2; do
  amixer -D "hw:$CARD" cget name="tas2783-$n Channel Playback" 2>/dev/null | tail -1 | sed "s/^/    tas2783-$n:/"
done
wpctl status | sed -n '/Sinks:/,/Sources:/p' | sed 's/^/    /'
SPK=$(pactl list short sinks 2>/dev/null | awk '/amd_sdw/ && /[Ss]peaker/{print $2; exit}')
if [ -n "${SPK:-}" ]; then
  wpctl set-default "$(pactl list short sinks | awk -v s="$SPK" '$2==s{print $1; exit}')" 2>/dev/null || true
  echo "    Default sink = $SPK"
fi

echo "==> 8/8 Saving ALSA state"
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
