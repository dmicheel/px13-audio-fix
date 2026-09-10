#!/usr/bin/env bash
# PX13 speaker EQ: 20-band tonal correction as a PipeWire filter-chain.
# Independent from install-drivers.sh; needs a working HiFi Speaker sink.
# Run as a regular user; sudo is only used to install lsp-plugins-lv2 if missing.
#
#   bash install-tuning.sh              # install + enable
#   bash install-tuning.sh --uninstall  # remove, restore raw speaker default
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/tunings/px13/filter-chain.conf"
DST="$HOME/.config/pipewire/pipewire.conf.d/51-px13-speaker-tuning.conf"
SPK_SINK="alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink"
TUNE_SINK="px13_speaker_tuning"

if [ "${1:-}" = "--uninstall" ]; then
  echo "==> Removing PX13 speaker EQ"
  rm -f "$DST"
  systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
  sleep 2
  pactl set-default-sink "$SPK_SINK" 2>/dev/null || true
  echo "    Removed $DST"
  echo "    Default sink set to raw speakers (if present)"
  exit 0
fi

echo "==> 1/5 Prerequisites"
command -v pipewire >/dev/null 2>&1 || { echo "    Error: pipewire not found" >&2; exit 1; }
have_limiter=0
if [ -d /usr/lib/lv2/lsp-plugins-lv2.lv2 ]; then have_limiter=1; fi
if [ -d /usr/lib/lv2/lsp-plugins.lv2 ]; then have_limiter=1; fi
for d in /usr/lib/lv2 /usr/local/lib/lv2 "$HOME/.lv2"; do
  if [ -d "$d" ] && find "$d" -maxdepth 2 -iname '*limiter*' 2>/dev/null | grep -q .; then
    have_limiter=1
  fi
done
if [ "$have_limiter" = 0 ]; then
  echo "    LSP limiter plugin missing; installing lsp-plugins-lv2 (requires sudo)"
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm lsp-plugins-lv2
  elif command -v apt >/dev/null 2>&1; then
    sudo apt install -y lsp-plugins-lv2
  else
    echo "    Error: install an LV2 package providing http://lsp-plug.in/plugins/lv2/limiter_stereo" >&2
    exit 1
  fi
else
  echo "    LSP limiter plugin present"
fi

echo "==> 2/5 Checking for a working speaker sink"
if ! pactl list short sinks 2>/dev/null | grep -q "$SPK_SINK"; then
  echo "    Error: HiFi Speaker sink '$SPK_SINK' not found." >&2
  echo "    Run 'bash install-drivers.sh' first, then re-run this script." >&2
  exit 1
fi
echo "    Speaker sink present"

echo "==> 3/5 Installing PipeWire filter-chain"
mkdir -p "$(dirname "$DST")"
cp -f "$SRC" "$DST"
systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
FOUND=""
for _ in $(seq 1 20); do
  sleep 0.5
  if pactl list short sinks 2>/dev/null | grep -q "$TUNE_SINK"; then FOUND=1; break; fi
done
if [ -z "$FOUND" ]; then
  echo "    Error: tuning sink '$TUNE_SINK' did not appear." >&2
  echo "    Check 'pw-cli ls Node' and 'journalctl --user -u pipewire' for filter-chain errors." >&2
  exit 1
fi
echo "    Tuning sink '$TUNE_SINK' active"
pactl set-default-sink "$TUNE_SINK" 2>/dev/null || \
  wpctl set-default "$(pactl list short sinks 2>/dev/null | awk -v s="$TUNE_SINK" '$2==s{print $1; exit}')" 2>/dev/null || true

echo "==> 4/5 Verifying clean output (silent sine probe)"
PLAYING="$(pactl list sink-inputs 2>/dev/null | awk '
  /^Sink Input #/ { id = $3 }
  /node.name = "px13_speaker_tuning_output"/ { skip[id] = 1 }
  /Corked: no/ { uncorked[id] = 1 }
  END { for (i in uncorked) if (!(i in skip)) print i }')"
if [ -n "$PLAYING" ]; then
  echo "    Error: audio is playing (sink inputs: $PLAYING); quit all audio apps, then re-run." >&2
  exit 1
fi
PROBE="$(mktemp /tmp/px13-probe-XXXXXX.wav)"
trap 'rm -f "$PROBE"' EXIT
speaker-test -D pulse -t sine -f 440 -c2 >/dev/null 2>&1 &
SPKPID=$!
sleep 2
timeout 5 pw-record --target "$TUNE_SINK.monitor" --rate 48000 --channels 2 \
  --format f32 "$PROBE" >/dev/null 2>&1 || true
kill "$SPKPID" 2>/dev/null || true
wait "$SPKPID" 2>/dev/null || true
if ! python3 -c "
import array, math, sys
d = open('$PROBE','rb').read()
a = array.array('f', d[d.find(b'data')+8:])
L = a[0::2]; n = len(L)
peak = max(abs(x) for x in L); rms = (sum(x*x for x in L)/n)**0.5
w = 2*math.pi*440/48000; c = 2*math.cos(w); s0=s1=s2=0.0
seg = L[n//4:3*n//4]
for x in seg:
    s0 = x + c*s1 - s2; s2 = s1; s1 = s0
mag = ((s1*s1+s2*s2-c*s1*s2)/len(seg))**0.5
sys.exit(0 if (peak < 1.5 and mag/(rms+1e-9) > 0.7) else 1)
"; then
  echo "    Error: probe output is dirty; removing the tuning, raw speakers stay default." >&2
  rm -f "$DST"
  systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
  sleep 2
  pactl set-default-sink "$SPK_SINK" 2>/dev/null || true
  exit 1
fi
rm -f "$PROBE"
echo "    Probe clean (440 Hz tone, no clipping)"

echo "==> 5/5 Tuned sink is default"
echo "    Default sink = $TUNE_SINK (raw speakers stay available for A/B)"
echo
echo "    A/B: pactl set-default-sink $SPK_SINK  # raw"
echo "         pactl set-default-sink $TUNE_SINK  # tuned"
echo "    Remove: bash install-tuning.sh --uninstall"
