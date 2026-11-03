#!/usr/bin/env python3
"""Vergleicht zwei Zustände des simulierten Sticks: Pakete, Einstellungen, Netzwerkregeln, App-Ops."""
import json,sys
a=json.load(open(sys.argv[1]))['tv']; b=json.load(open(sys.argv[2]))['tv']
pa,pb=a['packages'],b['packages']; n_diff=0
for n in sorted(set(pa)|set(pb)):
    x,y=pa.get(n),pb.get(n)
    if x is None: print('NEU    ',n); n_diff+=1; continue
    if y is None: print('FEHLT  ',n); n_diff+=1; continue
    if (x['enabled'] in (0,1))!=(y['enabled'] in (0,1)) or x['installed']!=y['installed']: print('DIFF   ',n,x['enabled'],'->',y['enabled']); n_diff+=1
for ns in ('global','secure','system'):
    sa,sb=a['settings'][ns],b['settings'][ns]
    for k in sorted(set(sa)|set(sb)):
        if sa.get(k)!=sb.get(k): print('SETTING',ns,k,repr(sa.get(k)),'->',repr(sb.get(k))); n_diff+=1
if a['netpolicy']!=b['netpolicy']: print('NETPOLICY',a['netpolicy'],b['netpolicy']); n_diff+=1
if sorted(a['deviceidle'])!=sorted(b['deviceidle']): print('DEVICEIDLE',b['deviceidle']); n_diff+=1
bad={k:v for k,v in b['appops'].items() if any(m in('ignore','deny') for m in v.values()) and k in pb}
if bad: print('APPOPS',bad); n_diff+=1
print('Unterschiede:',n_diff)
