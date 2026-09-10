#!/usr/bin/env bash
# ProArt PX13 audio setup: kernel driver fix + speaker EQ.
#
#   bash install.sh                 # both (default)
#   bash install.sh --drivers-only  # speaker fix only, raw flat output
#   bash install.sh --tuning-only   # EQ only (needs working speakers)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  "")             bash "$REPO/install-drivers.sh"; echo; bash "$REPO/install-tuning.sh" ;;
  --drivers-only) bash "$REPO/install-drivers.sh" ;;
  --tuning-only)  bash "$REPO/install-tuning.sh" ;;
  *) echo "usage: bash install.sh [--drivers-only | --tuning-only]" >&2; exit 1 ;;
esac
