#!/usr/bin/env bash
# Read-only inventory for a TV this repo has no verified package list for
# (Android TV today, or an unfamiliar Fire OS build).
#
# It changes nothing on the device. It lists the installed packages, flags the
# ones whose names look like ads/analytics/promo, and writes a paste-ready block
# for data/<platform>/packages.txt — commented out, because a package name that
# merely looks like telemetry is not evidence.
#
# Usage: ./scripts/discover.sh [--dry-run]
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
parse_flags "$@"
need_device

PLATFORM=$(if is_fireos; then echo fireos; else echo androidtv; fi)
MODEL=$(dev1 getprop ro.product.model)
ANDROID=$(dev1 getprop ro.build.version.release)
NEVER=$DATA/$PLATFORM/never-disable.txt
[[ $PLATFORM == fireos ]] && NEVER=$(fos never-disable.txt)
[[ -f $NEVER ]] || NEVER=$DATA/fireos/never-disable.txt
OUT="$REPORT/discover-$PLATFORM-$(date +%Y%m%d-%H%M).txt"
mkdir -p "$REPORT"

step "inventory"
note "platform  $PLATFORM"
note "model     $MODEL"
note "android   $ANDROID"

# One call, package + apk path, plus the disabled set.
all=$(dev 'pm list packages -f' | sed 's/^package://' | tr -d '\r')
dis=$(dev 'pm list packages -d' | sed 's/^package://' | tr -d '\r')
third=$(dev 'pm list packages -3' | sed 's/^package://' | tr -d '\r')
total=$(printf '%s\n' "$all" | grep -c . || true)
[[ -z $all ]] && die "no packages read from the device"

never_list=$(list_of "$NEVER" | awk '{print $1}')

is_never() { printf '%s\n' "$never_list" | grep -qx "$1"; }
is_third() { printf '%s\n' "$third" | grep -qx "$1"; }
is_disabled() { printf '%s\n' "$dis" | grep -qx "$1"; }

# Names that usually mean ads, measurement or vendor promo. Deliberately broad:
# this list produces candidates for a human to review, never actions.
CANDIDATE='(^|\.)(ads?|adservice|advert|advertising|analytics|metrics?|telemetry|tracking|tracker|crash|logger|logging|promo|weblab|experiment|abtest|attribution|referrer|recommendations?|suggestions?)(\.|$)'
# Never suggested, whatever the name says.
ESSENTIAL='^(android|com\.android\.(systemui|settings|packageinstaller|permissioncontroller|shell|providers\..*)|com\.google\.android\.(gms|gsf|vending)|com\.amazon\.(tv\.launcher|tv\.settings.*|tv\.inputpreference\.service|tv\.routing|tv\.devicecontrol.*|tv\.keypolicymanager|firehomestarter|fireinputdevices|autopairservice|device\.bluetoothpa|device\.blepa|whisperjoin\..*|tv\.oobe|tv\.ooberesource|webview\.chromium|venezia))$'

cand=""
# `pm list packages -f` prints package:/path/to/base.apk=com.pkg, so the package
# is after the last '=' and the path before it.
for line in $all; do
  pkg=${line##*=}
  path=${line%=*}
  [[ -z $pkg || $pkg == "$line" ]] && continue
  printf '%s' "$pkg" | grep -Eq "$ESSENTIAL" && continue
  is_never "$pkg" && continue
  if printf '%s' "$pkg" | grep -Eqi "$CANDIDATE"; then
    state=installed; is_disabled "$pkg" && state=disabled
    is_third "$pkg" && kind=third-party || kind=system
    cand="$cand$(printf '%-58s %-12s %-10s %s\n' "$pkg" "$kind" "$state" "${path##*/}")"$'\n'
  fi
done

count=$(printf '%s' "$cand" | grep -c . || true)

{
  printf '# dumbtv discover — %s\n' "$(date '+%Y-%m-%d %H:%M')"
  printf '# model: %s · android %s · platform %s\n' "$MODEL" "$ANDROID" "$PLATFORM"
  printf '# %s packages total, %s third-party, %s disabled\n' "$total" "$(printf '%s\n' "$third" | grep -c .)" "$(printf '%s\n' "$dis" | grep -c .)"
  printf '#\n# Nothing below has been changed. Every line is a suggestion to verify.\n\n'
  printf 'likely ads / telemetry / promo (%s):\n' "$count"
  printf '%s' "$cand"
  printf '\n# Paste-ready block. Uncomment only what you verified on this device,\n'
  printf '# then put it in data/%s/packages.txt with a note of what each one did.\n' "$PLATFORM"
  printf '%s' "$cand" | while read -r pkg rest; do
    [[ -n $pkg ]] && printf '# %-58s %s\n' "$pkg" "$rest"
  done
} > "$OUT"

step "result"
note "candidates $count of $total packages"
note "report     ${OUT#$ROOT/}"
note ""
note "next: verify a few candidates by hand (disable one, watch for breakage),"
note "      fill in data/$PLATFORM/packages.txt, then run ./scripts/contribute.sh"

printf '\n%s\n\n' "$(printf '%s' "$cand" | head -20)"
