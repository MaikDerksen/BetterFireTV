# TCL Smart TV G10 (Google TV, Android 12)

Contributed by [@nolanvargas](https://github.com/nolanvargas).

These notes are from one **TCL Smart TV (G10_4K_US_NF / G10), Android 12**,
read over ADB on October 20, 2026. The package changes were made on
September 6, 2026. A snapshot taken before that session is the baseline;
the same disable set was still in effect when the TV was read again.

```
ro.product.model=Smart TV
ro.product.name=G10_4K_US_NF
ro.product.device=G10
ro.build.fingerprint=TCL/G10_4K_US_NF/G10:12/STT2.230203.001/AS102:user/release-keys
ro.build.description=G10-user 12 STT2.230203.001 AS50 release-keys
ro.build.display.id=STT2.230203.001 release-keys
ro.build.version.release=12
ro.build.version.sdk=31
ro.build.version.security_patch=2025-09-05
ro.product.cpu.abi=armeabi-v7a
ro.hardware=rtd6748
kernel=5.4.274+
```

`ro.build.fingerprint` and `ro.build.description` disagree on the build
number (`AS102` versus `AS50`). Both values are copied from the device.

About 1.8 GB of RAM (`MemTotal` 1807460 kB). The only ABI is
`armeabi-v7a`; an arm64 APK does not install.

This is one household's set of choices, applied by hand. The notes say why
another owner might keep each app.

## What this session disabled

Twenty-nine packages were enabled in the baseline and disabled for user 0
during the session. None of them was uninstalled. On October 20 they were
still disabled. `settings get global boot_count` was still `10`, the same
value as the September snapshot, so this note does **not** show that the
disables survive a reboot. Another TCL build (a G05) has been reported to
drop a launcher disable across a reboot.

| Package | Role | What to consider before disabling |
|---|---|---|
| `com.google.android.apps.tv.launcherx` | Google TV home | Disable only after another home screen is installed and is the default. On this set that was a third-party launcher. |
| `com.google.android.tungsten.setupwraith` | First-run setup; also answers HOME | Disabled together with `launcherx`. Disabling `launcherx` alone can leave setup answering HOME. |
| `com.google.android.apps.tv.dreamx` | Ambient screensaver (Backdrop) | The screensaver component was pointed at `com.android.dreams.basic/.Colors` instead. |
| `com.google.android.youtube.tv` | YouTube | Keep if anyone uses the YouTube app. |
| `com.netflix.ninja` | Netflix | Keep if anyone uses Netflix. |
| `com.netflix.tokenmanager` | Netflix companion | Goes with the Netflix app. |
| `com.amazon.amazonvideo.livingroom` | Prime Video | Keep if anyone uses Prime Video. |
| `com.google.android.tv.remote.service` | Phone / Android TV remote service | The TV remote still operated the set afterwards. A phone remote was not tested. |
| `com.google.android.marvin.talkback` | TalkBack | Keep if anyone uses it. |
| `com.google.android.onetimeinitializer` | One-time Google initializer | Already past first setup on this set. |
| `com.google.android.syncadapters.calendar` | Calendar sync | Keep if a calendar account is in use. |
| `com.tcl.airplay2` | TCL AirPlay | Keep to receive AirPlay. |
| `com.realtek.airplay2` | Realtek AirPlay | Same choice as TCL AirPlay. Both were disabled together. |
| `com.realtek.dongledetect` | Dongle detection | Keep if a wireless display dongle is used. |
| `com.tcl.ttvs` | TCL services, including update UI | The G08 notes kept this. Vendor update UI may be unavailable here. |
| `com.tcl.suspension` | Source / input path on some TCL builds | Disabled here, and HDMI was still selected afterwards from the replacement home screen. Other G10 firmware may not behave the same way. |
| `com.tcl.partnercustomizer` | TCL customization of home rows | Home-row layout and TCL tiles may change. |
| `com.tcl.gamebar` | Game-mode overlay | Keep for the game overlay. |
| `com.tcl.ui_mediaCenter` | TCL media player | Keep if anyone uses that player. |
| `com.tcl.android.webview` | TCL WebView build | The Google WebView package was left enabled. |
| `com.tcl.hotelmenu` | Hotel menu | Keep on a set used as a hotel TV. |
| `com.tcl.initsetup` | First-run setup | Already past first setup on this set. |
| `com.tcl.ocean.instructions` | On-TV manual | The built-in manual may be unavailable. |
| `com.tcl.repairguide` | Repair guide | The built-in repair guide may be unavailable. |
| `com.tcl.UpdatePeripheral` | Peripheral firmware helper | This household did not use it. |
| `com.android.dynsystem` | Dynamic system updates | Leave it if that update path is wanted. |
| `com.android.managedprovisioning` | Work-profile provisioning | Not used on this set. |
| `com.android.printspooler` | Printing | Keep if an app prints. |
| `com.android.wallpaper.livepicker` | Live wallpaper picker | Not used on this set. |

## Already off before the session

These were already disabled for user 0 in the baseline. This session did
not turn them off, and did not test what happens when they go from enabled
to disabled.

`android.autoinstalls.config.google.gtvpai`,
`com.google.android.feedback`, `com.google.android.partnersetup`,
`com.tcl.channelplus`, `com.tcl.dashboard`, `com.tcl.esticker`,
`com.tcl.exhibit`, `com.tcl.interactive`, `com.tcl.logkit`,
`com.tcl.smartlink.core`, `com.tcl.tv.plus`, `com.tcl.tv.tclhome_passive`,
`com.tcl.useragreement`, `tv.samba.ssm.ui`.

These were already uninstalled for user 0 in the baseline, and were still
absent on October 20. This session did not uninstall them. On the G08
notes, assistant and Cast were kept; on this G10 they were already gone,
so there is no remote-mic or Cast path here.

`com.google.android.apps.mediashell`, `com.google.android.katniss`,
`com.google.android.play.games`, `com.google.android.videos`,
`com.google.android.youtube.tvmusic`, `com.tcl.messagebox`,
`com.tcl.smartalexa`, `com.tcl.usercenter`.

`com.tcl.browser` and `com.android.healthconnect.controller`, both in the
G08 notes, are not installed on this build.

## What the household kept

Inputs and live TV: `com.tcl.tv`, `com.tcl.tvinput`. Remote pairing:
`com.tcl.autopair`. Remote keys: `com.tcl.globalkeyoverlay`. TCL system
service and configuration: `com.tcl.systemserver`, `com.tcl.providers.config`.
Factory menu: `com.tcl.factory.view`.

Also left enabled: Android TV settings, system UI, the basic screensaver
(`com.android.dreams.basic`), Google Play services and the Play Store,
the Latin keyboard, Google text-to-speech, and Google WebView.

## Home screen and settings

A third-party launcher was set as home; dumbtv home was not installed.
`cmd package get-home-activities` is not a command on this Android 12 build.

`ro.product.model` is `Smart TV`, with a space. `adb devices -l` prints
`model:Smart_TV`.

Two settings were changed and were still set on October 20:

- Private DNS: `private_dns_mode=hostname` with an ad-blocking resolver. No
  on-device DNS-filter app was installed.
- Screensaver component: from
  `com.google.android.apps.tv.dreamx/.service.Backdrop` to
  `com.android.dreams.basic/.Colors`.

## Reversibility and evidence limits

Each package this session disabled can be turned back on with
`adb shell pm enable --user 0 <package>`. That is not an exact restore
for a package that was already disabled. The eight packages uninstalled
for user 0 were already in that state; `cmd package install-existing`
can put an existing system APK back for user 0, and was not run here.

The TV was still in daily use on 20 October.
