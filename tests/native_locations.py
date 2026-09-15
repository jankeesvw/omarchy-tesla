#!/usr/bin/env python3
"""Exercise the real local editor using compositor-delivered keyboard input."""
import json
import pathlib
import subprocess
import time

root = pathlib.Path.home() / '.config/omarchy-tesla'
assert json.loads((root / 'fixture.json').read_text())['fixture'] is True, 'VM fixture required'
p = root / 'locations.json'
before = len(json.loads(p.read_text())['locations']) if p.exists() else 0
subprocess.run(['omarchy-shell','jankeesvw.tesla.test','dashboardTab','3'],check=True)
def keys(*args):
    subprocess.run(['wtype', *args], check=True)
keys('-M','alt','-k','n','-m','alt')
keys('Keyboard fixture')
keys('-k','Tab')
keys('Synthetic address')
keys('-M','alt','-k','Return','-m','alt')
keys('0')
keys('-M','alt','-k','s','-m','alt')
for _ in range(30):
    if p.exists():
        data = json.loads(p.read_text())
        if len(data['locations']) == before + 1: break
    time.sleep(0.1)
else: raise AssertionError('Native location editor did not persist a keyboard-entered location')
assert data['locations'][-1]['name'] == 'Keyboard fixture'
assert data['locations'][-1]['tariffs'][-1]['price'] == 0
assert p.stat().st_mode % 512 == 0o600
print('PASS: keyboard local save, zero tariff, exact readback, mode 0600')
