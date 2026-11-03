#!/usr/bin/env bash
# Read-only. Prints what the TV is and what the full pass would change.
# Usage: ./scripts/preflight.sh [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_flags "$@"
need_device
load_conf
mkdir -p "$REPORT"

step "device"
note "serial        $SERIAL"
note "manufacturer  $(dev1 getprop ro.product.manufacturer)"
note "model         $(dev1 getprop ro.product.model)"
note "build         $(dev1 getprop ro.build.display.id)"
note "android       $(dev1 getprop ro.build.version.release) (sdk $(dev1 getprop ro.build.version.sdk))"
note "kernel        $(dev1 uname -r)"
note "abi           $(dev1 getprop ro.product.cpu.abi)"
note "verified boot $(dev1 getprop ro.boot.verifiedbootstate)  (1 = locked, cannot be changed)"
note "gateway       $(gateway)"

if is_fireos; then
  note "platform      $(fireos_name)"
  note "lists         ${DATA#$ROOT/}/$(basename "$(dirname "$(fos packages.txt)")")"
  if [[ $SDK -lt 28 ]]; then
    note "fire os 6     own package lists, no RUN_ANY_IN_BACKGROUND, and HOME is held by the"
    note "              launcher's Keeper because 6.7 refuses accessibility services"
  fi
else
  note "platform      NOT Amazon hardware — read docs/OTHER-TVS.md before running debloat.sh"
fi

step "current state"
note "packages      $(dev 'pm list packages' | wc -l | tr -d ' ') installed, $(dev 'pm list packages -d' | wc -l | tr -d ' ') disabled"
note "third-party   $(dev 'pm list packages -3' | sed 's/package://' | grep -vc overlay) apps"
note "home screen   $(front_activity | awk -F/ '{print $1}')"
note "free ram      $(dev 'dumpsys meminfo' | sed -n 's/.*Free RAM: *\([0-9,]*K\).*/\1/p' | head -1)"
note "dns filter    $(present dnsfilter.android && echo installed || echo 'not installed')"
note "launcher      $(present tv.dumbtv.home && echo 'dumbtv home installed' || echo 'not installed')"

step "the pass would"
note "disable $(cleanup_list | wc -l | tr -d ' ') Amazon packages, minus anything in never-disable.txt"
# debloat.sh removes only the apps named in dumbtv.conf, never the whole user-apps.txt.
if [[ -n $REMOVE_EXTRA ]]; then note "remove only the apps you named: $REMOVE_EXTRA"
else note "remove none of your apps (none named in dumbtv.conf)"; fi
note "deny background work + data to $(list_of "$(fos protected.txt)" | wc -l | tr -d ' ') protected packages"
note "apply $(list_of "$(fos settings.txt)" | wc -l | tr -d ' ') privacy settings"
if [[ $DNSFILTER == 1 ]]; then
  note "install a DNS filter that blocks Amazon telemetry$([[ $ALEXA == 0 ]] && printf ', Alexa') and the OTA servers"
fi
if [[ $LAUNCHER == 1 ]]; then
  note "replace the home screen with dumbtv home (this repo's own launcher, no internet access)"
fi
note "reboot twice (about 5 minutes)"

step "not touched, ever"
note "/system (dm-verity), the bootloader, the launcher package itself, settings, TV input, device control, Bluetooth pairing"
note "see ${DATA#$ROOT/}/$(basename "$(dirname "$(fos never-disable.txt)")")/never-disable.txt"

step "snapshot before anything changes"
if [[ $DRY_RUN == 0 ]]; then
  # Only the first run counts: later runs would snapshot the already-tightened
  # values and destroy the originals restore.sh needs.
  if [[ -f $REPORT/settings-before-secure.txt ]]; then
    note "settings snapshot already exists, keeping the original"
  else
    dev 'settings list secure' > "$REPORT/settings-before-secure.txt" 2>/dev/null || true
    dev 'settings list global' > "$REPORT/settings-before-global.txt" 2>/dev/null || true
    note "saved to report/ (git-ignored) so restore.sh can put the exact values back"
  fi
else
  note "[dry-run] would snapshot secure and global settings into report/"
fi

step "next"
note "./scripts/all.sh            full pass (asks first)"
note "./scripts/debloat.sh --dry-run   see the exact package commands"
