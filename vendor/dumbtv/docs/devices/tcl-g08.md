# TCL Smart TV Pro G08 (Google TV, Android 14)

Contributed by [@maam00](https://github.com/maam00). Device report:
[catalog/devices/androidtv-tcl-g08.yaml](../../catalog/devices/androidtv-tcl-g08.yaml).

21 packages disabled for user 0 on one TCL Smart TV Pro (G08_4K_US), build
`tcl9618-user 14 UTT2.250416.001 AU14 release-keys`, on 18 October 2026. Nothing
was uninstalled, and the owner confirmed the TV worked afterwards.

This is one household's set of choices, applied by hand. The last column says why
another owner might keep each app.

## What was disabled

| Package | Role identified in the session | What to consider before disabling |
|---|---|---|
| `com.tcl.tv.plus` | TCL TV+ streaming channels | Keep if anyone watches TCL TV+. |
| `com.tcl.channelplus` | TCL Live/FAST channels | Keep if anyone uses those channels. |
| `com.tcl.tv.tclhome_passive` | TCL home content integration | TCL content suggestions may disappear. |
| `com.tcl.partnercustomizer` | TCL customization of Google TV rows | Home row layout and TCL tiles may change. |
| `com.tcl.interactive` | TCL TIAS background service | Its full dependency surface was not established; review it on the target build. |
| `com.tcl.smartlink.core` | TCL app installation service | Vendor-managed app installation may stop; check whether it is needed. |
| `com.tcl.messagebox` | TCL message inbox | TCL messages or notices may disappear. |
| `com.tcl.usercenter` | TCL account center | Keep if the household uses TCL account features. |
| `com.tcl.exhibit` | Retail demonstration component | Keep if the TV is used for retail demonstration. |
| `com.tcl.esticker` | Retail/store display component | Store-mode information displays may stop. |
| `com.tcl.ocean.instructions` | On-TV manual | The built-in help/manual may be unavailable. |
| `com.tcl.smartalexa` | TCL Alexa integration | Keep for Alexa-to-TV integration; an Echo working independently does not prove this integration is unnecessary. |
| `com.tcl.browser` | TCL web browser | Keep if anyone uses this browser. |
| `com.tcl.gamebar` | Game-mode overlay | Keep for console/game overlay controls. |
| `com.tcl.UpdatePeripheral` | TCL peripheral update utility | Peripheral firmware management may be unavailable; this household did not use it for its soundbar. |
| `com.tcl.logkit` | TCL log collection | Vendor support diagnostics may be affected. |
| `android.autoinstalls.config.google.gtvpai` | Partner app installation configuration | Partner app provisioning may change. |
| `com.google.android.feedback` | Google feedback reporting | Feedback/reporting features may be unavailable. |
| `com.google.android.play.games` | Google Play Games | Keep for games or Play Games features. |
| `com.android.printspooler` | Android printing | Keep if any installed app uses printing. |
| `com.android.healthconnect.controller` | Health Connect | Keep if any installed app depends on Health Connect. |

## What the household kept

The final setup kept Google TV home (`com.google.android.apps.tv.launcherx`),
Google's assistant (`com.google.android.katniss`), and TCL Intelligent picture
processing. Disabling the assistant during an earlier experiment removed the
remote microphone/voice-search path; it was re-enabled. Keeping these features
was a deliberate choice, not an incomplete launcher replacement.

The session also excluded these functional areas from cleanup:

- Inputs and live TV: `com.tcl.tv`, `com.tcl.tvinput`, Android TV settings and
  system UI.
- Remote pairing: `com.tcl.autopair` and
  `com.google.android.tv.remote.service`.
- TCL system components: `com.tcl.systemserver`, `com.tcl.dashboard`,
  `com.tcl.ttvs` (which also hosts TCL update UI), setup and configuration
  providers.
- Cast/AirPlay: `com.google.android.apps.mediashell`, `com.tcl.airplay2` and
  the MediaTek AirPlay components present on this build.
- Google Play services/store, keyboards, WebView, permission controllers,
  media/DRM services, and Dolby/MediaTek hardware services.

## Undo

`adb shell pm enable --user 0 <package>` turns any of them back on. Note the state
of a package before you change it: `pm enable` is not an exact undo for one that
was already disabled.
