#!/usr/bin/env bash
# PX13 speaker EQ as a WirePlumber software-DSP replacement for the raw sink.
# Run as a regular user; sudo is only used to install lsp-plugins-lv2 if missing.
#
#   bash install-tuning.sh              # install + enable
#   bash install-tuning.sh --uninstall  # remove, restore raw speaker volume
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_SRC="$REPO/tunings/px13/filter-chain.conf"
RULE_SRC="$REPO/configs/px13-wireplumber.conf.in"
ROUTE_SCRIPT="$REPO/configs/px13-speaker-route.lua"
PW_CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
WP_DIR="$HOME/.config/wireplumber"
WP_CONF_DIR="$WP_DIR/wireplumber.conf.d"
LEGACY_DST="$PW_CONF_DIR/51-px13-speaker-tuning.conf"
RULE_DST="$WP_CONF_DIR/51-px13-speaker-tuning.conf"
GRAPH_DST="$WP_DIR/px13-speaker-dsp.conf"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/px13-audio-fix"
VOLUME_STATE="$STATE_DIR/original-speaker-volume"
WP_ROUTES_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/default-routes"
SPK_SINK="alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink"
TUNE_SINK="px13_speaker_tuning"

sink_visible() {
  pactl list short sinks 2>/dev/null |
    awk -v sink="$1" '$2 == sink { found=1 } END { exit !found }'
}

# True once WirePlumber has saved the Speaker route at 100%, unmuted.
speaker_route_saved() {
  grep -F 'alsa_card.pci-0000_c4_00.5-platform-amd_sdw:output:' "$WP_ROUTES_STATE" 2>/dev/null |
    grep -F 'Speaker=' |
    grep -Eq '"channelVolumes":\[1\.0+, 1\.0+\].*"mute":false'
}

is_managed_file() {
  local path=$1
  [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
  grep -q '^# Managed by px13-audio-fix' "$path" 2>/dev/null && return 0
  if [ "$path" = "$GRAPH_DST" ] &&
      grep -Eq 'node\.name[[:space:]]*=[[:space:]]*"px13_speaker_tuning"' "$path" &&
      grep -Fq "target.object = \"$SPK_SINK\"" "$path"; then
    return 0
  fi
  [ "$path" = "$LEGACY_DST" ] &&
    grep -q '^# PX13 speaker EQ:' "$path" 2>/dev/null && return 0
  return 1
}

restore_saved_volume() {
  local volume mute
  [ -r "$VOLUME_STATE" ] || return 0
  volume="$(sed -n '1p' "$VOLUME_STATE")"
  mute="$(sed -n '2p' "$VOLUME_STATE")"
  if [[ "$volume" =~ ^[0-9]+([.][0-9]+)?%$ ]] &&
      [[ "$mute" = yes || "$mute" = no ]]; then
    pactl set-sink-volume "$SPK_SINK" "$volume"
    pactl set-sink-mute "$SPK_SINK" "$mute"
  else
    echo "    Error: saved speaker-volume state is invalid: $VOLUME_STATE" >&2
    return 1
  fi
}

if [ "${1:-}" = "--uninstall" ]; then
  for path in "$RULE_DST" "$GRAPH_DST" "$LEGACY_DST"; do
    if ! is_managed_file "$path"; then
      echo "    Error: refusing to remove unowned config: $path" >&2
      exit 1
    fi
  done

  echo "==> Removing PX13 speaker tuning"
  rm -f -- "$RULE_DST" "$GRAPH_DST" "$LEGACY_DST"
  systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
  for _ in $(seq 1 20); do
    sink_visible "$SPK_SINK" && break
    sleep 0.5
  done
  if ! sink_visible "$SPK_SINK"; then
    echo "    Error: raw speaker sink did not return; saved volume state was kept." >&2
    exit 1
  fi
  restore_saved_volume
  pactl set-default-sink "$SPK_SINK"
  rm -f -- "$VOLUME_STATE"
  rmdir "$STATE_DIR" 2>/dev/null || true
  echo "    Removed tuning; raw speaker sink restored"
  exit 0
fi

echo "==> 1/6 Prerequisites"
for cmd in pipewire wireplumber wpexec pactl systemctl pw-play pw-record timeout python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "    Error: required command '$cmd' not found." >&2
    exit 1
  }
done
WP_VERSION="$(wireplumber --version 2>/dev/null |
  sed -nE 's/.*libwireplumber ([0-9]+(\.[0-9]+)+).*/\1/p' | head -n 1)"
IFS=. read -r WP_MAJOR WP_MINOR _ <<< "$WP_VERSION"
if [[ ! "${WP_MAJOR:-}" =~ ^[0-9]+$ || ! "${WP_MINOR:-}" =~ ^[0-9]+$ ]] ||
    (( 10#$WP_MAJOR == 0 && 10#$WP_MINOR < 5 )); then
  echo "    Error: this setup requires WirePlumber 0.5 or newer (found '${WP_VERSION:-unknown}')." >&2
  exit 1
fi

have_limiter=0
if [ -d /usr/lib/lv2/lsp-plugins-lv2.lv2 ] || [ -d /usr/lib/lv2/lsp-plugins.lv2 ]; then
  have_limiter=1
fi
for dir in /usr/lib/lv2 /usr/local/lib/lv2 "$HOME/.lv2"; do
  if [ -d "$dir" ] && find "$dir" -maxdepth 2 -iname '*limiter*' 2>/dev/null | grep -q .; then
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

echo "==> 2/6 Checking the speaker sink and idle state"
RAW_VISIBLE=0
if sink_visible "$SPK_SINK"; then
  RAW_VISIBLE=1
elif sink_visible "$TUNE_SINK" && [ -f "$RULE_DST" ] && [ -f "$GRAPH_DST" ] && [ -f "$VOLUME_STATE" ]; then
  : # already installed; re-installing re-applies the files and route volume
else
  echo "    Error: raw HiFi Speaker sink '$SPK_SINK' not found." >&2
  echo "    Run 'bash install-drivers.sh' first, then re-run this script." >&2
  exit 1
fi
PLAYING="$(pactl list sink-inputs 2>/dev/null | awk '
  /^Sink Input #/ { id = $3 }
  /Corked: no/ { uncorked[id] = 1 }
  END { for (i in uncorked) print i }')"
if [ -n "$PLAYING" ]; then
  echo "    Error: audio is playing (sink inputs: $PLAYING); quit all audio apps, then re-run." >&2
  exit 1
fi
for path in "$RULE_DST" "$GRAPH_DST" "$LEGACY_DST"; do
  if ! is_managed_file "$path"; then
    echo "    Error: refusing to overwrite unowned config: $path" >&2
    exit 1
  fi
done
echo "    Speaker sink present; no active playback"

ORIGINAL_DEFAULT="$(pactl get-default-sink 2>/dev/null || true)"
if [ "$RAW_VISIBLE" = 1 ]; then
  ROLLBACK_VOLUME="$(LC_ALL=C pactl get-sink-volume "$SPK_SINK" 2>/dev/null |
    awk -F/ 'NR == 1 { gsub(/[[:space:]]/, "", $2); print $2 }')"
  ROLLBACK_MUTE="$(LC_ALL=C pactl get-sink-mute "$SPK_SINK" 2>/dev/null | awk '{ print $2 }')"
else
  ROLLBACK_VOLUME=100%
  ROLLBACK_MUTE=no
fi
if [[ ! "$ROLLBACK_VOLUME" =~ ^[0-9]+([.][0-9]+)?%$ ]] ||
    [[ "$ROLLBACK_MUTE" != yes && "$ROLLBACK_MUTE" != no ]]; then
  echo "    Error: could not read the raw speaker volume/mute state." >&2
  exit 1
fi

echo "==> 3/6 Preparing the replacement sink"
mkdir -p "$PW_CONF_DIR" "$WP_CONF_DIR" "$STATE_DIR"
BACKUP_DIR="$(mktemp -d "$STATE_DIR/.install-backup.XXXXXX")"
TMP_GRAPH=""
TMP_RULE=""
TMP_STATE=""
PROBE=""
PROBE_IN=""
PLAYPID=""
HAD_LEGACY=0
HAD_RULE=0
HAD_GRAPH=0
INSTALLED=0
VOLUME_CHANGED=0
STATE_CREATED=0

finish_install() {
  local status=$?
  trap - EXIT

  if [ -n "$PLAYPID" ]; then
    kill "$PLAYPID" 2>/dev/null || true
    wait "$PLAYPID" 2>/dev/null || true
  fi

  if [ "$status" -ne 0 ] && [ "$INSTALLED" = 1 ]; then
    echo "    Install failed; restoring the previous audio configuration." >&2
    if [ "$HAD_LEGACY" = 1 ]; then
      mv -f -- "$BACKUP_DIR/legacy" "$LEGACY_DST" || echo "    Warning: could not restore $LEGACY_DST" >&2
    else
      rm -f -- "$LEGACY_DST" || true
    fi
    if [ "$HAD_RULE" = 1 ]; then
      mv -f -- "$BACKUP_DIR/rule" "$RULE_DST" || echo "    Warning: could not restore $RULE_DST" >&2
    else
      rm -f -- "$RULE_DST" || true
    fi
    if [ "$HAD_GRAPH" = 1 ]; then
      mv -f -- "$BACKUP_DIR/graph" "$GRAPH_DST" || echo "    Warning: could not restore $GRAPH_DST" >&2
    else
      rm -f -- "$GRAPH_DST" || true
    fi
    systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true
    for _ in $(seq 1 20); do
      sink_visible "$SPK_SINK" && break
      sleep 0.5
    done
    if [ "$VOLUME_CHANGED" = 1 ]; then
      pactl set-sink-volume "$SPK_SINK" "$ROLLBACK_VOLUME" 2>/dev/null || true
      pactl set-sink-mute "$SPK_SINK" "$ROLLBACK_MUTE" 2>/dev/null || true
    fi
    if [ -n "$ORIGINAL_DEFAULT" ]; then
      pactl set-default-sink "$ORIGINAL_DEFAULT" 2>/dev/null || true
    fi
  fi

  [ -z "$TMP_GRAPH" ] || rm -f -- "$TMP_GRAPH" || true
  [ -z "$TMP_RULE" ] || rm -f -- "$TMP_RULE" || true
  [ -z "$TMP_STATE" ] || rm -f -- "$TMP_STATE" || true
  [ -z "$PROBE" ] || rm -f -- "$PROBE" || true
  [ -z "$PROBE_IN" ] || rm -f -- "$PROBE_IN" || true
  rm -f -- "$BACKUP_DIR/legacy" "$BACKUP_DIR/rule" "$BACKUP_DIR/graph" || true
  rmdir "$BACKUP_DIR" 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ "$STATE_CREATED" = 1 ]; then
    rm -f -- "$VOLUME_STATE"
    rmdir "$STATE_DIR" 2>/dev/null || true
  fi
  exit "$status"
}
trap finish_install EXIT

if [ -e "$LEGACY_DST" ] || [ -L "$LEGACY_DST" ]; then
  HAD_LEGACY=1
  cp -a -- "$LEGACY_DST" "$BACKUP_DIR/legacy"
fi
if [ -e "$RULE_DST" ] || [ -L "$RULE_DST" ]; then
  HAD_RULE=1
  cp -a -- "$RULE_DST" "$BACKUP_DIR/rule"
fi
if [ -e "$GRAPH_DST" ] || [ -L "$GRAPH_DST" ]; then
  HAD_GRAPH=1
  cp -a -- "$GRAPH_DST" "$BACKUP_DIR/graph"
fi

if [ ! -f "$VOLUME_STATE" ]; then
  TMP_STATE="$(mktemp "$STATE_DIR/.speaker-volume.XXXXXX")"
  printf '%s\n%s\n' "$ROLLBACK_VOLUME" "$ROLLBACK_MUTE" > "$TMP_STATE"
  chmod 600 "$TMP_STATE"
  mv -f -- "$TMP_STATE" "$VOLUME_STATE"
  TMP_STATE=""
  STATE_CREATED=1
fi

FILTER_PATH_ESCAPED=${GRAPH_DST//\\/\\\\}
FILTER_PATH_ESCAPED=${FILTER_PATH_ESCAPED//&/\\&}
FILTER_PATH_ESCAPED=${FILTER_PATH_ESCAPED//|/\\|}
TMP_GRAPH="$(mktemp "$WP_DIR/.px13-speaker-dsp.XXXXXX")"
cp "$GRAPH_SRC" "$TMP_GRAPH"
chmod 644 "$TMP_GRAPH"
TMP_RULE="$(mktemp "$WP_CONF_DIR/.51-px13-speaker-tuning.XXXXXX")"
sed "s|@FILTER_PATH@|$FILTER_PATH_ESCAPED|g" "$RULE_SRC" > "$TMP_RULE"
chmod 644 "$TMP_RULE"

echo "==> 4/6 Installing WirePlumber software-DSP rule"
INSTALLED=1
mv -f -- "$TMP_GRAPH" "$GRAPH_DST"
TMP_GRAPH=""
mv -f -- "$TMP_RULE" "$RULE_DST"
TMP_RULE=""
rm -f -- "$LEGACY_DST"
systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || true

FOUND=""
for _ in $(seq 1 20); do
  if sink_visible "$TUNE_SINK" && ! sink_visible "$SPK_SINK"; then
    FOUND=1
    break
  fi
  sleep 0.5
done
if [ -z "$FOUND" ]; then
  echo "    Error: replacement sink did not appear with the raw AMD sink hidden." >&2
  echo "    Check 'journalctl --user -u wireplumber' for software-DSP errors." >&2
  exit 1
fi

# The raw sink is hidden from clients now, so set its hardware volume through
# the card's Speaker route, and wait until WirePlumber has saved it (it saves
# with a delay; restarting before that would bring the old volume back).
VOLUME_CHANGED=1
timeout 10 wpexec "$ROUTE_SCRIPT" | sed 's/^/    /'
SAVED=""
for _ in $(seq 1 20); do
  if speaker_route_saved; then
    SAVED=1
    break
  fi
  sleep 0.5
done
if [ -z "$SAVED" ]; then
  echo "    Error: WirePlumber did not save the 100% speaker route volume." >&2
  exit 1
fi
echo "    Only the tuned speaker sink is exposed; AMD hardware volume is 100% (saved)"

echo "==> 5/6 Verifying tuned output"
# A quiet 440 Hz tone goes into the tuned sink and is recorded at the filter
# output, after the EQ and limiter. The gain must match the EQ curve, which
# proves the graph is loaded and in the signal path.
TUNE_VOLUME="$(LC_ALL=C pactl get-sink-volume "$TUNE_SINK" | awk -F/ 'NR == 1 { gsub(/[[:space:]]/, "", $2); print $2 }')"
TUNE_MUTE="$(LC_ALL=C pactl get-sink-mute "$TUNE_SINK" | awk '{ print $2 }')"
pactl set-sink-volume "$TUNE_SINK" 100%
pactl set-sink-mute "$TUNE_SINK" 0
PROBE_IN="$(mktemp "${TMPDIR:-/tmp}/px13-probe-in-XXXXXX.wav")"
PROBE="$(mktemp "${TMPDIR:-/tmp}/px13-probe-XXXXXX.wav")"
python3 -c '
import math, struct, sys, wave
fs, amp = 48000, 10 ** (-30 / 20)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(fs)
    w.writeframes(b"".join(
        struct.pack("<hh", *(int(32767 * amp * math.sin(2 * math.pi * 440 * i / fs)),) * 2)
        for i in range(fs * 4)))
' "$PROBE_IN"
pw-play --target "$TUNE_SINK" "$PROBE_IN" >/dev/null 2>&1 &
PLAYPID=$!
sleep 0.7
timeout 2 pw-record --target "${TUNE_SINK}_output" --rate 48000 --channels 2 \
  --format f32 "$PROBE" >/dev/null 2>&1 || true
wait "$PLAYPID" 2>/dev/null || true
PLAYPID=""
pactl set-sink-volume "$TUNE_SINK" "$TUNE_VOLUME" 2>/dev/null || true
pactl set-sink-mute "$TUNE_SINK" "$TUNE_MUTE" 2>/dev/null || true
if ! python3 -c '
import array, cmath, math, re, sys

fs, f = 48000, 440.0
d = open(sys.argv[1], "rb").read()
offset = d.find(b"data")
if offset < 0:
    sys.exit("no data in recording")
a = array.array("f", d[offset + 8:])
if len(a) < 2 * fs // 2:
    sys.exit("recording too short")

# EQ response at f from the installed graph (left chain, RBJ peaking).
graph = open(sys.argv[2]).read()
bands = re.findall(r"name = e\d+_l label = bq_peaking +control = \{ \"Freq\" = ([\d.]+) \"Q\" = ([\d.]+) \"Gain\" = ([-\d.]+)", graph)
z = cmath.exp(-1j * 2 * math.pi * f / fs)
h = 1
for f0, q, g in bands:
    A = 10 ** (float(g) / 40)
    w0 = 2 * math.pi * float(f0) / fs
    al = math.sin(w0) / (2 * float(q))
    c = -2 * math.cos(w0)
    h *= ((1 + al * A) + c * z + (1 - al * A) * z * z) / ((1 + al / A) + c * z + (1 - al / A) * z * z)
expected = 20 * math.log10(abs(h))
in_rms = 10 ** (-30 / 20) / math.sqrt(2)

for ch in (a[0::2], a[1::2]):
    seg = ch[len(ch) // 4:3 * len(ch) // 4]
    rms = (sum(x * x for x in seg) / len(seg)) ** 0.5
    k = 2 * math.cos(2 * math.pi * f / fs)
    s1 = s2 = 0.0
    for x in seg:
        s1, s2 = x + k * s1 - s2, s1
    tone = math.sqrt(2 * max(s1 * s1 + s2 * s2 - k * s1 * s2, 0)) / len(seg)
    gain = 20 * math.log10(rms / in_rms + 1e-12)
    if tone / (rms + 1e-12) < 0.9 or abs(gain - expected) > 1.0:
        sys.exit("gain %.1f dB (EQ expects %.1f dB), tone purity %.2f" % (gain, expected, tone / (rms + 1e-12)))
print("    Probe clean: 440 Hz at %+.1f dB through the EQ (expected %+.1f dB)" % (gain, expected))
' "$PROBE" "$GRAPH_DST"; then
  echo "    Error: the tuned output did not carry the EQ-processed probe tone." >&2
  exit 1
fi
rm -f -- "$PROBE" "$PROBE_IN"
PROBE=""
PROBE_IN=""

echo "==> 6/6 Tuned speaker is default"
if ! pactl set-default-sink "$TUNE_SINK" 2>/dev/null; then
  echo "    Error: could not make '$TUNE_SINK' the default sink." >&2
  exit 1
fi
echo "    Desktop volume now controls the tuned sink; the hidden AMD sink stays at 100%."
echo "    A/B is disabled to avoid bypassing the tuning. Uninstall to restore raw output."
echo "    Remove: bash install-tuning.sh --uninstall"
