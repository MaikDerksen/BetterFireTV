#!/usr/bin/env python3
"""Ein simulierter Fire TV Stick für tests/run.sh: beantwortet adb-Aufrufe aus einer JSON-Zustandsdatei.
Unbekannte Shell-Befehle werden in FAKE_TV_UNKNOWN protokolliert und leer beantwortet."""
import json, os, shlex, shutil, sys
from pathlib import Path

state_path = Path(os.environ['FAKE_TV_STATE'])
st = json.loads(state_path.read_text())
log = Path(os.environ.get('FAKE_TV_LOG', '/dev/null'))
unknown = Path(os.environ.get('FAKE_TV_UNKNOWN', '/dev/null'))
sd = Path(st['sdcard'])

def save():
    state_path.write_text(json.dumps(st, indent=1))

def out(s=''):
    if s:
        sys.stdout.write(s if s.endswith('\n') else s + '\n')

args = sys.argv[1:]
with log.open('a') as f:
    f.write(' '.join(args) + '\n')

if args[:1] == ['start-server'] or args[:1] == ['kill-server']:
    sys.exit(0)
if args[:1] == ['version']:
    out('Android Debug Bridge version 1.0.41'); out('Version 36.0.2-fake'); sys.exit(0)
if args[:1] == ['devices']:
    # simuliert: jemand drückt nach einer Weile am Fernseher auf "Zulassen"
    for d in st['devices'].values():
        if d.get('connected') and not d.get('authorized') and d.get('auth_after') is not None:
            d['auth_after'] -= 1
            if d['auth_after'] <= 0: d['authorized'] = True
    save()
    out('List of devices attached')
    for s, d in st['devices'].items():
        if d.get('connected'):
            out(f"{s}\t{'device' if d.get('authorized') else 'unauthorized'}")
    sys.exit(0)
if args[:1] == ['connect']:
    s = args[1]
    if s in st['devices']:
        d = st['devices'][s]
        if d.get('auth_after') is not None and not d.get('authorized'):
            d['auth_after'] -= 1
            if d['auth_after'] <= 0:
                d['authorized'] = True
        if d.get('authorized'):
            already = d.get('connected')
            d['connected'] = True; save()
            out(f'already connected to {s}' if already else f'connected to {s}')
            sys.exit(0)
        # wie neuere adb-Versionen: nicht freigegeben -> Meldung, Verbindung je nach Modus weg
        d['connected'] = not st.get('drop_unauth', False); save()
        out(f'failed to authenticate to {s}')
        sys.exit(1)
    out(f"failed to connect to '{s}': Connection refused")
    sys.exit(1)
if args[:1] == ['disconnect']:
    st['dropped'] = False
    save()
    sys.exit(0)

if args[:1] != ['-s']:
    sys.exit(90)
serial, args = args[1], args[2:]
d = st['devices'].get(serial)
if not d or not d.get('connected'):
    sys.stderr.write(f"error: device '{serial}' not found\n")
    sys.exit(1)
if args == ['get-state']:
    if d.get('authorized'):
        out('device'); sys.exit(0)
    sys.stderr.write('error: device unauthorized.\nThis adb server\'s $ADB_VENDOR_KEYS is not set\n'); sys.exit(1)
if not d.get('authorized'):
    sys.stderr.write('error: device unauthorized.\n')
    sys.exit(1)
if not d.get('tv'):
    # anderes Android-Gerät
    if args[:1] == ['shell'] and 'manufacturer' in ' '.join(args):
        out('Google'); sys.exit(0)
    sys.exit(0)

tv = st['tv']
pk = tv['packages']        # name -> {system, enabled(0/1/2/3), installed, protected, uid}
S = tv['settings']          # ns -> {key: value}

def a11y():
    return S['secure'].get('enabled_accessibility_services', '')

def home_front():
    if 'tv.betterfiretv.home' in pk and pk['tv.betterfiretv.home']['installed'] and \
            'tv.betterfiretv.home/com.fireframe.home.HomeService' in a11y() and tv.get('ff_works', True):
        return 'tv.betterfiretv.home/com.fireframe.home.MainActivity'
    if 'com.fireframe.home' in pk and pk['com.fireframe.home']['installed'] and \
            'com.fireframe.home/com.fireframe.home.HomeService' in a11y() and tv.get('ff_works', True):
        return 'com.fireframe.home/.MainActivity'
    if 'tv.dumbtv.home' in pk and pk['tv.dumbtv.home']['installed'] and 'tv.dumbtv.home' in a11y():
        return 'tv.dumbtv.home/.Home'
    return 'com.amazon.tv.launcher/.ui.MainActivity'

def apk_pkg(path):
    n = Path(path).name.lower()
    for k, v in [('betterfiretv-home', 'tv.betterfiretv.home'), ('fireframe', 'com.fireframe.home'), ('smarttube', 'org.smarttube.stable'),
                 ('dnsfilter', 'dnsfilter.android'), ('dumbtv-home', 'tv.dumbtv.home')]:
        if k in n:
            return v
    return 'com.example.unknown'

def tvpath(p):
    assert p.startswith('/sdcard'), p
    return sd / p[len('/sdcard'):].lstrip('/')

def reboot():
    tv['boot_id'] += 1
    tv['front'] = home_front()
    # deaktivierte Pakete laufen nicht mehr
    save()

if args[:1] == ['install']:
    apk = args[-1]
    p = apk_pkg(apk)
    pk.setdefault(p, {'system': False, 'enabled': 1, 'installed': True, 'uid': 10900 + len(pk)})
    pk[p].update(installed=True, enabled=1)
    if p == 'tv.betterfiretv.home': pk[p]['vc'] = 101
    save(); out('Performing Streamed Install'); out('Success'); sys.exit(0)
if args[:1] == ['uninstall']:
    p = args[-1]
    if p in pk and pk[p]['installed'] and not pk[p]['system']:
        del pk[p]
        if p == 'dnsfilter.android':
            S['secure'].pop('always_on_vpn_app', None)
        S['secure']['enabled_accessibility_services'] = ':'.join(
            x for x in a11y().split(':') if x and not x.startswith(p + '/'))
        save(); out('Success'); sys.exit(0)
    out('Failure [DELETE_FAILED_INTERNAL_ERROR]'); sys.exit(1)
if args[:1] == ['reboot']:
    reboot(); sys.exit(0)
if args[:1] == ['exec-out']:
    sys.stdout.buffer.write(b'\x89PNG\r\n\x1a\nFAKE'); sys.exit(0)
if args[:1] == ['push']:
    src, dst = Path(args[1]), args[2]
    t = tvpath(dst)
    if src.is_dir():
        target = t / src.name if dst.endswith('/') else t
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(src, target)
    else:
        t.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, t if not dst.endswith('/') else t / src.name)
    out(f'{src}: 1 file pushed'); sys.exit(0)
if args[:1] == ['pull']:
    src, dst = tvpath(args[1]), Path(args[2])
    if not src.exists():
        out(f"adb: error: failed to stat remote object '{args[1]}'"); sys.exit(1)
    target = dst / src.name if dst.is_dir() else dst
    if src.is_dir():
        shutil.copytree(src, target, dirs_exist_ok=True)
    else:
        shutil.copy(src, target)
    out('1 file pulled'); sys.exit(0)
if args[:1] != ['shell']:
    sys.exit(91)

cmdline = ' '.join(args[1:])
with log.open('a') as f:
    f.write('  SHELL: ' + cmdline + '\n')
if tv.get('offline', 0) > 0:
    tv['offline'] -= 1; save()
    sys.stderr.write('error: closed\n'); sys.exit(1)

def run(cmd):
    try:
        w = shlex.split(cmd)
    except ValueError:
        w = cmd.split()
    w = [x for x in w if not x.startswith('2>')]
    if not w:
        return 0
    c = w[0]
    fos5 = tv.get('fos5', False)
    if fos5 and c == 'cmd':
        out('/system/bin/sh: cmd: not found'); return 127
    if fos5 and c == 'settings' and len(w) > 1 and w[1] in ('list', 'delete'):
        out('usage:  settings [--user NUM] get namespace key'); out('        settings [--user NUM] put namespace key value'); return 1
    if fos5 and c == 'pm' and len(w) > 1 and w[1] in ('disable-user', 'hide') :
        out('Error: java.lang.SecurityException: Permission Denial: attempt to change component state'); return 1
    if c == 'content':
        ns = w[w.index('--uri') + 1].rsplit('/', 1)[-1]
        if w[1] == 'query':
            for i, (k, v) in enumerate(sorted(S[ns].items())): out(f'Row: {i} name={k}, value={v if v != "" else "NULL"}')
            return 0
        if w[1] == 'delete':
            import re
            m = re.search(r"name='([^']*)'", ' '.join(w))
            if m: S[ns].pop(m.group(1), None); save()
            return 0
    if c == 'echo':
        out(' '.join(w[1:])); return 0
    if c == 'getprop':
        if len(w) == 1:
            for k, v in tv['props'].items(): out(f'[{k}]: [{v}]')
        else:
            out(tv['props'].get(w[1], ''))
        return 0
    if c == 'pm':
        sub = w[1]
        if sub == 'list' and w[2] == 'packages':
            flags = [x for x in w[3:] if x.startswith('-')]
            names = [x for x in w[3:] if not x.startswith('-')]
            for n, p in sorted(pk.items()):
                if not p['installed'] and '-u' not in flags: continue
                if '-e' in flags and p['enabled'] not in (0, 1): continue
                if '-d' in flags and p['enabled'] in (0, 1): continue
                if '-s' in flags and not p['system']: continue
                if '-3' in flags and p['system']: continue
                if names and n not in names: continue
                out('package:' + n)
            return 0
        if sub == 'path':
            n = w[2]
            if n in pk and pk[n]['installed']:
                out(f'package:/system/priv-app/{n}/{n}.apk'); return 0
            return 1
        if sub in ('disable-user', 'enable', 'uninstall', 'grant'):
            n = w[-1]
            if sub == 'grant': return 0
            if n not in pk or not pk[n]['installed']:
                out(f'Error: Unknown package: {n}'); return 1
            if sub == 'disable-user':
                if pk[n].get('protected'):
                    out('Exception occurred while executing:'); out(f'java.lang.SecurityException: Cannot disable a protected package: {n}'); return 255
                if pk[n]['enabled'] == 2:
                    out(f'Shell cannot change component state for {n} to 3'); return 255
                pk[n]['enabled'] = 3; save(); out(f'Package {n} new state: disabled-user'); return 0
            if sub == 'enable':
                pk[n]['enabled'] = 1; save(); out(f'Package {n} new state: enabled'); return 0
            if sub == 'uninstall':
                pk[n]['installed'] = False; save(); out('Success'); return 0
    if c == 'cmd' and w[1] == 'package':
        if w[2] == 'help':
            out('  install-existing [--user USER_ID] PACKAGE'); return 0
        if w[2] == 'install-existing':
            n = w[-1]
            if n in pk and pk[n]['system']:
                pk[n]['installed'] = True; save(); out(f'Package {n} installed for user: 0'); return 0
            out(f'Error: Package {n} doesn\'t exist'); return 1
    if c == 'cmd' and w[1] == 'netpolicy':
        np = tv['netpolicy']
        if w[2] == 'set' and w[3] == 'restrict-background':
            np['restrict'] = w[4] == 'true'; save(); return 0
        if w[2] == 'get' and w[3] == 'restrict-background':
            out('Restrict background status: ' + ('enabled' if np['restrict'] else 'disabled')); return 0
        if w[2] == 'list' and w[3] == 'restrict-background-blacklist':
            out('Restrict background blacklisted UIDs: ' + (' '.join(map(str, np['blacklist'])) or 'none')); return 0
        if w[2] == 'add' and w[3] == 'restrict-background-blacklist':
            u = int(w[4]); np['blacklist'] = sorted(set(np['blacklist']) | {u}); save(); return 0
        if w[2] == 'remove' and w[3] == 'restrict-background-blacklist':
            u = int(w[4]); np['blacklist'] = [x for x in np['blacklist'] if x != u]; save(); return 0
    if c == 'settings':
        i = 1
        if w[1] == '--user': i = 3
        verb, ns = w[i], w[i + 1]
        if verb == 'list':
            for k, v in sorted(S[ns].items()): out(f'{k}={v}')
            return 0
        if verb == 'get':
            out(S[ns].get(w[i + 2], 'null')); return 0
        if verb == 'put':
            if len(w) != i + 4:
                out('Bad arguments'); tv.setdefault('bad', []).append(cmd); save(); return 1
            S[ns][w[i + 2]] = w[i + 3]; save(); return 0
        if verb == 'delete':
            S[ns].pop(w[i + 2], None); save(); out('Deleted 1 rows'); return 0
    if c == 'appops':
        if w[1] == 'set':
            n, op, mode = w[2], w[3], w[4]
            tv['appops'].setdefault(n, {})[op] = mode
            if mode == 'default': tv['appops'][n].pop(op, None)
            save(); return 0
        if w[1] == 'get':
            ops = tv['appops'].get(w[2], {})
            if not ops: out('No operations.')
            for k, v in ops.items(): out(f'{k}: {v}')
            return 0
        if w[1] == 'write-settings': return 0
    if c == 'dumpsys':
        what = w[1] if len(w) > 1 else ''
        if what == 'package':
            n = w[2]
            if n in pk:
                p = pk[n]
                out(f'Packages:\n  Package [{n}]\n    userId={p.get("uid", 10500)}\n    versionCode={p.get("vc", 1)} minSdk=22\n'
                    f'    User 0: ceDataInode=1 installed={str(p["installed"]).lower()} hidden=false enabled={p["enabled"]} ')
            return 0
        if what == 'activity':
            out('ACTIVITY MANAGER ACTIVITIES')
            out(f'  ResumedActivity: ActivityRecord{{abc123 u0 {tv["front"]} t12}}'); return 0
        if what == 'deviceidle':
            if len(w) > 3 and w[3].startswith('+'):
                tv['deviceidle'].append(w[3][1:]); save(); out('Added: ' + w[3][1:])
            elif len(w) > 3 and w[3].startswith('-'):
                tv['deviceidle'] = [x for x in tv['deviceidle'] if x != w[3][1:]]; save(); out('Removed: ' + w[3][1:])
            else:
                for x in tv['deviceidle']: out('user,' + x + ',10001')
            return 0
        if what == 'accessibility':
            out('User state[attributes:{id=0, ...}'); return 0
        return 0
    if c == 'cat':
        if w[1] == '/proc/meminfo':
            free = 900 - 8 * sum(1 for p in pk.values() if p['installed'] and p['enabled'] in (0, 1))
            out(f'MemTotal:        1949000 kB\nMemAvailable:     {max(free, 50) * 1024} kB'); return 0
        if w[1] == '/proc/sys/kernel/random/boot_id':
            out(f'boot-{tv["boot_id"]}'); return 0
        try:
            sys.stdout.write(tvpath(w[1]).read_text()); return 0
        except Exception:
            return 1
    if c == 'svc' and w[1:3] == ['power', 'reboot']:
        reboot(); tv['offline'] = 1; save(); return 0
    if c == 'reboot':
        reboot(); return 0
    if c == 'input' and w[1] == 'keyevent':
        if w[2] in ('KEYCODE_HOME', '3'):
            tv['front'] = home_front(); save()
        return 0
    if c == 'am':
        if w[1] == 'start':
            comp = None
            for i, x in enumerate(w):
                if x == '-n': comp = w[i + 1]
            if comp is None:
                for x in w:
                    if '/' in x and not x.startswith('-'): comp = x
            if comp: tv['front'] = comp
            if comp and comp.startswith('tv.betterfiretv.home/'):
                h = tv.setdefault('home', {'dock': None, 'hidden': [], 'wallpaper': None, 'builtins': True})
                i = 0
                while i < len(w):
                    if w[i] in ('--es', '--ez') and i + 2 < len(w):
                        k, v = w[i + 1], w[i + 2]
                        if k == 'dock': h['dock'] = [x for x in v.split(',') if x]
                        if k == 'hide': h['hidden'] = [x for x in v.split(',') if x]
                        if k == 'wallpaper': h['wallpaper'] = v
                        if k == 'builtins': h['builtins'] = v == 'true'
                        i += 3; continue
                    i += 1
                launch = sorted(n for n, p in pk.items() if p['installed'] and p['enabled'] in (0, 1) and
                                (not p['system'] or n in ('com.amazon.firebat', 'com.amazon.firetv.youtube', 'com.amazon.tv.settings.v2'))
                                and n not in ('tv.betterfiretv.home', 'dnsfilter.android'))
                dock = h['dock'] if h['dock'] is not None else [x for x in launch if not pk[x]['system']][:6]
                dock = [x for x in dock if x in launch and x not in h['hidden']]
                h['dock_effective'] = dock
                lines = [f"{n}\t{n.split('.')[-1].capitalize()}\t{dock.index(n) + 1 if n in dock else '-'}\t{1 if n in h['hidden'] else 0}" for n in launch]
                f = sd / 'Android/media/tv.betterfiretv.home/apps.txt'
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text('\n'.join(lines) + '\n')
            save()
            return 0
        if w[1] == 'get-current-user':
            out('0'); return 0
        return 0
    if c == 'monkey':
        out('Events injected: 1'); return 0
    if c == 'ps':
        for n, p in pk.items():
            if p['installed'] and p['enabled'] in (0, 1) and p.get('runs'): out(n)
        return 0
    if c == 'ip':
        out('default via 192.168.178.1 dev wlan0 table 1021 proto static'); return 0
    if c == 'ping':
        host = w[-1]
        if S['secure'].get('always_on_vpn_app') == 'dnsfilter.android' and 'dnsfilter.android' in pk \
                and pk['dnsfilter.android']['installed'] and ('amazon' in host and 'youtube' not in host):
            out(f'PING {host} (127.0.0.1) 56(84) bytes of data.')
        else:
            out(f'PING {host} (93.184.216.34) 56(84) bytes of data.')
        return 0
    if c == 'test':
        # test -f|-d PATH
        p = w[2]
        if p.startswith('/sdcard'):
            t = tvpath(p)
            return 0 if (t.is_file() if w[1] == '-f' else t.is_dir()) else 1
        return 1
    if c == 'ls':
        p = w[-1]
        if p.startswith('/sdcard') and tvpath(p).is_dir():
            for x in sorted(os.listdir(tvpath(p))): out(x)
            return 0
        return 1
    if c == 'rm':
        for p in w[1:]:
            if p.startswith('/sdcard'):
                t = tvpath(p)
                if t.is_dir(): shutil.rmtree(t)
                elif t.exists(): t.unlink()
        return 0
    if c == 'mkdir':
        p = w[-1]
        if p.startswith('/sdcard'): tvpath(p).mkdir(parents=True, exist_ok=True)
        return 0
    if c in ('chmod', 'touch', 'sleep', 'logcat', 'device_config'):
        return 0
    if c == 'uname':
        out('4.19.0'); return 0
    if c == 'grep':
        return 0
    with unknown.open('a') as f:
        f.write(cmd + '\n')
    return 0

rc = 0
# Unterstützt "a && b" und "a; b" in einfacher Form
for part in cmdline.split(';'):
    chain = part.split('&&')
    for seg in chain:
        rc = run(seg.strip())
        if rc != 0:
            break
sys.exit(rc)
