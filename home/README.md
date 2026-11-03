# BetterFireTV-Startbildschirm

Eine Fassung von [FireFrame](https://github.com/dyascj/FireFrame) 1.1.3 (MIT) für BetterFireTV.

Geändert gegenüber FireFrame:

- **App-Kacheln in Farbe:** das TV-Banner der App, sonst ihr Symbol auf einer Fläche in ihrer Farbe. Keine weißen Logos, keine Graustufen.
- **Vom PC einstellbar:** Dock-Reihenfolge, ausgeblendete Apps und Hintergrundbild per `am start -n tv.betterfiretv.home/com.fireframe.home.MainActivity` mit `--es dock "a,b"`, `--es hide "a,b"`, `--es wallpaper "file:bild.jpg"`, `--ez builtins true|false`, `--ez reload true`, `--ez export true`. Die App-Liste steht danach in `/sdcard/Android/media/tv.betterfiretv.home/apps.txt`.
- **Eigene Hintergrundbilder** aus `/sdcard/Android/media/tv.betterfiretv.home/wallpapers/`.
- **Hilfs-Apps ausgeblendet:** personalDNSfilter, FireFrame und dumbtv home tauchen nicht im Dock auf.
- **Am Fernseher:** „Ausblenden“ im App-Menü der App-Schublade, „Ausgeblendete Apps wieder zeigen“ in den Einstellungen oben rechts.
- **Weitere Änderungen:** Texte auf Deutsch, kein Auto-Update, keine Internet-Berechtigung, eigener Paketname `tv.betterfiretv.home`.

Die Home-Taste übernimmt der unveränderte Mechanismus von FireFrame: eine Bedienungshilfe (`HomeService`), die Amazons Startbildschirm sofort verdeckt.

## Bauen

```sh
sudo apt-get install aapt dalvik-exchange apksigner zipalign android-sdk-platform-23
./build.sh        # -> betterfiretv-home.apk, .sha256, .version
```

Gebaut wird ohne Gradle. Der Code enthält bewusst keine Lambdas, weil `dx` sie nicht umschreiben kann.

Signiert wird mit `signing/betterfiretv.jks` (Passwort `betterfiretv`). Der Schlüssel liegt bewusst nicht im Repo. Fehlt er, legt `build.sh` einen neuen an. Eine so gebaute APK lässt sich nicht über die alte installieren, deshalb deinstalliert das Tool die alte Version dann zuerst.

## Lizenzen

Der Code steht unter der MIT-Lizenz, siehe `LICENSE`.

| Bestandteil | Lizenz |
|---|---|
| Schrift Inter | SIL OFL 1.1, siehe `assets/fonts/Inter-LICENSE.txt` |
| UI-Symbole | Material Symbols, Apache 2.0 |
| Hintergrundbilder | NASA, gemeinfrei |
