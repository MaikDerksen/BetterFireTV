#!/usr/bin/env bash
# Baut home/betterfiretv-home.apk ohne Gradle, mit den Android-Werkzeugen aus Ubuntu/Debian:
#   sudo apt-get install aapt dalvik-exchange apksigner zipalign android-sdk-platform-23
# Plain Java ohne Lambdas (dx kann sie für Android nicht umschreiben), Ressourcen mit aapt.
# Der Signierschlüssel liegt in signing/; Updates müssen damit signiert sein.
set -euo pipefail
cd "$(dirname "$0")"
SDK=${ANDROID_SDK:-/usr/lib/android-sdk}
JAR=${ANDROID_JAR:-$SDK/platforms/android-23/android.jar}
BT=$SDK/build-tools/debian
[[ -f $JAR ]] || { echo "android.jar fehlt ($JAR)" >&2; exit 1; }

rm -rf out; mkdir -p out/classes
aapt package -f -M AndroidManifest.xml -S res -A assets -I "$JAR" -F out/base.apk
# shellcheck disable=SC2046
javac -nowarn -Xlint:-options -encoding UTF-8 -source 8 -target 8 -bootclasspath "$JAR" \
  -d out/classes $(find src -name '*.java')
"$BT/dx" --dex --min-sdk-version=22 --output=out/classes.dex out/classes
cp out/base.apk out/unsigned.apk
(cd out && zip -q -j unsigned.apk classes.dex)
zipalign -f 4 out/unsigned.apk out/aligned.apk

KS=signing/betterfiretv.jks; PASS=${KEYSTORE_PASS:-betterfiretv}
mkdir -p signing
[[ -f $KS ]] || keytool -genkeypair -keystore "$KS" -storepass "$PASS" -keypass "$PASS" -alias betterfiretv \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=BetterFireTV" >/dev/null 2>&1
apksigner sign --ks "$KS" --ks-pass "pass:$PASS" --out betterfiretv-home.apk out/aligned.apk
sha256sum betterfiretv-home.apk | awk '{print $1}' > betterfiretv-home.apk.sha256
sed -n 's/.*android:versionCode="\([0-9]*\)".*/\1/p' AndroidManifest.xml | head -1 > betterfiretv-home.apk.version
rm -f betterfiretv-home.apk.idsig
echo "Gebaut: betterfiretv-home.apk ($(du -k betterfiretv-home.apk | cut -f1) KB)"
