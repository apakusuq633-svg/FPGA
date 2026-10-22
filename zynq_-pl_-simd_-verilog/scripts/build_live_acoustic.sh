#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${DAS_ACTIVE_CHANNELS:-8}" != 8 ]; then
    echo 'Production requires the planar 8-microphone board.' >&2
    exit 1
fi
python3 scripts/build_planar8.py "$@"
