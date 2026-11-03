#!/usr/bin/env bash
# Test-Stub (tests/run.sh) für youtube.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_flags "$@"; need_device; load_conf
[[ $DRY_RUN == 1 ]] && { note "[dry-run] smarttube"; exit 0; }
"$ADB" -s "$SERIAL" install -r "$STUB_APKS/SmartTube_stable.apk" | tail -1
dev "pm disable-user --user 0 com.amazon.firetv.youtube" | tail -1
