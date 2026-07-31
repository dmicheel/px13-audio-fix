#!/bin/bash
# PX13 SoundWire audio recovery after s2idle resume.
# Runs as a transient unit (systemd-run) started by the hook
# /usr/lib/systemd/system-sleep/50-px13-soundwire. It must never run inline
# during resume because that delays thawing the user session (black screen).
#
# Method (validated 2026-07-30): fully reload the SoundWire/ACP modules.
# A simple PCI unbind/bind does not work on kernel 7.1.5. The peripherals
# disappear from the bus after s2idle and only full re-enumeration restores them.
#
#   - Always reload, even when Attached: TAS2783 DSP firmware does not survive
#     s2idle and only re-probing downloads it again ("playback without fw
#     download" means a silent amplifier).
#   - Unbind PCI -> unload stack (children first) -> load modules -> bind.
#   - Wait up to 20 seconds for Attached status.
#   - Always restart session PipeWire: a missing card wedges WirePlumber's graph
#     and even breaks Bluetooth audio (observed 2026-07-29).
#   - On success, restore the HiFi profile and unmute the speaker. Make it the
#     default only when the current default is auto_null, so Bluetooth is kept.
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

# There is no "already Attached" shortcut. s2idle clears TAS2783 DSP firmware
# even when the bus remains Attached (dmesg reports "error playback without fw
# download" and the amplifier is silent; observed 2026-07-30). Only re-probing
# by reloading the modules downloads the firmware again. Always reload.
is_bound && all_attached && log "recovery: codecs are Attached, but reloading because amplifier firmware does not survive s2idle"

# Fully reload modules in the order mapped from lsmod on kernel 7.1.5.
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

# Always restart session PipeWire. A missing SoundWire card after resume wedges
# the WirePlumber graph and even breaks Bluetooth audio.
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
