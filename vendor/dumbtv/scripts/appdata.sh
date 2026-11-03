#!/usr/bin/env bash
# Puts files into an app's own folder on Android 11, where adb may not write
# /sdcard/Android/data/<pkg>. An `adb restore` archive can carry them: Android unpacks it
# as the app itself, after clearing the app's data. Sourced by dnsfilter.sh; uses the
# caller's dev, note, ADB and SERIAL. Must stay bash 3.2 compatible.

# app_data_archive OUT PKG VERSION_CODE SDK SIGNER SRC SUBDIR
# Writes OUT, an uncompressed backup whose files from SRC land in
# /sdcard/Android/data/PKG/files/SUBDIR. Android accepts it only for the installed
# package signed by SIGNER (hex DER certificate) at VERSION_CODE or newer.
app_data_archive() {
  local out=$1 pkg=$2 code=$3 sdk=$4 signer=$5 src=$6 sub=$7 stage
  stage=$(dirname "$out")/appdata-stage
  mkdir -p "$stage/apps/$pkg/ef"
  cp -R "$src" "$stage/apps/$pkg/ef/$sub"
  # Format version, package, versionCode, platform sdk, installer, has-APK, signatures.
  printf '1\n%s\n%s\n%s\n\n0\n1\n%s\n' "$pkg" "$code" "$sdk" "$signer" > "$stage/apps/$pkg/_manifest"
  # Android's reader knows plain ustar entries only, and wants the manifest first.
  # COPYFILE_DISABLE keeps macOS tar from adding ._ metadata files.
  (cd "$stage" && COPYFILE_DISABLE=1 tar --format=ustar -cf body.tar "apps/$pkg/_manifest" "apps/$pkg/ef/$sub") ||
    return 1
  { printf 'ANDROID BACKUP\n5\n0\nnone\n'; cat "$stage/body.tar"; } > "$out"
}

restore_count() { dev 'logcat -d -s BackupManagerService' | grep -cE "$1"; }

# adb restore does nothing, silently, unless Android's backup service runs for the user. Some
# Fire OS 8 builds leave it out ("Can't find service: backup") or keep it "Inactive", and only
# a system app can switch it on. "Backup Manager is disabled" still restores: that switch is
# for scheduled backups.
backup_active() {
  local first
  first=$(dev 'dumpsys backup' | head -1 | tr -d '\r')
  [[ $first == "Backup Manager is "* ]]
}

# restore_app_data ARCHIVE
# Runs `adb restore` and answers the TV's confirmation by tapping "Restore my data" where a
# uiautomator dump places it. Keys are the second try: the dialog's password field keeps any
# key it gets once it has focus. Android drops a request nobody answers within 60 s. Android logs "processing complete" even for a
# refused or timed-out request, so success also needs its "taking data" line and no read
# error. Returns 0 when the TV reports all three.
restore_app_data() {
  local ab=$1 pid i done0 took0 fail0 asked=0
  done0=$(restore_count 'adb restore processing complete')
  took0=$(restore_count 'taking data')
  fail0=$(restore_count 'ErrnoException|timed out waiting for user confirmation')
  # A dialog left from an earlier request that timed out would take the keys meant for this one.
  dev am force-stop com.android.backupconfirm >/dev/null 2>&1
  "$ADB" -s "$SERIAL" restore "$ab" >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 40); do
    confirmation_shown && break
    kill -0 "$pid" 2>/dev/null || { note "adb restore ended before the TV showed its confirmation"; return 1; }
    sleep 0.5
  done
  # The window has focus before its buttons reach the accessibility tree, so an early dump
  # still shows the screen behind it.
  for i in 1 2 3 4 5; do
    sleep 1.5
    tap_allow && sleep 2
    confirmation_shown || break
  done
  if confirmation_shown; then
    for i in 1 2 3 4; do
      allow_focused && break
      dev input keyevent KEYCODE_TAB >/dev/null 2>&1
      sleep 0.7
    done
    allow_focused && dev input keyevent KEYCODE_DPAD_CENTER >/dev/null 2>&1
    sleep 2
  fi
  if confirmation_shown; then
    asked=1
    note "on the TV: choose RESTORE MY DATA (within a minute)"
  fi
  for i in $(seq 1 90); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null
  # The TV can still be unpacking after adb has sent everything.
  for i in $(seq 1 30); do
    [[ $(restore_count 'adb restore processing complete') -gt $done0 ]] && break
    sleep 1
  done
  [[ $(restore_count 'adb restore processing complete') -gt $done0 ]] || return 1
  [[ $(restore_count 'taking data') -gt $took0 ]] || return 1
  [[ $(restore_count 'ErrnoException|timed out waiting for user confirmation') -eq $fail0 ]] || return 1
  [[ $asked == 1 ]] && note "confirmed on the TV"
  return 0
}

# Full outputs are captured before matching: under pipefail, grep -q ending the read early
# makes the whole check fail.
confirmation_shown() {
  local focus
  focus=$(dev dumpsys window | grep 'mCurrentFocus=')
  [[ $focus == *BackupRestoreConfirmation* ]]
}

tap_allow() {
  local ui re='resource-id="com\.android\.backupconfirm:id/button_allow"[^>]*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"'
  ui=$(dev 'uiautomator dump /sdcard/dumbtv-ui.xml >/dev/null 2>&1; cat /sdcard/dumbtv-ui.xml; rm -f /sdcard/dumbtv-ui.xml')
  [[ $ui =~ $re ]] || return 1
  dev input tap $(( (BASH_REMATCH[1] + BASH_REMATCH[3]) / 2 )) $(( (BASH_REMATCH[2] + BASH_REMATCH[4]) / 2 )) >/dev/null 2>&1
}

# The flag groups of a dumpsys view line: the second one starts ".F" when the view has focus.
allow_focused() {
  local top
  top=$(dev dumpsys activity top | grep 'app:id/button_allow')
  [[ $top =~ \ [A-Z.]{9}\ .F ]]
}
