#!/usr/bin/env python3
"""Erzeugt den Zustand eines simulierten Fire TV Sticks: Stick 4K 2. Gen (Fire OS 8) oder mit 'fos5' einen Stick 2. Gen (Fire OS 5).

Aufruf: make_state.py ZUSTAND.json SDCARD-ORDNER [fos5]"""
import json, sys, re
from pathlib import Path
dt = Path(__file__).resolve().parent.parent / 'vendor/dumbtv/data/fireos'
def lst(f):
    return [l.split('#')[0].split()[0] for l in (dt/f).read_text().splitlines() if l.split('#')[0].strip()]
pk = {}
uid = 10100
def add(n, system=True, enabled=1, protected=False, runs=False):
    global uid
    uid += 1
    pk[n] = dict(system=system, enabled=enabled, installed=True, protected=protected, uid=uid, runs=runs)
for n in lst('packages.txt') + lst('alexa.txt') + lst('never-disable.txt'): add(n)
for n in lst('user-apps.txt')[:12]: add(n)
for n in lst('protected.txt'): add(n, protected=True, runs=True)
for n in ['com.amazon.kso.blackbird','com.amazon.wifilocker','com.amazon.d3','com.amazon.gamehub','com.amazon.cardinal',
          'com.amazon.comms.starktachyon','com.amazon.cast.sink','com.amazon.awvflingreceiver','com.amazon.firetv.youtube',
          'com.amazon.vizzini','com.android.settings','com.amazon.tv.ime']:
    add(n)
add('com.netflix.ninja', system=False)
add('com.disney.disneyplus', system=False)
pk['com.android.nfc']['enabled'] = 2           # vom System deaktiviert
pk['com.amazon.dummy.music']['enabled'] = 3    # vorher schon vom Nutzer aus
pk['com.amazon.hedwig']['runs'] = True
state = {
  'sdcard': sys.argv[2],
  'devices': {
    '192.168.178.45:5555': {'tv': True, 'authorized': False, 'auth_after': 2},
    '192.168.178.60:5555': {'tv': False, 'authorized': True},
  },
  'tv': {
    'props': {'ro.product.manufacturer': 'Amazon', 'ro.product.model': 'AFTKM', 'ro.build.version.sdk': '30',
              'ro.build.version.name': 'Fire OS 8.1.4.1 (RS8141/4891)', 'ro.serialno': 'G070VM1234567890',
              'sys.boot_completed': '1', 'ro.build.version.release': '11'},
    'packages': pk,
    'settings': {
      'global': {'window_animation_scale': '1.0', 'transition_animation_scale': '1.0', 'animator_duration_scale': '1.0',
                 'heads_up_notifications_enabled': '1', 'device_name': 'Fire TV von Mama', 'private_dns_mode': 'opportunistic'},
      'secure': {'limit_ad_tracking': '0', 'amz_limit_ad_tracking': '0', 'USAGE_METRICS_UPLOAD_ENABLED': '1',
                 'screensaver_components': 'com.amazon.bueller.photos/.Screensaver', 'enabled_accessibility_services': '',
                 'accessibility_enabled': '0', 'android_id': 'abc', 'x1': 'a', 'x2': 'b', 'x3': 'c'},
      'system': {'screen_off_timeout': '600000'},
    },
    'netpolicy': {'restrict': False, 'blacklist': []},
    'deviceidle': ['com.amazon.device.messaging'],
    'appops': {},
    'boot_id': 1,
    'front': 'com.amazon.tv.launcher/.ui.MainActivity',
    'offline': 0,
    'ff_works': True,
  },
}
if len(sys.argv) > 3 and sys.argv[3] == 'fos5':
    t = state['tv']; t['fos5'] = True
    t['props'].update({'ro.product.model': 'AFTT', 'ro.build.version.sdk': '22', 'ro.build.version.name': 'Fire OS 5.2.9.5 (688806320)',
                       'ro.serialno': 'G0K0H40472340AAA', 'ro.build.version.release': '5.1.1'})
    t['packages']['com.amazon.dummy.music']['enabled'] = 1
    t['packages']['com.android.nfc']['enabled'] = 1
Path(sys.argv[1]).write_text(json.dumps(state, indent=1))
print(len(pk), 'packages')
