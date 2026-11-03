#!/usr/bin/env bash
# The HOME takeover helpers of launcher/install.sh. They use the caller's sh_ (adb shell),
# and set_futurity also its dev_sdk.

# Starts dumbtv home at the end of the install.
#
# `am start -W` waits until the activity has drawn, and a sleeping TV never draws it, so
# an install that ran while the TV fell asleep hung for ever. The TV is woken first (a
# no-op when it is awake), and the wait is bounded, $2 seconds (20 by default).
start_home() {
  local pid i bound=${2:-20}
  sh_ input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  sh_ am start -W -n "$1" >/dev/null 2>&1 &
  pid=$!
  for ((i = 0; i < bound; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  echo "note: dumbtv home did not draw within $bound s; is the TV asleep? Press a button on the remote."
  return 0
}

# Alarms normally fire no sooner than 5 s from now; the home switch needs them immediate.
# Android 11 and older read min_futurity from settings global alarm_manager_constants.
# Android 12 and later ignore that setting and read DeviceConfig alarm_manager instead.
# A min_futurity someone set before is kept in dumbtv_min_futurity, and --undo puts it back.
constants_futurity() {
  local cur
  cur=$(sh_ settings get global alarm_manager_constants | tr -d '\r')
  [[ $cur == null ]] && cur=
  if [[ $1 == get ]]; then
    printf '%s' "$cur" | tr ',' '\n' | sed -n 's/^min_futurity=//p' | head -1
    return
  fi
  cur=$(printf '%s' "$cur" | tr ',' '\n' | { grep -v '^min_futurity=' || true; } | paste -sd, -)
  if [[ -n ${2:-} ]]; then cur=${cur:+$cur,}min_futurity=$2; fi
  if [[ -n $cur ]]; then sh_ settings put global alarm_manager_constants "$cur" >/dev/null
  else sh_ settings delete global alarm_manager_constants >/dev/null; fi
}

config_futurity() {
  local cur
  case $1 in
    get) cur=$(sh_ device_config get alarm_manager min_futurity | tr -d '\r' || true)
         if [[ $cur != null ]]; then printf '%s' "$cur"; fi ;;
    put) if [[ -n ${2:-} ]]; then cur=$(sh_ device_config put alarm_manager min_futurity "$2" 2>&1) || true
         else cur=$(sh_ device_config delete alarm_manager min_futurity 2>&1) || true; fi
         # A build that refuses the shell this write still gets the takeover, only slower.
         if [[ $(config_futurity get) != "${2:-}" ]]; then
           echo "warning: could not set device_config alarm_manager min_futurity: ${cur:-no reason given}" >&2
         fi ;;
  esac
}

set_futurity() {
  local store=constants_futurity old saved
  if [[ $dev_sdk -ge 31 ]]; then store=config_futurity; fi
  old=$($store get)
  saved=$(sh_ settings get global dumbtv_min_futurity | tr -d '\r')
  [[ $saved == null ]] && saved=
  if [[ $1 == on ]]; then
    if [[ -n $old && $old != 0 && -z $saved ]]; then
      sh_ settings put global dumbtv_min_futurity "$old" >/dev/null
    fi
    $store put 0
    return
  fi
  if [[ $saved =~ ^[0-9]+$ ]]; then $store put "$saved"; else $store put ""; fi
  if [[ -n $saved ]]; then sh_ settings delete global dumbtv_min_futurity >/dev/null; fi
  # Installs before this split wrote min_futurity=0 into the Android 11 setting on newer
  # TVs as well. Only that value is ours to remove.
  if [[ $store == config_futurity && $(constants_futurity get) == 0 ]]; then
    constants_futurity put ""
  fi
}
