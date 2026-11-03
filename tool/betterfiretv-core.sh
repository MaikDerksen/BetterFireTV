#!/usr/bin/env bash
# (Wird von tool/betterfiretv.sh eingelesen, nicht direkt starten.)
# BetterFireTV: macht einen Fire TV Stick werbefrei, schneller und gibt ihm einen
# Startbildschirm im Apple-TV-Look. Ohne Root, alles umkehrbar.
#
# Normalerweise über die .cmd-Dateien im Hauptordner gestartet. Direkt:
#   tool/betterfiretv.sh einrichten   [--ip ADRESSE] [--kandidaten "IP IP"] [-y] [--trockenlauf]
#   tool/betterfiretv.sh rueckgaengig [--ip ADRESSE] [-y]
#   tool/betterfiretv.sh backup       [--ip ADRESSE]
#   tool/betterfiretv.sh status       [--ip ADRESSE]
#   tool/betterfiretv.sh startbildschirm [--ip ADRESSE]          Dock und ausgeblendete Apps
#   tool/betterfiretv.sh hintergrund  [--ip ADRESSE] [--neu "a.jpg b.jpg"]
#   tool/betterfiretv.sh screenshot   [--ip ADRESSE]          Bild vom Startbildschirm fürs README
#
# Die eigentliche Arbeit (Debloat, Sperren, DNS-Filter, SmartTube, Restore) machen die
# getesteten Skripte von dumbtv (vendor/dumbtv, MIT). Dieses Skript ergänzt:
# Gerätesuche, ein vollständiges Rollback-Backup vor jeder Änderung, den Startbildschirm
# (home/, eine Fassung von FireFrame, MIT) und eine Rücksetzung auf exakt den
# gesicherten Zustand.
set -uo pipefail

VERSION=1.0.0
CORE_FILE=${BASH_SOURCE[0]}
TOOL=$(cd "$(dirname "$CORE_FILE")" && pwd)
ROOT=$(cd "$TOOL/.." && pwd)
DUMBTV=${BFTV_DUMBTV:-$ROOT/vendor/dumbtv}
CONFIG=${BFTV_CONFIG:-$ROOT/einstellungen.txt}
BACKUPS=${BFTV_BACKUPS:-$ROOT/backups}
LOGDIR=${BFTV_LOGS:-$ROOT/logs}
WALLDIR=${BFTV_WALLDIR:-$ROOT/hintergruende}
ADB=${ADB:-adb}
TVDIR=/sdcard/BetterFireTV
REBOOT_WAIT=${BFTV_REBOOT_WAIT:-25}

# Git Bash (MSYS2) würde Argumente wie /sdcard/... in Windows-Pfade umschreiben.
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/sdcard;/data;/storage;/system;/proc;/vendor"
case $(uname -s 2>/dev/null) in MINGW*|MSYS*) export PATH="/usr/bin:/mingw64/bin:$PATH" ;; esac

# --- Startbildschirm im Apple-TV-Look ----------------------------------------------------
# BetterFireTV-Fassung von FireFrame (MIT): Quelltext und fertige APK in home/.
HOME_PKG=tv.betterfiretv.home
HOME_SVC=$HOME_PKG/com.fireframe.home.HomeService
HOME_ACT=$HOME_PKG/com.fireframe.home.MainActivity
HOME_APK=${BFTV_HOME_APK:-$ROOT/home/betterfiretv-home.apk}
HOME_MEDIA=/sdcard/Android/media/$HOME_PKG
# Das Original-FireFrame aus früheren Läufen wird ersetzt.
FF_PKG=com.fireframe.home
FF_SVC=$FF_PKG/$FF_PKG.HomeService

# Apps, die nur dieses Tool auf den Stick bringt. "Rückgängig" entfernt sie wieder,
# sofern sie im Original-Backup nicht vorhanden waren.
OUR_APPS="$HOME_PKG $FF_PKG org.smarttube.stable tv.dumbtv.home"
VPN_APP=dnsfilter.android
EXTRAS=""

# Zusätzlich zu dumbtv's Listen (aus FireFrame's debloat.txt, auf Fire OS 7 geprüft).
# Nur System-Apps, die auf dem Stick vorhanden sind, werden weitergereicht; alles aus
# dumbtv's never-disable-Listen wird nie angefasst.
EXTRA_SAFE="com.amazon.kso.blackbird com.amazon.device.logmanager com.amazon.client.metrics
  com.amazon.wifilocker com.amazon.d3 com.amazon.ods.kindleconnect com.amazon.gamehub
  com.amazon.spiderpork com.amazon.minitv.android.app com.amazon.imdb.tv.android.app
  com.amazon.brightdata.coralreef com.amazon.brightdata.jellyfish"
EXTRA_ALEXA="com.amazon.cardinal com.amazon.comms.starktachyon"
EXTRA_AMAZONAPPS="com.amazon.bueller.music com.amazon.bueller.photos com.amazon.cloud9"
EXTRA_MIRROR="com.amazon.cast.sink"

# ---------------------------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=; G=; Y=; R=; N=
fi
titel()  { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
info()   { printf '  %s\n' "$*"; }
ok()     { printf '  %sOK%s  %s\n' "$G" "$N" "$*"; }
# Erfolgsmeldung für Schritte, die im Trockenlauf nur angezeigt werden
fertig() { if [[ $DRY_RUN == 1 ]]; then info "[Trockenlauf] würde: $*"; else ok "$*"; fi; }
warn()   { printf '  %s!!%s  %s\n' "$Y" "$N" "$*"; WARNUNGEN+=("$*"); }
fehler() { printf '\n%sFEHLER:%s %s\n' "$R" "$N" "$*"; exit 1; }
WARNUNGEN=()

frage_jn() {   # $1 Frage; Standard: nein. Mit -y immer ja.
  [[ $YES == 1 ]] && return 0
  local a
  printf '\n%s [j/N] ' "$1"
  read -r a || return 1
  a=${a//$'\r'/}
  [[ $a =~ ^[jJyY] ]]
}

# --- adb ----------------------------------------------------------------------------
S=""
adbs() { "$ADB" -s "$S" "$@"; }
dev()  { "$ADB" -s "$S" shell "$@" </dev/null 2>&1 | tr -d '\r'; }
dev1() { dev "$@" | head -1; }
shq()  { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
norm_serial() { case $1 in *:*) printf '%s' "$1" ;; *) printf '%s:5555' "$1" ;; esac; }

# Zustand laut "adb devices": device | unauthorized | offline | "" (nicht verbunden).
# Nicht "adb get-state": das meldet ein nicht freigegebenes Gerät nur als Fehler auf stderr.
state_of() { "$ADB" devices 2>/dev/null | tr -d '\r' | awk -v s="$1" '$1 == s {print $2; exit}'; }

# Verbindet $1 und setzt TRY_STATE (device | unauthorized | offline | "") und CONNECT_MSG.
TRY_STATE=""; CONNECT_MSG=""
try_connect() {
  local i
  CONNECT_MSG=$("$ADB" connect "$1" 2>&1 | tr -d '\r' | awk 'NF' | tail -1)
  for i in 1 2 3; do
    TRY_STATE=$(state_of "$1")
    [[ $TRY_STATE == device || $TRY_STATE == unauthorized ]] && break
    sleep 1
  done
  # Neuere adb-Versionen trennen nach "failed to authenticate" sofort wieder,
  # der Fernseher zeigt die Freigabe-Frage aber trotzdem an.
  if [[ $TRY_STATE != device && $TRY_STATE != unauthorized && $CONNECT_MSG == *authenticat* ]]; then
    TRY_STATE=unauthorized
  fi
}

# Wartet, bis eines der Geräte am Fernseher freigegeben wurde. Setzt AUTH_OK.
AUTH_OK=""
wait_for_auth() {
  local t c st
  AUTH_OK=""
  printf '\n  %sAm Fernseher erscheint "USB-Debugging zulassen?".%s\n' "$B" "$N"
  info "Haken bei \"Immer von diesem Computer zulassen\" setzen und OK drücken."
  info "Ich warte bis zu 2 Minuten ..."
  for t in $(seq 1 40); do
    for c in "$@"; do
      st=$(state_of "$c")
      # Nur neu verbinden, wenn adb die Verbindung verworfen hat (sonst bliebe die Frage am
      # Fernseher nicht stehen) oder alle 30 s, falls die Frage dort weggeklickt wurde.
      if [[ -z $st ]] || (( t % 10 == 0 )); then
        [[ -n $st ]] && "$ADB" disconnect "$c" >/dev/null 2>&1
        "$ADB" connect "$c" >/dev/null 2>&1
        st=$(state_of "$c")
      fi
      if [[ $st == device ]] && is_amazon "$c"; then AUTH_OK=$c; return 0; fi
    done
    sleep 3
  done
  return 1
}

is_amazon() { [[ $("$ADB" -s "$1" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r') == Amazon* ]]; }

connect_tv() {
  local cands=() c st line
  local -A seen=()
  local found=() pending=()
  if [[ -n $OPT_IP ]]; then
    cands+=("$OPT_IP")
  elif [[ -n ${TV_IP:-} ]]; then
    cands+=("$TV_IP")
  else
    [[ -s $BACKUPS/letzte-ip.txt ]] && cands+=("$(head -1 "$BACKUPS/letzte-ip.txt")")
    # shellcheck disable=SC2206
    [[ -n $OPT_KANDIDATEN ]] && cands+=($OPT_KANDIDATEN)
    while read -r line; do
      [[ $line == *:*$'\t'device ]] && cands+=("${line%%$'\t'*}")
    done < <("$ADB" devices 2>/dev/null | tr -d '\r')
  fi

  titel "Fire TV suchen"
  local out
  out=$("$ADB" version 2>&1) || fehler "adb lässt sich nicht starten: $(printf '%s' "$out" | tail -1)
  Ist adb.exe durch eine Firmenrichtlinie oder den Virenscanner gesperrt? Dann einen privaten PC nehmen."
  out=$("$ADB" start-server 2>&1) || fehler "Der adb-Dienst startet nicht: $(printf '%s' "$out" | tail -1)"
  for c in "${cands[@]}"; do
    [[ -z $c ]] && continue
    c=$(norm_serial "$c")
    [[ -n ${seen[$c]:-} ]] && continue
    seen[$c]=1
    try_connect "$c"
    case $TRY_STATE in
      device)
        if is_amazon "$c"; then found+=("$c"); info "$c: Fire TV gefunden"
        else info "$c: kein Fire-TV-Gerät, übersprungen"; fi ;;
      unauthorized) pending+=("$c"); info "$c: wartet auf Freigabe am Fernseher" ;;
      *) info "$c: nicht erreichbar (${CONNECT_MSG:-keine Antwort})" ;;
    esac
  done

  if [[ ${#found[@]} -eq 0 && ${#pending[@]} -gt 0 ]]; then
    if wait_for_auth "${pending[@]}"; then
      found=("$AUTH_OK")
    else
      info "Keine Freigabe erhalten."
    fi
  fi

  while [[ ${#found[@]} -eq 0 ]]; do
    [[ $YES == 1 ]] && fehler "Kein Fire TV gefunden. IP-Adresse mit --ip angeben."
    printf '\n  Kein Fire TV automatisch gefunden.\n'
    info "Die IP-Adresse steht am Fernseher unter: Einstellungen > Mein Fire TV > Info > Netzwerk"
    info "Prüfen: Entwickleroptionen > ADB-Debugging ist an, PC und Stick im selben WLAN, kein VPN aktiv."
    printf '  IP-Adresse eingeben (leer = abbrechen): '
    read -r c || c=""
    c=${c//[$'\r' ]/}
    [[ -z $c ]] && fehler "Abgebrochen."
    c=$(norm_serial "$c")
    try_connect "$c"
    st=$TRY_STATE
    if [[ $st == unauthorized ]]; then
      if wait_for_auth "$c"; then st=device; else st=unauthorized; fi
    fi
    if [[ $st == device ]] && is_amazon "$c"; then found=("$c")
    elif [[ $st == device ]]; then info "$c ist kein Fire-TV-Gerät."
    elif [[ $st == unauthorized ]]; then info "$c wurde am Fernseher nicht freigegeben."
    else info "$c antwortet nicht: ${CONNECT_MSG:-keine Antwort}"
    fi
  done

  if [[ ${#found[@]} -gt 1 ]]; then
    local i=1 pick
    printf '\n  Mehrere Fire-TV-Geräte gefunden:\n'
    for c in "${found[@]}"; do
      printf '    %d) %s  %s\n' "$i" "$c" "$("$ADB" -s "$c" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
      i=$((i+1))
    done
    if [[ $YES == 1 ]]; then pick=1
    else printf '  Welches? [1-%d]: ' "${#found[@]}"; read -r pick || pick=1; pick=${pick//$'\r'/}; fi
    [[ $pick =~ ^[0-9]+$ && $pick -ge 1 && $pick -le ${#found[@]} ]] || fehler "Ungültige Auswahl."
    found=("${found[$((pick-1))]}")
  fi

  S=${found[0]}
  mkdir -p "$BACKUPS"
  printf '%s\n' "$S" > "$BACKUPS/letzte-ip.txt"
  read_device_info
}

model_name() {
  case $1 in
    AFTKM)      echo "Fire TV Stick 4K (2. Generation)" ;;
    AFTKRT)     echo "Fire TV Stick 4K Max (2. Generation)" ;;
    AFTKA)      echo "Fire TV Stick 4K Max (1. Generation)" ;;
    AFTMM)      echo "Fire TV Stick 4K (1. Generation)" ;;
    AFTMA08C15) echo "Fire TV Stick 4K Plus" ;;
    AFTSSS)     echo "Fire TV Stick (3. Generation)" ;;
    AFTSS)      echo "Fire TV Stick HD / Lite" ;;
    AFTT)       echo "Fire TV Stick (2. Generation)" ;;
    AFTGAZL)    echo "Fire TV Cube (3. Generation)" ;;
    AFTR)       echo "Fire TV Cube (2. Generation)" ;;
    AFTN)       echo "Fire TV (3. Generation)" ;;
    *)          echo "Fire TV ($1)" ;;
  esac
}

read_device_info() {
  MODEL=$(dev1 getprop ro.product.model)
  SDK=$(dev1 getprop ro.build.version.sdk)
  FOS=$(dev1 getprop ro.build.version.name)
  SERIALNO=$(dev1 getprop ro.serialno)
  [[ $SDK =~ ^[0-9]+$ ]] || SDK=0
  [[ -n $FOS ]] || FOS="Android SDK $SDK"
  NAME=$(model_name "$MODEL")
  local id=${SERIALNO:-${S%%:*}}
  DEVDIR="$BACKUPS/${MODEL:-FireTV}_${id//[^A-Za-z0-9._-]/_}"
  mkdir -p "$DEVDIR"
  export CONF="$DEVDIR/dumbtv.conf" REPORT="$DEVDIR/dumbtv-report"
  ok "$NAME · $FOS · $S"
}

reboot_tv() {
  info "Der Stick startet neu (ca. 1 Minute) ..."
  local before; before=$(dev1 "cat /proc/sys/kernel/random/boot_id")
  # Android speichert Paket-Änderungen erst nach ein paar Sekunden. "svc power reboot"
  # fährt sauber herunter; Fire OS 7.7 verweigert das der Shell, dann nach 12 s hart.
  dev "svc power reboot" >/dev/null 2>&1 || true
  sleep 3
  if [[ $(dev1 echo ok) == ok && -z $(dev1 getprop sys.shutdown.requested) ]]; then
    sleep "${PM_WRITE_SECONDS:-12}"
    adbs reboot >/dev/null 2>&1
  fi
  sleep "$REBOOT_WAIT"
  local i
  for i in $(seq 1 60); do
    "$ADB" connect "$S" >/dev/null 2>&1
    if [[ $(dev1 getprop sys.boot_completed) == 1 && $(dev1 "cat /proc/sys/kernel/random/boot_id") != "$before" ]]; then
      sleep "${BFTV_SETTLE:-8}"
      ok "Stick ist wieder da"
      return 0
    fi
    sleep 3
  done
  warn "Der Stick antwortet nach dem Neustart nicht. Ist er an und im WLAN?"
  return 1
}

adb_reconnect() {
  local i
  for i in $(seq 1 15); do
    [[ $(state_of "$S") == device && $(dev1 echo ok) == ok ]] && return 0
    "$ADB" disconnect "$S" >/dev/null 2>&1
    "$ADB" connect "$S" >/dev/null 2>&1
    sleep 3
  done
  return 1
}

# --- Listen -------------------------------------------------------------------------------
list_of() { [[ -f $1 ]] && sed 's/#.*//; s/[[:space:]]*$//' "$1" | awk 'NF'; }
pkgs_of() { sed -n 's/^package://p' "$1" | tr -d '\r' | LC_ALL=C sort -u; }
pkgs_now() { dev "pm list packages $*" | sed -n 's/^package://p' | LC_ALL=C sort -u; }
in_list() { printf '%s\n' "$2" | grep -qxF -- "$1"; }

never_disable() {
  { list_of "$DUMBTV/data/fireos/never-disable.txt"; list_of "$DUMBTV/data/fireos6/never-disable.txt"; } |
    awk '{print $1}' | LC_ALL=C sort -u
}

# Alles, was dumbtv oder dieses Tool je an- oder abschalten könnte.
touched_universe() {
  {
    local f
    for f in packages.txt alexa.txt user-apps.txt protected.txt never-disable.txt; do
      list_of "$DUMBTV/data/fireos/$f"; list_of "$DUMBTV/data/fireos6/$f"
    done
    printf '%s\n' $EXTRA_SAFE $EXTRA_ALEXA $EXTRA_AMAZONAPPS $EXTRA_MIRROR com.amazon.firetv.youtube $OUR_APPS $VPN_APP
  } | awk 'NF {print $1}' | LC_ALL=C sort -u
}

# Einstellungen, die dumbtv oder dieses Tool verändern. Nur diese setzt "Rückgängig" zurück.
settings_keys() {
  {
    local f
    for f in settings.txt settings.alexa.txt settings.restore.txt; do
      list_of "$DUMBTV/data/fireos/$f" | sed 's/ = / /' | awk '{print $1, $2}'
    done
    printf '%s\n' \
      "global window_animation_scale" "global transition_animation_scale" "global animator_duration_scale" \
      "secure enabled_accessibility_services" "secure accessibility_enabled" \
      "secure always_on_vpn_app" "secure always_on_vpn_lockdown" \
      "global alarm_manager_constants" "global private_dns_mode" "global private_dns_specifier"
  } | awk 'NF == 2 && ($1 == "global" || $1 == "secure" || $1 == "system")' | LC_ALL=C sort -u
}

value_in() {  # $1 Datei mit key=value, $2 key -> Wert; Rückgabe 1 wenn nicht vorhanden
  tr -d '\r' < "$1" | awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); f = 1; exit } END { exit !f }'
}

# --- Konfiguration ----------------------------------------------------------------------
load_config() {
  STARTBILDSCHIRM=fireframe; PRIME_VIDEO=1; ALEXA=0; AMAZON_APPS=0; SPIEGELN=0
  DNS_FILTER=1; DNS_UPSTREAM="94.140.14.14 94.140.15.15"; SMARTTUBE=1; TV_IP=""
  if [[ -f $CONFIG ]]; then
    # shellcheck disable=SC1090
    source <(tr -d '\r' < "$CONFIG") || fehler "einstellungen.txt ist fehlerhaft."
  fi
  local v
  for v in PRIME_VIDEO ALEXA AMAZON_APPS SPIEGELN DNS_FILTER SMARTTUBE; do
    [[ ${!v} == 0 || ${!v} == 1 ]] || fehler "einstellungen.txt: $v muss 0 oder 1 sein (ist '${!v}')."
  done
  [[ $STARTBILDSCHIRM == betterfiretv ]] && STARTBILDSCHIRM=fireframe
  case $STARTBILDSCHIRM in fireframe|dumbtv|amazon) ;; *)
    fehler "einstellungen.txt: STARTBILDSCHIRM muss fireframe, dumbtv oder amazon sein." ;; esac
}

# --- Backup -------------------------------------------------------------------------------
snapshot() {  # $1 Zielordner, $2 Bezeichnung
  local d=$1 p n
  mkdir -p "$d"
  {
    echo "BetterFireTV $VERSION"
    echo "erstellt=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "art=$2"
    echo "geraet=$NAME"
    echo "modell=$MODEL"
    echo "fireos=$FOS"
    echo "sdk=$SDK"
    echo "adresse=$S"
  } > "$d/info.txt"
  dev getprop > "$d/getprop.txt"
  dev "pm list packages -u" > "$d/pakete-alle.txt"
  dev "pm list packages" > "$d/pakete-installiert.txt"
  dev "pm list packages -e" > "$d/pakete-aktiv.txt"
  dev "pm list packages -d" > "$d/pakete-deaktiviert.txt"
  dev "pm list packages -s" > "$d/pakete-system.txt"
  dev "pm list packages -3" > "$d/pakete-drittanbieter.txt"
  for n in global secure system; do settings_dump "$n" > "$d/settings-$n.txt"; done
  dev "cmd netpolicy get restrict-background" > "$d/netpolicy-restrict-background.txt"
  dev "cmd netpolicy list restrict-background-blacklist" > "$d/netpolicy-blacklist.txt"
  dev "dumpsys deviceidle whitelist" > "$d/deviceidle-whitelist.txt"
  dev "cat /proc/meminfo" > "$d/meminfo.txt"
  local inst; inst=$(pkgs_of "$d/pakete-installiert.txt")
  : > "$d/appops.txt"
  while read -r p; do
    in_list "$p" "$inst" || continue
    { echo "### $p"; dev "appops get $p"; } >> "$d/appops.txt"
  done < <(touched_universe)
  adbs exec-out screencap -p > "$d/bildschirm.png" 2>/dev/null || rm -f "$d/bildschirm.png"

  # Ohne vollständige Paketliste und Einstellungen gibt es keinen Rollback.
  local np ns
  np=$(grep -c '^package:' "$d/pakete-installiert.txt")
  ns=$(grep -c '=' "$d/settings-secure.txt")
  [[ $np -ge 20 && $ns -ge 5 ]] || return 1
  echo "pakete=$np" >> "$d/info.txt"
  return 0
}

# Sichert den Zustand. Der allererste Stand eines Geräts kommt nach "original" und wird
# nie überschrieben; spätere Läufe bekommen einen eigenen Ordner.
backup_now() {
  titel "Rollback-Backup"
  ORIG="$DEVDIR/original"
  if [[ ! -f $ORIG/info.txt ]] && [[ $(dev1 "test -f $TVDIR/original/info.txt && echo ja") == ja ]]; then
    info "Original-Backup liegt auf dem Stick, hole es auf den PC ..."
    adbs pull "$TVDIR/original" "$DEVDIR/" >/dev/null 2>&1 || true
  fi
  local ziel art
  if [[ -f $ORIG/info.txt ]]; then
    ziel="$DEVDIR/stand-$(date +%Y%m%d-%H%M%S)"; art=zwischenstand
    info "Original-Backup vom $(sed -n 's/^erstellt=//p' "$ORIG/info.txt") bleibt unverändert."
  else
    ziel=$ORIG; art=original
  fi
  info "Sichere Paketliste, alle Einstellungen, Bedienungshilfen, Netzwerkregeln und einen Screenshot ..."
  snapshot "$ziel" "$art" || { rm -rf "${ziel:?}"; fehler "Backup unvollständig. Abbruch, am Stick wurde nichts geändert."; }
  ok "Backup auf dem PC: ${ziel#"$ROOT"/}"
  if [[ $DRY_RUN == 0 ]]; then
    dev "mkdir -p $TVDIR" >/dev/null
    if adbs push "$ziel" "$TVDIR/" >/dev/null 2>&1 && [[ $(dev1 "test -f $TVDIR/$(basename "$ziel")/info.txt && echo ja") == ja ]]; then
      ok "Kopie auf dem Stick: $TVDIR/$(basename "$ziel")"
    else
      warn "Kopie auf dem Stick fehlgeschlagen (das Backup auf dem PC reicht für den Rollback)."
    fi
  fi
  BEFORE_DIR=$ziel
}

mem_mb() { awk '/MemAvailable/ {print int($2/1024); exit}' "$1" 2>/dev/null; }

# --- dumbtv -------------------------------------------------------------------------------
DT_OUT=""
run_dumbtv() {  # $1 Skript, Rest: Argumente. Ausgabe wird zusätzlich in $DT_OUT mitgeschrieben.
  local s=$1; shift
  [[ -n $DT_OUT ]] && rm -f "$DT_OUT"
  DT_OUT=$(mktemp)
  ADB="$ADB" ADB_SERIAL="$S" CONF="$CONF" REPORT="$REPORT" NO_REBOOT="${NO_REBOOT:-0}" \
    bash "$DUMBTV/scripts/$s" "$@" 2>&1 | tee "$DT_OUT"
  return "${PIPESTATUS[0]}"
}

dry_flag() { [[ $DRY_RUN == 1 ]] && printf -- '--dry-run' || printf -- '-y'; }

extras_for_device() {
  local list=$EXTRA_SAFE sys never dream p out=()
  [[ $ALEXA == 0 ]] && list+=" $EXTRA_ALEXA"
  [[ $AMAZON_APPS == 0 ]] && list+=" $EXTRA_AMAZONAPPS"
  [[ $SPIEGELN == 0 ]] && list+=" $EXTRA_MIRROR"
  sys=$(pkgs_now -s)
  never=$(never_disable)
  dream=$(dev1 "settings get secure screensaver_components"); dream=${dream%%,*}; dream=${dream%%/*}
  for p in $list; do
    in_list "$p" "$sys" || continue
    in_list "$p" "$never" && continue
    if [[ $p == "$dream" ]]; then   # der aktive Bildschirmschoner bleibt
      info "$p bleibt an: davon kommt der Bildschirmschoner." >&2
      continue
    fi
    out+=("$p")
  done
  printf '%s' "${out[*]:-}"
}

configure_dumbtv() {  # $1 = DNS-Upstream
  local launcher=0
  [[ $STARTBILDSCHIRM == dumbtv ]] && launcher=1
  run_dumbtv configure.sh -y --prime "$PRIME_VIDEO" --alexa "$ALEXA" --launcher "$launcher" \
    --dnsfilter "$DNS_FILTER" --youtube "$SMARTTUBE" --dns-upstream "$1" --remove "$EXTRAS" >/dev/null ||
    { cat "$DT_OUT"; return 1; }
}

# --- Startbildschirm (BetterFireTV-Fassung von FireFrame, Quelltext in home/) -------------
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

set_setting() { dev "settings put $1 $2 $(shq "$3")" >/dev/null; }
del_setting() {
  local out
  out=$(dev "settings delete $1 $2")
  # Android 5.1 (Fire OS 5) kennt "settings delete" nicht: dann direkt über den Settings-Provider.
  if [[ $out == *[Uu]sage* || $out == *nvalid* || $out == *nknown* ]]; then
    dev "content delete --uri content://settings/$1 --where \"name='$2'\"" >/dev/null
  fi
  return 0
}

# Alle Einstellungen eines Bereichs als key=value. Fallback über den Settings-Provider für Android 5.1.
settings_dump() {
  local out
  out=$(dev "settings list $1")
  if [[ $(printf '%s\n' "$out" | grep -c '=') -lt 5 ]]; then
    out=$(dev "content query --uri content://settings/$1 --projection name:value" |
      sed -n 's/^Row: [0-9]* name=\(.*\), value=\(.*\)$/\1=\2/p' | sed 's/=NULL$/=/')
  fi
  printf '%s\n' "$out"
}

a11y_list() { local v; v=$(dev1 "settings get secure enabled_accessibility_services"); [[ $v == null ]] && v=""; printf '%s' "$v"; }

# Unsere Home-Taste an, die von FireFrame (Original) aus, alle übrigen Dienste bleiben.
home_service_on() {
  local cur new
  cur=$(a11y_list)
  new=$(printf '%s' "$cur" | tr ':' '\n' | grep -vxF -e "$HOME_SVC" -e "$FF_SVC" -e "$FF_PKG/.HomeService" -e '' | paste -sd: - || true)
  new=${new:+$new:}$HOME_SVC
  set_setting secure enabled_accessibility_services "$new"
  set_setting secure accessibility_enabled 1
}

home_service_off() {
  local cur rest
  cur=$(a11y_list)
  rest=$(printf '%s' "$cur" | tr ':' '\n' | grep -vxF -e "$HOME_SVC" -e "$FF_SVC" -e "$FF_PKG/.HomeService" -e '' | paste -sd: - || true)
  if [[ -n $rest ]]; then set_setting secure enabled_accessibility_services "$rest"
  else del_setting secure enabled_accessibility_services; set_setting secure accessibility_enabled 0; fi
}

# Paket im Vordergrund. Wie dumbtv: zuerst die globale Zeile "ResumedActivity:" (Android 9, 11),
# sonst die erste per-Stack-Zeile (Android 5.1/7.1) oder "topResumedActivity=" (Android 13).
front_pkg() {
  local dump line
  dump=$(dev "dumpsys activity activities")
  line=$(printf '%s\n' "$dump" | grep -m1 -E '^ *ResumedActivity: ActivityRecord')
  [[ -n $line ]] || line=$(printf '%s\n' "$dump" | grep -m1 -E '(topResumedActivity=|mResumedActivity: )ActivityRecord')
  printf '%s\n' "$line" | sed -nE 's/.*ActivityRecord\{[^ ]+ u[0-9]+ ([^ /}]+).*/\1/p'
}

home_check() {  # $1 erwartetes Paket. Drückt HOME und wartet bis zu 15 s (mit Profilauswahl länger).
  local i f="" hinted=0
  dev "input keyevent KEYCODE_HOME" >/dev/null
  for i in $(seq 1 20); do
    sleep 2
    f=$(front_pkg)
    [[ $f == "$1" ]] && return 0
    if [[ $f == com.amazon.ftv.profilepicker ]]; then
      [[ $hinted == 0 ]] && info "Am Fernseher fragt Amazon nach dem Profil: bitte ein Profil wählen ..."
      hinted=1
      continue
    fi
    (( i >= 8 )) && break
  done
  HOME_FRONT=$f
  return 1
}

installed_version() { dev "dumpsys package $1" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1; }
is_installed() { [[ -n $(dev "pm path $1" | grep '^package:') ]]; }

# Schickt Einstellungen an den laufenden Startbildschirm: home_send --es dock 'a,b' ...
home_send() { dev "am start -n $HOME_ACT $*" >/dev/null; }

install_home() {
  if [[ $SDK -ge 25 && $SDK -lt 28 ]]; then
    warn "Fire OS 6 erlaubt keine fremden Bedienungshilfen, der Startbildschirm kann die Home-Taste nicht übernehmen."
    info "Ich nehme stattdessen dumbtv home (nutzt auf Fire OS 6 einen anderen Weg)."
    STARTBILDSCHIRM=dumbtv
    install_dumbtv_home
    return
  fi
  [[ -f $HOME_APK ]] || { warn "home/betterfiretv-home.apk fehlt."; return 1; }
  if [[ -f $HOME_APK.sha256 && $(sha256_of "$HOME_APK") != "$(tr -d ' \r\n' < "$HOME_APK.sha256")" ]]; then
    warn "Prüfsumme von betterfiretv-home.apk stimmt nicht, wird nicht installiert."; return 1
  fi
  local out
  out=$(adbs install -r "$HOME_APK" 2>&1 | tr -d '\r' | tail -1)
  if [[ $out == *INCOMPATIBLE* || $out == *SIGNATURE* || $out == *DOWNGRADE* ]]; then
    adbs uninstall "$HOME_PKG" >/dev/null 2>&1
    out=$(adbs install "$HOME_APK" 2>&1 | tr -d '\r' | tail -1)
  fi
  [[ $out == *Success* ]] || { warn "Installation des Startbildschirms fehlgeschlagen: $out"; return 1; }
  ok "Startbildschirm installiert (Apple-TV-Look, App-Kacheln in Farbe)"
  # Zwei Startbildschirme mit Home-Hook stören sich gegenseitig: dumbtv home muss weichen.
  if is_installed tv.dumbtv.home; then
    ADB="$ADB" ADB_SERIAL="$S" bash "$DUMBTV/launcher/install.sh" --undo >/dev/null 2>&1 || true
    adbs uninstall tv.dumbtv.home >/dev/null 2>&1 && ok "dumbtv home entfernt (zwei Startbildschirme stören sich)"
  fi
  home_service_on
  if is_installed "$FF_PKG"; then
    adbs uninstall "$FF_PKG" >/dev/null 2>&1 && ok "alte FireFrame-Version entfernt"
  fi
  dev "am start -n $HOME_ACT" >/dev/null
  sleep 3
  apply_home_conf
  sync_wallpapers quiet
  if home_check "$HOME_PKG"; then
    ok "Home-Taste öffnet jetzt den neuen Startbildschirm"
    return 0
  fi
  warn "Die Home-Taste landet noch bei ${HOME_FRONT:-unbekannt}, nicht beim neuen Startbildschirm."
  if [[ $SDK -lt 25 ]]; then
    info "Auf Fire OS 5 gibt es dafür keine Alternative (dumbtv home braucht Fire OS 6)."
    if frage_jn "Startbildschirm wieder entfernen? (Nein = als App behalten, über \"Deine Apps\" startbar)"; then
      home_service_off
      adbs uninstall "$HOME_PKG" >/dev/null 2>&1 && info "Startbildschirm entfernt"
    fi
    return 1
  fi
  if frage_jn "Stattdessen dumbtv home probieren (schlichter, auf Fire OS 8 am meisten getestet)?"; then
    home_service_off
    adbs uninstall "$HOME_PKG" >/dev/null 2>&1
    STARTBILDSCHIRM=dumbtv
    install_dumbtv_home
  else
    info "Der Startbildschirm bleibt installiert. Ein Neustart des Sticks hilft oft: danach Home drücken."
  fi
}

# Installiert oder aktualisiert den Startbildschirm, wenn nötig.
ensure_home() {
  if [[ $SDK -lt 25 ]]; then
    fehler "$NAME hat Fire OS 5. Dort lässt sich die Home-Taste nicht übernehmen, ein eigener Startbildschirm (Dock, Hintergründe) geht auf diesem Gerät nicht."
  fi
  case $STARTBILDSCHIRM in
    fireframe) ;;
    *) fehler "In einstellungen.txt steht STARTBILDSCHIRM=$STARTBILDSCHIRM. Für Dock und Hintergrund: STARTBILDSCHIRM=fireframe, dann noch einmal starten." ;;
  esac
  local want have
  want=$(tr -d ' \r\n' < "$HOME_APK.version" 2>/dev/null)
  have=$(installed_version "$HOME_PKG")
  if [[ -z $have || $have != "$want" ]] || [[ ":$(a11y_list):" != *":$HOME_SVC:"* ]]; then
    titel "Startbildschirm installieren"
    install_home || fehler "Der Startbildschirm konnte nicht installiert werden."
  fi
}

HOME_CONF() { printf '%s' "$DEVDIR/startbildschirm.conf"; }

load_home_conf() {
  H_DOCK=""; H_HIDE=""; H_BUILTINS=""; H_WALLPAPER=""; H_SET=0
  local f; f=$(HOME_CONF)
  [[ -f $f ]] || return 0
  H_SET=1
  H_DOCK=$(sed -n 's/^DOCK="\(.*\)"$/\1/p' "$f" | tail -1)
  H_HIDE=$(sed -n 's/^HIDE="\(.*\)"$/\1/p' "$f" | tail -1)
  H_BUILTINS=$(sed -n 's/^BUILTINS=\([01]\)$/\1/p' "$f" | tail -1)
  H_WALLPAPER=$(sed -n 's/^WALLPAPER="\(.*\)"$/\1/p' "$f" | tail -1)
}

save_home_conf() {
  {
    echo "# Startbildschirm für dieses Gerät. Wird nach jeder (Neu-)Installation wieder angewendet."
    echo "DOCK=\"$H_DOCK\""
    echo "HIDE=\"$H_HIDE\""
    [[ -n $H_BUILTINS ]] && echo "BUILTINS=$H_BUILTINS"
    [[ -n $H_WALLPAPER ]] && echo "WALLPAPER=\"$H_WALLPAPER\""
  } > "$(HOME_CONF)"
}

# Gespeicherte Dock-/Ausblende-/Hintergrund-Wahl wieder auf den Stick bringen.
apply_home_conf() {
  load_home_conf
  [[ $H_SET == 1 ]] || return 0
  local args=""
  [[ -n $H_DOCK ]] && args+=" --es dock $(shq "$H_DOCK")"
  args+=" --es hide $(shq "$H_HIDE")"
  [[ -n $H_BUILTINS ]] && { [[ $H_BUILTINS == 1 ]] && args+=" --ez builtins true" || args+=" --ez builtins false"; }
  [[ -n $H_WALLPAPER ]] && args+=" --es wallpaper $(shq "$H_WALLPAPER")"
  home_send "$args"
  info "Gespeicherte Dock- und Hintergrund-Einstellungen angewendet"
}

# Liest die App-Liste, die der Startbildschirm in seinen Media-Ordner schreibt.
read_apps() {
  local raw="" i
  A_PKG=(); A_NAME=(); A_DOCK=(); A_HID=()
  dev "rm -f $HOME_MEDIA/apps.txt" >/dev/null
  home_send "--ez export true"
  for i in 1 2 3 4 5 6 7 8; do
    sleep 1
    raw=$(dev "cat $HOME_MEDIA/apps.txt 2>/dev/null")
    [[ $raw == *$'\t'* ]] && break
  done
  [[ $raw == *$'\t'* ]] || return 1
  local p n d h
  while IFS=$'\t' read -r p n d h; do
    [[ -z $p ]] && continue
    A_PKG+=("$p"); A_NAME+=("$n"); A_DOCK+=("$d"); A_HID+=("$h")
  done <<< "$raw"
  return 0
}

dock_csv() {  # aktuelle Dock-Reihenfolge laut App-Liste
  local i pos out=()
  for pos in $(seq 1 ${#A_PKG[@]}); do
    for i in "${!A_PKG[@]}"; do [[ ${A_DOCK[$i]} == "$pos" ]] && out+=("${A_PKG[$i]}"); done
  done
  (IFS=,; printf '%s' "${out[*]:-}")
}

hidden_csv() {
  local i out=()
  for i in "${!A_PKG[@]}"; do [[ ${A_HID[$i]} == 1 ]] && out+=("${A_PKG[$i]}"); done
  (IFS=,; printf '%s' "${out[*]:-}")
}

name_of() { local i; for i in "${!A_PKG[@]}"; do [[ ${A_PKG[$i]} == "$1" ]] && { printf '%s' "${A_NAME[$i]}"; return; }; done; printf '%s' "$1"; }

show_dock() {
  local csv=$1 p out=()
  IFS=, read -ra ps <<< "$csv"
  for p in "${ps[@]}"; do [[ -n $p ]] && out+=("$(name_of "$p")"); done
  if [[ ${#out[@]} -eq 0 ]]; then info "(leer)"; else info "$(printf '%s' "${out[0]}"; printf ' · %s' "${out[@]:1}")"; fi
}

# Nummern-Eingabe ("3 1 7") in Paketnamen umsetzen. Ungültiges wird gemeldet und übersprungen.
nums_to_csv() {
  local n out=() used=" "
  for n in ${1//,/ }; do
    if [[ ! $n =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#A_PKG[@]} )); then info "\"$n\" gibt es nicht, übersprungen" >&2; continue; fi
    [[ $used == *" $n "* ]] && continue
    used+="$n "
    out+=("${A_PKG[$((n-1))]}")
  done
  (IFS=,; printf '%s' "${out[*]:-}")
}

mode_startbildschirm() {
  load_config
  connect_tv
  ensure_home
  read_apps || fehler "Der Startbildschirm hat keine App-Liste geliefert. Einmal Home drücken und noch einmal versuchen."
  load_home_conf
  local dock hide i mark a
  dock=$(dock_csv); hide=$(hidden_csv)

  titel "Dock (Leiste unten), von links nach rechts"
  show_dock "$dock"
  titel "Alle Apps"
  for i in "${!A_PKG[@]}"; do
    mark=""
    [[ ${A_DOCK[$i]} != - ]] && mark="Dock ${A_DOCK[$i]}"
    [[ ${A_HID[$i]} == 1 ]] && mark="ausgeblendet"
    printf '  %2d) %-30s %s\n' "$((i+1))" "${A_NAME[$i]:0:30}" "$mark"
  done

  printf '\n  Neue Dock-Reihenfolge als Nummern, z. B. "3 1 7" (Enter = so lassen): '
  read -r a || a=""; a=${a//$'\r'/}
  [[ -n ${a// /} ]] && dock=$(nums_to_csv "$a")
  printf '  Apps ausblenden: Nummern, 0 = keine (Enter = so lassen): '
  read -r a || a=""; a=${a//$'\r'/}
  if [[ ${a// /} == 0 ]]; then hide=""
  elif [[ -n ${a// /} ]]; then hide=$(nums_to_csv "$a")
  fi
  # Was im Dock liegt, wird nicht ausgeblendet.
  local p keep=()
  IFS=, read -ra hs <<< "$hide"
  for p in "${hs[@]}"; do [[ -n $p && ",$dock," != *",$p,"* ]] && keep+=("$p"); done
  hide=$(IFS=,; printf '%s' "${keep[*]:-}")

  home_send "--es dock $(shq "$dock") --es hide $(shq "$hide")"
  H_DOCK=$dock; H_HIDE=$hide
  save_home_conf
  read_apps || true
  titel "Neu auf dem Fernseher"
  show_dock "$(dock_csv)"
  [[ -n $hide ]] && info "Ausgeblendet: $(IFS=,; for p in $hide; do printf '%s, ' "$(name_of "$p")"; done | sed 's/, $//')"
  ok "Gespeichert. Gilt auch nach einer Neuinstallation (backups/.../startbildschirm.conf)."
}

# Bringt alle Bilder aus hintergruende/ auf den Stick und entfernt dort, was es am PC nicht mehr gibt.
sync_wallpapers() {
  local quiet=${1:-} dir=$WALLDIR f n tv=() added=0 removed=0
  mkdir -p "$dir"
  dev "mkdir -p $HOME_MEDIA/wallpapers" >/dev/null
  mapfile -t tv < <(dev "ls $HOME_MEDIA/wallpapers 2>/dev/null" | awk 'NF')
  local -A here=()
  for f in "$dir"/*; do
    [[ -f $f ]] || continue
    n=$(basename "$f")
    case ${n,,} in *.jpg|*.jpeg|*.png|*.webp) ;; *) continue ;; esac
    here[$n]=1
    if ! printf '%s\n' "${tv[@]:-}" | grep -qxF -- "$n"; then
      adbs push "$f" "$HOME_MEDIA/wallpapers/$n" >/dev/null 2>&1 && added=$((added+1))
    fi
  done
  for n in "${tv[@]:-}"; do
    [[ -z $n || -n ${here[$n]:-} ]] && continue
    dev "rm -f $(shq "$HOME_MEDIA/wallpapers/$n")" >/dev/null
    removed=$((removed+1))
  done
  WALL_COUNT=${#here[@]}
  if [[ -z $quiet || $added -gt 0 || $removed -gt 0 ]]; then
    info "Eigene Hintergrundbilder: $WALL_COUNT (neu: $added, entfernt: $removed)"
  fi
  (( added + removed > 0 )) && home_send "--ez reload true"
  return 0
}

mode_hintergrund() {
  load_config
  connect_tv
  ensure_home
  load_home_conf
  titel "Hintergrundbilder"
  sync_wallpapers
  local first="" a
  if [[ -n $OPT_NEU ]]; then
    first=${OPT_NEU%% *}
    H_WALLPAPER="file:$first"
    info "Aktuelles Bild: $first"
  fi
  if (( WALL_COUNT > 0 )); then
    if [[ $H_BUILTINS == 0 ]]; then
      printf '\n  NASA-Bilder zusätzlich zu deinen eigenen anbieten? [j/N] '
      read -r a || a=""; a=${a//$'\r'/}
      [[ $a =~ ^[jJyY] ]] && H_BUILTINS=1
    else
      printf '\n  NASA-Bilder zusätzlich zu deinen eigenen anbieten? [J/n] '
      read -r a || a=""; a=${a//$'\r'/}
      if [[ $a =~ ^[nN] ]]; then H_BUILTINS=0; else H_BUILTINS=1; fi
    fi
  else
    H_BUILTINS=1
    info "Noch keine eigenen Bilder. Hintergrund.cmd öffnet ein Auswahlfenster, oder Bilder in den Ordner hintergruende/ legen."
  fi
  local args="--ez reload true"
  [[ $H_BUILTINS == 1 ]] && args+=" --ez builtins true" || args+=" --ez builtins false"
  [[ -n $first ]] && args+=" --es wallpaper $(shq "$H_WALLPAPER")"
  home_send "$args"
  save_home_conf
  ok "Fertig. Am Fernseher wechselt das Bild-Symbol oben rechts zwischen den Bildern."
}

install_dumbtv_home() {
  if is_installed "$HOME_PKG"; then
    home_service_off
    adbs uninstall "$HOME_PKG" >/dev/null 2>&1 && info "BetterFireTV-Startbildschirm entfernt (zwei Startbildschirme stören sich)"
  fi
  [[ -z $EXTRAS && -f $CONF ]] && EXTRAS=$(sed -n 's/^REMOVE_EXTRA="\(.*\)"$/\1/p' "$CONF" | tail -1)
  configure_dumbtv "${CUR_UPSTREAM-$DNS_UPSTREAM}"
  if run_dumbtv launcher.sh -y; then ok "dumbtv home ist der Startbildschirm"
  else warn "dumbtv home hat die Home-Taste nicht übernommen (Details oben)."; fi
}

# --- DNS-Filter ---------------------------------------------------------------------------
dns_manual_step() {
  titel "Ein Handgriff am Fernseher (Fire OS 8 versteckt die App-Ordner vor adb)"
  info "Die Sperrliste liegt schon auf dem Stick. Bitte mit der Fernbedienung:"
  info "  1. App \"personalDNSfilter\" öffnen, \"Advanced settings\" anhaken,"
  info "     dann \"Configure filter update\" anhaken."
  info "  2. In der Tabelle alle Listen abhaken."
  info "  3. In der letzten Zeile <new> rechts auf den Bearbeiten-Knopf."
  info "  4. Als URL eintragen (drei Schrägstriche):"
  info "     file:///storage/emulated/0/Android/media/dnsfilter.android/dumbtv-blocklist.txt"
  info "     \"Active\" anhaken, OK."
  info "Danach hier Enter drücken. (Zum Überspringen: s + Enter)"
  local a=""
  [[ $YES == 1 ]] && a=s || read -r a || a=s
  a=${a//$'\r'/}
  if [[ $a =~ ^[sS] ]]; then
    warn "DNS-Filter-Liste übersprungen. Später: Einrichten.cmd erneut starten."
    return 1
  fi
  dev "settings put secure always_on_vpn_app $VPN_APP" >/dev/null
  dev "appops write-settings" >/dev/null
  reboot_tv
  sleep 15
  dns_selftest
}

dns_selftest() {
  local line
  line=$(dev "ping -c1 -W2 softwareupdates.amazon.com" | head -1)
  case $line in
    *0.0.0.0*|*127.0.0.1*) ok "DNS-Filter aktiv: Amazon-Update-Server blockiert" ;;
    *) warn "DNS-Filter blockt noch nicht. Stick neu starten und Status.cmd ausführen."; return 1 ;;
  esac
}

setup_dns() {
  CUR_UPSTREAM=$DNS_UPSTREAM
  if [[ $DNS_FILTER == 0 ]]; then info "DNS-Filter ist in den Einstellungen aus."; return 0; fi
  if run_dumbtv dnsfilter.sh "$(dry_flag)"; then
    if grep -q "one manual step" "$DT_OUT"; then
      dns_manual_step
    else
      fertig "DNS-Filter läuft${DNS_UPSTREAM:+ (Rest über AdGuard DNS)}"
    fi
    return 0
  fi
  if [[ -n $DNS_UPSTREAM && $DRY_RUN == 0 ]]; then
    warn "DNS-Filter mit AdGuard als Weiterleitung hat den Selbsttest nicht bestanden, nehme den Router."
    CUR_UPSTREAM=""
    configure_dumbtv ""
    if run_dumbtv dnsfilter.sh -y; then
      grep -q "one manual step" "$DT_OUT" && dns_manual_step
      ok "DNS-Filter läuft (Weiterleitung über den Router)"
      return 0
    fi
  fi
  warn "DNS-Filter nicht aktiv (Details oben). Werbung im Amazon-Menü ist trotzdem weg; Updates sind nicht blockiert."
  return 1
}

# --- DNS-Filter auf Fire OS 5 ---------------------------------------------------------------------
# Android 5.1 kennt kein "immer aktives VPN"; personalDNSfilter startet dort über seinen eigenen
# Autostart, und die VPN-Erlaubnis muss einmal jemand am Fernseher bestätigen. Darum: Liste und
# Einstellungen mit dumbtv aufspielen (ohne dessen Neustart), App öffnen, Frage bestätigen lassen,
# prüfen, neu starten, noch einmal prüfen.
dns_blocked() {
  case $(dev "ping -c1 -W2 softwareupdates.amazon.com" | head -1) in
    *0.0.0.0*|*127.0.0.1*) return 0 ;;
  esac
  return 1
}

dns_resolves() {
  local l; l=$(dev "ping -c1 -W2 www.youtube.com" | head -1)
  [[ $l == PING* && $l != *0.0.0.0* && $l != *127.0.0.1* ]]
}

setup_dns_fos5() {
  CUR_UPSTREAM=$DNS_UPSTREAM
  if [[ $DNS_FILTER == 0 ]]; then info "DNS-Filter ist in den Einstellungen aus."; return 0; fi
  local rc
  NO_REBOOT=1
  run_dumbtv dnsfilter.sh "$(dry_flag)"; rc=$?
  NO_REBOOT=0
  [[ $DRY_RUN == 1 ]] && { info "[Trockenlauf] danach: VPN-Frage am Fernseher bestätigen, Neustart, Selbsttest"; return 0; }
  [[ $rc == 0 ]] || { warn "DNS-Filter konnte nicht eingerichtet werden (Details oben)."; return 1; }
  dns_vpn_consent
}

dns_vpn_consent() {
  local a="" t
  dev "am start -n $VPN_APP/.DNSProxyActivity" >/dev/null
  titel "Ein Handgriff am Fernseher"
  info "Am Fernseher ist jetzt die App personalDNSfilter offen."
  info "Erscheint eine \"Verbindungsanfrage\" (VPN): \"Ich vertraue dieser App\" anhaken, dann OK."
  info "Erscheint keine Frage: in der App einmal auf \"Neu starten\" bzw. \"Restart\" gehen."
  printf '  Danach hier Enter drücken (überspringen: s + Enter): '
  if [[ $YES == 1 ]]; then a=s; else read -r a || a=s; fi
  a=${a//$'\r'/}
  if [[ $a =~ ^[sS] ]]; then
    warn "DNS-Filter-Freigabe übersprungen. Später einfach Einrichten.cmd noch einmal starten."
    return 1
  fi
  for t in 1 2 3 4; do dns_blocked && break; sleep 5; done
  if ! dns_blocked; then
    warn "Der Filter blockt noch nicht. In personalDNSfilter sollte oben \"Connections\" stehen und unten Einträge laufen."
    return 1
  fi
  if ! dns_resolves; then
    if [[ -n $CUR_UPSTREAM ]]; then
      warn "Über AdGuard DNS kommt keine Antwort, ich nehme den Router."
      CUR_UPSTREAM=""
      configure_dumbtv ""
      NO_REBOOT=1; run_dumbtv dnsfilter.sh -y >/dev/null; NO_REBOOT=0
    else
      warn "Mit dem Filter löst der Stick keine Namen mehr auf. Rueckgaengig.cmd nimmt ihn wieder heraus."
      return 1
    fi
  fi
  ok "DNS-Filter blockt${CUR_UPSTREAM:+ (Rest über AdGuard DNS)}"
  dev "input keyevent KEYCODE_HOME" >/dev/null
  info "Neustart, um zu prüfen, ob der Filter von selbst wieder anspringt ..."
  reboot_tv || return 1
  for t in 1 2 3 4 5 6; do
    if dns_blocked; then ok "DNS-Filter startet nach dem Neustart von selbst"; return 0; fi
    sleep 10
  done
  warn "Nach dem Neustart blockt der Filter nicht von selbst. In personalDNSfilter muss \"Autostart\" an sein."
  return 1
}

# Zeigt alle 30 s, dass ein langer Schritt noch läuft.
with_heartbeat() {
  ( while sleep 30; do printf '  ... läuft noch (%s)\n' "$(date +%H:%M)"; done ) &
  local hb=$! rc
  "$@"; rc=$?
  kill "$hb" 2>/dev/null
  wait "$hb" 2>/dev/null
  return "$rc"
}

# --- Modi ---------------------------------------------------------------------------------
plan_text() {
  titel "Das passiert jetzt mit $NAME"
  info "1. Rollback-Backup: Paketliste, alle Einstellungen, Screenshot (PC + Stick)"
  info "2. Werbung, Tracking, Telemetrie, Experimente aus: rund 50 Amazon-Dienste werden"
  info "   deaktiviert, nicht gelöscht"
  local keep=() off=()
  [[ $PRIME_VIDEO == 1 ]] && keep+=("Prime Video") || off+=("Prime-Video-Server")
  [[ $ALEXA == 1 ]] && keep+=("Alexa") || off+=("Alexa/Sprachsuche")
  [[ $AMAZON_APPS == 1 ]] && keep+=("Amazon Music/Fotos/Silk") || off+=("Amazon Music/Fotos/Silk")
  [[ $SPIEGELN == 1 ]] && keep+=("Bildschirm spiegeln") || off+=("Bildschirm spiegeln")
  [[ ${#off[@]} -gt 0 ]] && info "   aus:   $(IFS=,; printf '%s' "${off[*]}" | sed 's/,/, /g')"
  [[ ${#keep[@]} -gt 0 ]] && info "   bleibt: $(IFS=,; printf '%s' "${keep[*]}" | sed 's/,/, /g')"
  if [[ $DNS_FILTER == 1 ]]; then
    info "3. DNS-Filter auf dem Stick: blockt Amazon-Tracking und Fire-OS-Updates"
    [[ -n $DNS_UPSTREAM ]] && info "   übrige Anfragen über AdGuard DNS (blockt Werbung/Tracker in Apps)"
  fi
  [[ $SMARTTUBE == 1 ]] && info "4. SmartTube statt YouTube (keine Werbung, keine Shorts)"
  case $STARTBILDSCHIRM in
    fireframe) info "5. Startbildschirm im Apple-TV-Look mit farbigen App-Kacheln, übernimmt die Home-Taste" ;;
    dumbtv)    info "5. dumbtv home als Startbildschirm" ;;
    amazon)    info "5. Amazons Startbildschirm bleibt" ;;
  esac
  info "6. Schnellere Animationen, kein Autoplay mit Ton auf der Startseite"
  printf '\n'
  info "Der Stick startet dabei 2-3 Mal neu, Dauer ca. 10 Minuten."
  info "Rückgängig machen jederzeit mit Rueckgaengig.cmd."
}

# --- Fire OS 5 (Android 5.1, z. B. Fire TV Stick 2. Generation) --------------------------------
# Amazon lässt dort keine App abschalten: pm disable-user, pm uninstall --user 0 und pm hide werden
# alle verweigert (dumbtv docs/OTHER-TVS.md, cleanyourtv #577). Was trotzdem geht: Datenschutz-
# Einstellungen, der DNS-Filter, SmartTube und der Startbildschirm, der Amazons Werbe-Startseite verdeckt.
plan_text_fireos5() {
  titel "Das passiert jetzt mit $NAME (Fire OS 5)"
  info "Fire OS 5 lässt keine Amazon-App abschalten, das verweigert Amazon auf diesem Gerät komplett."
  info "Was trotzdem geht:"
  info "1. Rollback-Backup: Paketliste, alle Einstellungen, Screenshot (PC + Stick)"
  info "2. Werbe-ID, Nutzungsdaten und Autoplay aus, schnellere Animationen"
  if [[ $DNS_FILTER == 1 ]]; then
    info "3. DNS-Filter auf dem Stick: blockt Amazons Werbe-, Tracking- und Update-Server"
    [[ -n $DNS_UPSTREAM ]] && info "   übrige Anfragen über AdGuard DNS (blockt Werbung/Tracker in Apps)"
    info "   (einmal am Fernseher die VPN-Frage mit OK bestätigen)"
  fi
  [[ $SMARTTUBE == 1 ]] && info "4. SmartTube zusätzlich zu YouTube (Installation 5-10 Min.)"
  info "Nicht möglich: ein eigener Startbildschirm. Fire OS 5 gibt die Home-Taste nicht her"
  info "(auf einem Fire TV Stick 2. Generation ausprobiert), Amazons Startseite bleibt."
  printf '\n'
  info "Der Stick startet dabei 1-2 Mal neu. Rückgängig jederzeit mit Rueckgaengig.cmd."
}

apply_privacy_settings() {
  local f ns key val n=0
  local files=("$DUMBTV/data/fireos/settings.txt")
  [[ $ALEXA == 0 ]] && files+=("$DUMBTV/data/fireos/settings.alexa.txt")
  for f in "${files[@]}"; do
    while read -r ns key val; do
      [[ -z ${ns:-} || -z ${val:-} ]] && continue
      [[ $DRY_RUN == 0 ]] && set_setting "$ns" "$key" "$val"
      n=$((n+1))
    done < <(list_of "$f" | sed 's/ = / /')
  done
  fertig "$n Einstellungen gesetzt (Werbe-ID, Nutzungsdaten, Autoplay, Animationen)"
}

# Wenn sich YouTube nicht abschalten ließ (Fire OS 5), wenigstens im Startbildschirm ausblenden.
hide_youtube_if_needed() {
  local yt=com.amazon.firetv.youtube
  [[ $SMARTTUBE == 1 && $STARTBILDSCHIRM == fireframe ]] || return 0
  is_installed org.smarttube.stable || return 0
  pkgs_now -e | grep -qxF "$yt" || return 0
  load_home_conf
  [[ ",$H_HIDE," == *",$yt,"* ]] && return 0
  H_HIDE=${H_HIDE:+$H_HIDE,}$yt
  [[ -n $H_DOCK ]] && H_DOCK=$(printf '%s' "$H_DOCK" | tr ',' '\n' | grep -vxF "$yt" | paste -sd, - || true)
  save_home_conf
  apply_home_conf
  info "YouTube ist im Startbildschirm ausgeblendet, SmartTube übernimmt."
}

einrichten_fireos5() {
  plan_text_fireos5
  [[ $DRY_RUN == 1 ]] && info "TROCKENLAUF: es wird nichts am Stick verändert."
  frage_jn "Loslegen?" || fehler "Abgebrochen, nichts verändert."

  backup_now
  local mem_before; mem_before=$(mem_mb "$BEFORE_DIR/meminfo.txt")
  EXTRAS=""
  CUR_UPSTREAM=$DNS_UPSTREAM

  titel "Datenschutz und Tempo"
  apply_privacy_settings
  configure_dumbtv "$DNS_UPSTREAM" || fehler "dumbtv-Konfiguration fehlgeschlagen."

  titel "DNS-Filter"
  setup_dns_fos5

  if [[ $SMARTTUBE == 1 ]]; then
    titel "SmartTube"
    info "Auf diesem alten Stick dauert die Installation 5 bis 10 Minuten: Fire OS 5 übersetzt die"
    info "ganze App schon beim Installieren. Bitte nicht abbrechen."
    if is_installed org.smarttube.stable && [[ $DRY_RUN == 0 ]]; then
      ok "SmartTube ist schon installiert"
    elif with_heartbeat run_dumbtv youtube.sh "$(dry_flag)" || { [[ $DRY_RUN == 0 ]] && is_installed org.smarttube.stable; }; then
      fertig "SmartTube installiert"
    else warn "SmartTube konnte nicht eingerichtet werden (Details oben)."; fi
  fi

  # Ein Startbildschirm aus einem früheren Lauf kann die Home-Taste hier nicht übernehmen: weg damit.
  if [[ $DRY_RUN == 0 ]] && is_installed "$HOME_PKG"; then
    home_service_off
    adbs uninstall "$HOME_PKG" >/dev/null 2>&1 && info "BetterFireTV-Startbildschirm entfernt (geht auf Fire OS 5 nicht)"
  fi

  if [[ $DRY_RUN == 1 ]]; then
    titel "Trockenlauf beendet, am Stick wurde nichts verändert."
    return 0
  fi
  titel "Kontrolle"
  [[ $DNS_FILTER == 1 ]] && { dns_blocked && ok "DNS-Filter blockt" || warn "DNS-Filter blockt gerade nicht."; }
  local after="$DEVDIR/nachher-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$after"
  dev "cat /proc/meminfo" > "$after/meminfo.txt"
  adbs exec-out screencap -p > "$after/bildschirm.png" 2>/dev/null || true
  local mem_after; mem_after=$(mem_mb "$after/meminfo.txt")
  [[ -n $mem_before && -n $mem_after ]] && ok "Freier Arbeitsspeicher: vorher $mem_before MB, jetzt $mem_after MB"
  summary
}

mode_einrichten() {
  load_config
  [[ -d $DUMBTV/scripts ]] || fehler "vendor/dumbtv fehlt."
  connect_tv
  [[ $SDK -ge 22 ]] || fehler "Fire OS 4 oder älter wird nicht unterstützt."
  if [[ $SDK -lt 25 ]]; then einrichten_fireos5; return; fi
  plan_text
  [[ $DRY_RUN == 1 ]] && info "TROCKENLAUF: es wird nichts am Stick verändert."
  frage_jn "Loslegen?" || fehler "Abgebrochen, nichts verändert."

  backup_now
  local mem_before; mem_before=$(mem_mb "$BEFORE_DIR/meminfo.txt")

  EXTRAS=$(extras_for_device)
  CUR_UPSTREAM=$DNS_UPSTREAM
  titel "Werbung und Ballast abschalten"
  configure_dumbtv "$DNS_UPSTREAM" || fehler "dumbtv-Konfiguration fehlgeschlagen."
  run_dumbtv preflight.sh || fehler "Vorprüfung fehlgeschlagen, nichts verändert."
  run_dumbtv debloat.sh "$(dry_flag)" || fehler "Abschalten fehlgeschlagen. Rueckgaengig.cmd stellt den alten Zustand her."
  fertig "Amazon-Ballast deaktiviert"
  run_dumbtv lockdown.sh "$(dry_flag)" || warn "Geschützte Amazon-Dienste konnten nicht gebremst werden."

  titel "DNS-Filter"
  setup_dns

  if [[ $SMARTTUBE == 1 ]]; then
    titel "SmartTube statt YouTube"
    if run_dumbtv youtube.sh "$(dry_flag)"; then fertig "SmartTube installiert, YouTube deaktiviert"
    elif [[ $DRY_RUN == 0 ]] && is_installed org.smarttube.stable; then ok "SmartTube installiert"
    else warn "SmartTube konnte nicht eingerichtet werden (Details oben)."; fi
  fi

  titel "Startbildschirm"
  if [[ $DRY_RUN == 1 ]]; then
    info "[Trockenlauf] $STARTBILDSCHIRM würde installiert."
  else
    case $STARTBILDSCHIRM in
      fireframe) install_home && hide_youtube_if_needed ;;
      dumbtv)    install_dumbtv_home ;;
      amazon)    info "Amazons Startbildschirm bleibt." ;;
    esac
  fi

  if [[ $DRY_RUN == 1 ]]; then
    titel "Trockenlauf beendet, am Stick wurde nichts verändert."
    return 0
  fi
  titel "Kontrolle"
  run_dumbtv verify.sh || warn "Die Kontrolle meldet Abweichungen (Details oben)."
  if [[ $DRY_RUN == 0 ]]; then
    local after="$DEVDIR/nachher-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$after"
    dev "cat /proc/meminfo" > "$after/meminfo.txt"
    dev "pm list packages -d" > "$after/pakete-deaktiviert.txt"
    adbs exec-out screencap -p > "$after/bildschirm.png" 2>/dev/null || true
    local mem_after; mem_after=$(mem_mb "$after/meminfo.txt")
    [[ -n $mem_before && -n $mem_after ]] && ok "Freier Arbeitsspeicher: vorher $mem_before MB, jetzt $mem_after MB"
  fi
  summary
}

summary() {
  titel "Fertig"
  if [[ ${#WARNUNGEN[@]} -eq 0 ]]; then
    ok "Alles hat geklappt."
  else
    info "Fertig, mit ${#WARNUNGEN[@]} Hinweis(en):"
    local w; for w in "${WARNUNGEN[@]}"; do info "  - $w"; done
  fi
  printf '\n'
  info "Tipps für die Fernbedienung:"
  case $STARTBILDSCHIRM in
    fireframe)
      info "  - Dock bearbeiten: am PC Startbildschirm.cmd, oder am TV OK lange drücken."
      info "  - Eigene Hintergrundbilder: am PC Hintergrund.cmd."
      info "  - Amazon-Einstellungen: oben rechts das Zahnrad." ;;
    dumbtv)
      info "  - dumbtv home: OK lange drücken = App verschieben, umbenennen, ausblenden."
      info "  - Nach oben: Options (Aussehen) und Settings (Amazon-Einstellungen)." ;;
  esac
  [[ $SMARTTUBE == 1 ]] && info "  - SmartTube: einmal Einstellungen > Allgemein > Shorts ausblenden."
  info "Alles zurück: Rueckgaengig.cmd (ADB-Debugging muss dafür an sein)."
  info "Protokoll: ${LOG#"$ROOT"/}"
}

reconcile() {  # $1 Original-Backup
  local b=$1 p out tmp
  tmp=$(mktemp -d)
  pkgs_of "$b/pakete-installiert.txt" > "$tmp/b_inst"
  pkgs_of "$b/pakete-aktiv.txt" > "$tmp/b_en"
  pkgs_of "$b/pakete-deaktiviert.txt" > "$tmp/b_dis"
  touched_universe > "$tmp/uni"

  # a) Apps, die vorher nicht da waren und von diesem Tool stammen
  pkgs_now > "$tmp/n_inst"
  for p in $OUR_APPS; do
    grep -qxF "$p" "$tmp/n_inst" || continue
    grep -qxF "$p" "$tmp/b_inst" && continue
    [[ $p == "$HOME_PKG" || $p == "$FF_PKG" ]] && home_service_off
    if [[ $p == tv.dumbtv.home ]]; then
      ADB="$ADB" ADB_SERIAL="$S" bash "$DUMBTV/launcher/install.sh" --undo >/dev/null 2>&1 || true
    fi
    out=$(adbs uninstall "$p" 2>&1 | tr -d '\r' | tail -1)
    [[ $out == *Success* ]] && ok "$p entfernt" || warn "$p ließ sich nicht entfernen: $out"
    [[ $p == "$HOME_PKG" ]] && dev "rm -rf $HOME_MEDIA" >/dev/null
  done

  # b) vorher installiert, jetzt weg -> zurückholen
  pkgs_now > "$tmp/n_inst"
  while read -r p; do
    [[ -z $p ]] && continue
    out=$(dev1 "cmd package install-existing $p")
    if [[ $out == *installed* || $out == *Success* ]]; then ok "$p wieder installiert"
    else warn "$p fehlt und kommt so nicht zurück ($out). Ggf. aus dem Appstore installieren."; fi
  done < <(LC_ALL=C comm -23 "$tmp/b_inst" "$tmp/n_inst")

  # c) vorher an, jetzt aus -> einschalten
  pkgs_now -d > "$tmp/n_dis"
  while read -r p; do
    [[ -z $p ]] && continue
    out=$(dev1 "pm enable --user 0 $p")
    [[ $out == *enabled* ]] && ok "$p wieder an" || warn "$p ließ sich nicht einschalten: $out"
  done < <(LC_ALL=C comm -12 "$tmp/b_en" "$tmp/n_dis")

  # d) vorher aus, jetzt an (nur was wir je anfassen) -> wieder aus
  pkgs_now -e > "$tmp/n_en"
  while read -r p; do
    [[ -z $p ]] && continue
    out=$(dev1 "pm disable-user --user 0 $p")
    [[ $out == *disabled* ]] && ok "$p wieder aus (war vorher aus)" || info "$p: $out"
  done < <(LC_ALL=C comm -12 "$tmp/b_dis" "$tmp/n_en" | LC_ALL=C comm -12 - "$tmp/uni")

  # e) Einstellungen
  local ns key bv nv changed=0
  while read -r ns key; do
    nv=$(dev1 "settings get $ns $key")
    if bv=$(value_in "$b/settings-$ns.txt" "$key"); then
      [[ $nv == "$bv" ]] && continue
      set_setting "$ns" "$key" "$bv"; changed=$((changed+1))
    else
      [[ -z $nv || $nv == null ]] && continue
      del_setting "$ns" "$key"; changed=$((changed+1))
    fi
  done < <(settings_keys)
  ok "$changed Einstellung(en) auf den Originalwert gesetzt"

  # f) Netzwerkregeln (Datensparmodus und Sperrliste)
  if grep -qi 'enabled' "$b/netpolicy-restrict-background.txt"; then
    dev "cmd netpolicy set restrict-background true" >/dev/null
  else
    dev "cmd netpolicy set restrict-background false" >/dev/null
  fi
  local before_uids now_uids u
  before_uids=$(grep -oE '[0-9]{4,}' "$b/netpolicy-blacklist.txt" | sort -u)
  now_uids=$(dev "cmd netpolicy list restrict-background-blacklist" | grep -oE '[0-9]{4,}' | sort -u)
  for u in $now_uids; do
    in_list "$u" "$before_uids" || dev "cmd netpolicy remove restrict-background-blacklist $u" >/dev/null
  done
  ok "Netzwerkregeln wie vorher"

  # g) Hintergrund-Rechte (appops) der Pakete, die dumbtv gebremst hat
  local op want nowm fixed=0
  while read -r p; do
    grep -qxF "$p" "$tmp/n_inst" || continue
    for op in RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND; do
      nowm=$(dev "appops get $p $op" | grep -oE "$op: [a-z]+" | head -1 | awk '{print $2}')
      [[ $nowm == ignore || $nowm == deny ]] || continue
      want=$(awk -v p="### $p" -v op="$op" '
        $0 == p { inside = 1; next }
        /^### / { inside = 0 }
        inside && index($0, op ": ") { sub(".*" op ": ", ""); sub(/[;[:space:]].*/, ""); print; exit }
      ' "$b/appops.txt")
      want=${want:-allow}
      [[ $want == "$nowm" ]] && continue
      dev "appops set $p $op $want" >/dev/null; fixed=$((fixed+1))
    done
  done < "$tmp/uni"
  ok "Hintergrund-Rechte: $fixed zurückgesetzt"

  # h) Akku-/Doze-Ausnahmen, die neu dazugekommen sind
  local w
  for w in $(dev "dumpsys deviceidle whitelist" | awk -F, 'NF >= 2 {print $2}'); do
    grep -qE ",$w," "$b/deviceidle-whitelist.txt" 2>/dev/null && continue
    grep -qxF "$w" "$tmp/uni" || continue
    dev "dumpsys deviceidle whitelist -$w" >/dev/null
  done

  # i) DNS-Filter-App zuletzt: ihr VPN-Ende trennt die WLAN-Verbindung zu adb kurz.
  if grep -qxF "$VPN_APP" "$tmp/n_inst" && ! grep -qxF "$VPN_APP" "$tmp/b_inst"; then
    del_setting secure always_on_vpn_app
    adbs uninstall "$VPN_APP" >/dev/null 2>&1
    sleep 3
    adb_reconnect || true
    if pkgs_now | grep -qxF "$VPN_APP"; then warn "personalDNSfilter ließ sich nicht entfernen."
    else ok "personalDNSfilter entfernt"; fi
  fi
  rm -rf "$tmp"
}

compare_with() {  # $1 Backup; meldet verbleibende Unterschiede
  local b=$1 tmp diffs=0 p
  tmp=$(mktemp -d)
  pkgs_of "$b/pakete-installiert.txt" > "$tmp/b_inst"
  pkgs_of "$b/pakete-aktiv.txt" > "$tmp/b_en"
  pkgs_now > "$tmp/n_inst"
  pkgs_now -e > "$tmp/n_en"
  while read -r p; do [[ -n $p ]] && { warn "fehlt noch: $p"; diffs=$((diffs+1)); }; done < <(LC_ALL=C comm -23 "$tmp/b_inst" "$tmp/n_inst")
  while read -r p; do
    [[ -z $p ]] && continue
    grep -qxF "$p" "$tmp/n_inst" || continue
    warn "noch deaktiviert: $p"; diffs=$((diffs+1))
  done < <(LC_ALL=C comm -23 "$tmp/b_en" "$tmp/n_en")
  local neu; neu=$(LC_ALL=C comm -13 "$tmp/b_inst" "$tmp/n_inst" | tr '\n' ' ')
  [[ -n ${neu// /} ]] && info "Seit dem Backup neu installiert (bleibt): $neu"
  rm -rf "$tmp"
  return "$diffs"
}

find_original() {
  ORIG="$DEVDIR/original"
  if [[ ! -f $ORIG/info.txt ]] && [[ $(dev1 "test -f $TVDIR/original/info.txt && echo ja") == ja ]]; then
    info "Hole das Original-Backup vom Stick ..."
    adbs pull "$TVDIR/original" "$DEVDIR/" >/dev/null 2>&1 || true
  fi
  [[ -f $ORIG/info.txt ]]
}

mode_rueckgaengig() {
  load_config
  connect_tv
  find_original || fehler "Kein Original-Backup für dieses Gerät gefunden (weder im Ordner backups noch auf dem Stick)."
  titel "Zurück auf den Stand vom $(sed -n 's/^erstellt=//p' "$ORIG/info.txt")"
  info "Alle deaktivierten Amazon-Apps wieder an, YouTube zurück, Amazons Startbildschirm zurück,"
  info "Startbildschirm, SmartTube und der DNS-Filter werden entfernt, Einstellungen wie im Backup."
  info "Apps, die nach dem Backup selbst installiert wurden, bleiben."
  frage_jn "Wirklich alles zurücksetzen?" || fehler "Abgebrochen, nichts verändert."

  titel "1/4 Sicherung des jetzigen Stands"
  snapshot "$DEVDIR/vor-rueckgaengig-$(date +%Y%m%d-%H%M%S)" vor-rueckgaengig >/dev/null && ok "gesichert"

  titel "2/4 dumbtv-Änderungen zurücknehmen"
  NO_REBOOT=1
  run_dumbtv restore.sh -y || warn "dumbtv-Restore meldete Fehler, der Abgleich unten fängt das auf."
  NO_REBOOT=0
  adb_reconnect || true

  titel "3/4 Abgleich mit dem Original-Backup"
  reconcile "$ORIG"

  titel "4/4 Neustart und Kontrolle"
  reboot_tv || true
  if compare_with "$ORIG"; then
    ok "Der Stick ist wieder im Zustand vom $(sed -n 's/^erstellt=//p' "$ORIG/info.txt")."
  else
    warn "Einzelne Unterschiede bleiben (siehe oben). Rueckgaengig.cmd einfach noch einmal starten."
  fi
  info "Das Backup bleibt erhalten, Einrichten.cmd geht jederzeit wieder."
}

mode_backup() {
  load_config
  connect_tv
  backup_now
}

mode_status() {
  load_config
  connect_tv
  titel "Status"
  local front a11y vpn dis mem
  front=$(front_pkg)
  a11y=$(a11y_list)
  vpn=$(dev1 "settings get secure always_on_vpn_app")
  dis=$(dev "pm list packages -d" | grep -c '^package:')
  mem=$(dev "cat /proc/meminfo" | awk '/MemAvailable/ {print int($2/1024)}')
  info "Im Vordergrund:        ${front:-unbekannt}"
  case ":$a11y:" in *":$HOME_SVC:"*) info "Startbildschirm:       BetterFireTV (Home-Taste übernommen)" ;;
    *":$FF_SVC:"*) info "Startbildschirm:       FireFrame (alte Version, Startbildschirm.cmd aktualisiert)" ;;
    *tv.dumbtv.home*) info "Startbildschirm:       dumbtv home" ;;
    *) info "Startbildschirm:       Amazon" ;; esac
  [[ $vpn == "$VPN_APP" ]] && info "DNS-Filter:            an" || info "DNS-Filter:            aus"
  info "Deaktivierte Pakete:   $dis"
  if [[ ":$a11y:" == *":$HOME_SVC:"* ]] && read_apps; then
    info "Dock:                  $(show_dock "$(dock_csv)" | sed 's/^ *//')"
  fi
  info "Freier Arbeitsspeicher: ${mem:-?} MB"
  if [[ -f $DEVDIR/original/info.txt ]]; then
    info "Original-Backup:       $(sed -n 's/^erstellt=//p' "$DEVDIR/original/info.txt")"
  else
    info "Original-Backup:       keins auf diesem PC"
  fi
  if [[ -f $CONF && $SDK -ge 25 ]]; then
    titel "Kontrolle (dumbtv verify)"
    run_dumbtv verify.sh || true
  fi
}

# Ein sauberes Bild vom Startbildschirm fürs README: kurz mit NASA-Hintergrund, dann zurück.
mode_screenshot() {
  load_config
  connect_tv
  ensure_home
  load_home_conf
  local dir=${BFTV_BILDER:-$ROOT/docs/bilder} out sig
  mkdir -p "$dir"
  out="$dir/startbildschirm.png"
  titel "Bild vom Startbildschirm"
  info "Für das Bild wird kurz ein NASA-Hintergrund gezeigt, danach kommt deiner zurück."
  home_send "--ez builtins true --es wallpaper aurora"
  dev "input keyevent KEYCODE_HOME" >/dev/null
  sleep 6
  adbs exec-out screencap -p > "$out.tmp" 2>/dev/null
  # Hintergrund wiederherstellen
  local args=""
  if [[ $H_BUILTINS == 0 ]]; then args+=" --ez builtins false"; fi
  [[ -n $H_WALLPAPER ]] && args+=" --es wallpaper $(shq "$H_WALLPAPER")"
  [[ -n $args ]] && home_send "$args"
  sig=$(head -c 4 "$out.tmp" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [[ $sig != 89504e47 ]]; then
    rm -f "$out.tmp"
    fehler "Kein Bild bekommen. Ist der Stick an und zeigt den Startbildschirm?"
  fi
  mv -f "$out.tmp" "$out"
  ok "Gespeichert: docs/bilder/startbildschirm.png"
  info "Fürs Repo: git add docs/bilder/startbildschirm.png, committen, pushen."
}

# --- Start ----------------------------------------------------------------------------------
# Aufgerufen von tool/betterfiretv.sh, nachdem diese Datei komplett eingelesen ist.
bftv_main() {
  MODE=${1:-}
  shift || true
  OPT_IP=""; OPT_KANDIDATEN=""; OPT_NEU=""; YES=0; DRY_RUN=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --ip) OPT_IP=${2:-}; shift 2 ;;
      --kandidaten) OPT_KANDIDATEN=${2:-}; shift 2 ;;
      --neu) OPT_NEU=${2:-}; shift 2 ;;
      -y|--ja) YES=1; shift ;;
      --trockenlauf|--dry-run) DRY_RUN=1; shift ;;
      *) fehler "Unbekannte Option: $1" ;;
    esac
  done

  case $MODE in einrichten|rueckgaengig|backup|status|startbildschirm|hintergrund|screenshot) ;; *)
    sed -n '6,13p' "$CORE_FILE" | sed 's/^# \{0,1\}//'; exit 2 ;; esac

  for t in "$ADB" curl awk sed tr comm; do
    command -v "$t" >/dev/null || fehler "$t nicht gefunden."
  done

  mkdir -p "$LOGDIR"
  LOG="$LOGDIR/$(date +%Y%m%d-%H%M%S)-$MODE.log"
  exec > >(tee -a "$LOG") 2>&1
  trap '[[ -n $DT_OUT ]] && rm -f "$DT_OUT"; sleep 0.3' EXIT
  printf '%sBetterFireTV %s%s · %s\n' "$B" "$VERSION" "$N" "$MODE"

  "mode_$MODE"
}
