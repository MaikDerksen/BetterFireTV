#!/usr/bin/env bash
# Test-Stub (tests/run.sh) für dnsfilter.sh (STUB_DNS_MODE=ok|manual|fail|fail-adguard)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_flags "$@"; need_device; load_conf
[[ $DNSFILTER == 0 ]] && { note "DNSFILTER=0"; exit 0; }
step "plan"; note "stub upstream=${DNS_UPSTREAM:-router}"
[[ $DRY_RUN == 1 ]] && { note "[dry-run] dns"; exit 0; }
"$ADB" -s "$SERIAL" install -r "$STUB_APKS/dnsfilter.apk" | tail -1
dev "appops set dnsfilter.android ACTIVATE_VPN allow" >/dev/null
dev "dumpsys deviceidle whitelist +dnsfilter.android" >/dev/null
mode=${STUB_DNS_MODE:-ok}
[[ $mode == fail-adguard && -z ${DNS_UPSTREAM:-} ]] && mode=ok
if [[ $mode == manual ]]; then
  step "one manual step (Fire OS 8 hides the app's files from adb)"; note "..."; exit 0
fi
dev "settings put secure always_on_vpn_app dnsfilter.android" >/dev/null
reboot_wait
if [[ $mode == fail || $mode == fail-adguard ]]; then note "NOT BLOCKED"; exit 1; fi
note "filter is live"
