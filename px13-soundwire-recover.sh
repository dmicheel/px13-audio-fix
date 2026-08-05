#!/bin/bash
# PX13 SoundWire audio recovery after s2idle/hibernate resume.
# Reloads the SoundWire/ACP module stack so the TAS2783 amplifier firmware is
# re-downloaded (it does not survive s2idle), then restarts the session audio
# stack and restores the HiFi speaker profile.
#
# Runs detached (systemd-run) from /usr/lib/systemd/system-sleep/50-px13-soundwire;
# do not run it inline during resume (blocks the frozen session).
#
# Install: /usr/local/lib/px13-soundwire-recover.sh (root:root 0755)
# Run manually: sudo /usr/local/lib/px13-soundwire-recover.sh
set -u
PCI="0000:c4:00.5"
DRV="/sys/bus/pci/drivers/snd_pci_ps"
CARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
SINK="alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink"
LOG="/var/log/px13-soundwire-resume.log"
log(){ echo "$(date '+%F %T' 2>/dev/null||echo now) $*" >> "$LOG" 2>/dev/null; }

# Allow resume to complete and the user session to thaw before changing devices.
sleep 2
log "recovery: starting in the background (ACP $PCI)"

is_bound(){ [ -e "/sys/bus/pci/devices/$PCI/driver" ]; }
all_attached(){
  local d ok=1 n=0
  for d in /sys/bus/soundwire/devices/sdw:0:1:*; do
    [ -e "$d/status" ] || continue; n=$((n+1))
    [ "$(cat "$d/status" 2>/dev/null)" = "Attached" ] || ok=0
  done
  [ "$n" -ge 1 ] && [ "$ok" = "1" ]
}
status_str(){ local d s="(empty)"; for d in /sys/bus/soundwire/devices/sdw:0:1:*; do [ -e "$d" ] || continue; s="$s $(basename "$d"|cut -d: -f4,5)=$(cat "$d/status" 2>/dev/null)"; done; echo "$s"; }

# There is no "already Attached" shortcut: s2idle clears the TAS2783 DSP
# firmware even when the bus stays Attached, leaving the amplifier silent.
# Only re-probing by reloading the modules downloads the firmware again.
is_bound && all_attached && log "recovery: codecs are Attached, but reloading because amplifier firmware does not survive s2idle"

# Fully reload modules, children first (order mapped from lsmod).
[ -e "/sys/bus/pci/devices/$PCI/driver" ] && { echo "$PCI" > "$DRV/unbind" 2>>"$LOG"; sleep 1; }
MODS_DOWN=(snd_acp_sdw_legacy_mach snd_acp_sdw_mach snd_soc_rt721_sdca \
           snd_soc_tas2783_sdw snd_ps_sdw_dma snd_pci_ps \
           snd_sof_amd_acp70 snd_sof_amd_acp63 snd_sof_amd_vangogh \
           snd_sof_amd_rembrandt snd_sof_amd_renoir snd_sof_amd_acp \
           soundwire_amd soundwire_generic_allocation)
for m in "${MODS_DOWN[@]}"; do
  lsmod | grep -q "^$m " || continue
  modprobe -r "$m" 2>>"$LOG" || log "rmmod $m FAILED (continuing)"
done
sleep 2
for m in snd_pci_ps snd_soc_rt721_sdca snd_soc_tas2783_sdw snd_ps_sdw_dma snd_acp_sdw_legacy_mach; do
  modprobe "$m" 2>>"$LOG" || log "modprobe $m FAILED"
done
sleep 2
is_bound || { echo "$PCI" > "$DRV/bind" 2>>"$LOG"; log "manually bound PCI device after reload"; }

# Wait up to 20 seconds for enumeration and attachment.
for i in $(seq 1 40); do sleep 0.5; all_attached && break; done
log "recovery after reload:$(status_str)"
all_attached || log "recovery: codecs remain unavailable; internal audio requires a reboot; restarting PipeWire to restore Bluetooth and HDMI"

# Always restart the session audio stack: a missing SoundWire card wedges
# WirePlumber's graph and breaks Bluetooth audio too.
UNAME="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 ~ /seat/ {print $3; exit}')"
[ -z "${UNAME:-}" ] && UNAME="$(id -nu 1000 2>/dev/null || echo root)"
UID_="$(id -u "$UNAME" 2>/dev/null || echo 1000)"; RT="/run/user/$UID_"
ru(){ runuser -u "$UNAME" -- env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@" 2>>"$LOG"; }
if [ -S "$RT/bus" ]; then
  ru systemctl --user restart wireplumber pipewire pipewire-pulse
  sleep 4
  if all_attached; then
    ru pactl set-card-profile "$CARD" HiFi; sleep 1
    ru pactl set-sink-mute "$SINK" 0
    # Only become the default when none exists; do not replace Bluetooth audio.
    DEF="$(ru pactl get-default-sink 2>/dev/null)"
    case "${DEF:-}" in ""|auto_null) ru pactl set-default-sink "$SINK" ;; esac
    log "recovery: SUCCESS; PipeWire restarted and HiFi speaker restored (previous default=${DEF:-empty})"
  else
    log "recovery: PipeWire restarted without the internal speaker"
  fi
else
  log "WARNING: $RT/bus is unavailable; PipeWire was not restarted"
fi
exit 0
