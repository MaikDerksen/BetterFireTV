#!/usr/bin/env bash
# Testet BetterFireTV gegen einen simulierten Fire TV (tests/fake_adb.py), ohne echtes Gerät:
# Einrichten, Dock, Hintergrund und Rückgängig, jeweils für Fire OS 8 und Fire OS 5.
# Danach muss der simulierte Stick exakt im Ausgangszustand sein ("Unterschiede: 0").
# Braucht bash und python3 (Linux, WSL oder Git Bash).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bftv-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# dumbtv-Kopie, in der DNS-Filter und SmartTube durch Stubs ersetzt sind (die echten laden aus dem Netz).
cp -r "$REPO/vendor/dumbtv" "$WORK/dumbtv"
cp "$HERE/stubs/dnsfilter.sh" "$HERE/stubs/youtube.sh" "$WORK/dumbtv/scripts/"
mkdir -p "$WORK/apks"
echo fake > "$WORK/apks/dnsfilter.apk"
echo fake > "$WORK/apks/SmartTube_stable.apk"

export ADB="$HERE/fake_adb.py"
export FAKE_TV_STATE="$WORK/state.json" FAKE_TV_LOG="$WORK/adb.log" FAKE_TV_UNKNOWN="$WORK/unknown.log"
export BFTV_DUMBTV="$WORK/dumbtv" BFTV_BACKUPS="$WORK/backups" BFTV_LOGS="$WORK/logs"
export BFTV_DOWNLOADS="$WORK/downloads" BFTV_WALLDIR="$WORK/hintergruende" BFTV_CONFIG="$REPO/einstellungen.txt"
export BFTV_BILDER="$WORK/bilder"
export BFTV_REBOOT_WAIT=0 BFTV_SETTLE=0 BOOT_SECONDS=0 PM_WRITE_SECONDS=0 STUB_APKS="$WORK/apks"
T="$REPO/tool/betterfiretv.sh"
fail=0

for v in fos8 fos5; do
  rm -rf "$WORK/backups" "$WORK/logs" "$WORK/sdcard" "$WORK/hintergruende"
  mkdir -p "$WORK/sdcard" "$WORK/hintergruende"
  python3 "$HERE/make_state.py" "$WORK/state.json" "$WORK/sdcard" "$v" >/dev/null
  cp "$WORK/state.json" "$WORK/state-orig.json"
  printf 'kein echtes Bild' > "$WORK/hintergruende/urlaub.jpg"
  printf '\n== %s\n' "$v"
  yes j | bash "$T" einrichten --kandidaten 192.168.178.45 > "$WORK/einrichten.txt" 2>&1 || { echo "Einrichten fehlgeschlagen"; fail=1; }
  grep -E "!!|FEHLER" "$WORK/einrichten.txt" | grep -v "Kontrolle meldet" || true
  if [[ $v == fos8 ]]; then
    printf '2 1\n0\n' | bash "$T" startbildschirm > "$WORK/dock.txt" 2>&1 || { echo "Dock fehlgeschlagen"; fail=1; }
    printf 'n\n' | bash "$T" hintergrund --neu urlaub.jpg > "$WORK/bild.txt" 2>&1 || { echo "Hintergrund fehlgeschlagen"; fail=1; }
    bash "$T" screenshot < /dev/null > "$WORK/shot.txt" 2>&1 && [[ -s $WORK/bilder/startbildschirm.png ]] || { echo "Screenshot fehlgeschlagen"; fail=1; }
  else
    # Fire OS 5: kein eigener Startbildschirm, die Modi müssen sauber ablehnen
    printf '\n' | bash "$T" startbildschirm > "$WORK/dock.txt" 2>&1 && { echo "Dock hätte ablehnen müssen"; fail=1; }
    grep -q "Fire OS 5" "$WORK/dock.txt" || { echo "Ablehnung ohne Erklärung"; fail=1; }
  fi
  yes j | bash "$T" rueckgaengig > "$WORK/rueck.txt" 2>&1 || { echo "Rückgängig fehlgeschlagen"; fail=1; }
  python3 "$HERE/compare.py" "$WORK/state-orig.json" "$WORK/state.json" | tee "$WORK/cmp.txt"
  grep -q "Unterschiede: 0" "$WORK/cmp.txt" || fail=1
done
[[ $fail == 0 ]] && echo "Alles bestanden." || echo "FEHLER, Ausgaben in $WORK (wird beim Beenden gelöscht)."
exit $fail
