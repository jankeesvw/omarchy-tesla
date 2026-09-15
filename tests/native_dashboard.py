#!/usr/bin/env python3
"""Native integration assertions. Run only in the dedicated fixture VM."""
import json
import subprocess

def call(*args):
    return subprocess.check_output(['omarchy-shell', 'jankeesvw.tesla.test', *args], text=True).strip()

initial = json.loads(call('dashboardStatus'))
assert initial['page'] >= 0, 'Initial page must never be negative during QML binding initialization'
results = []
for tab in range(8):
    call('dashboardTab', str(tab))
    status = json.loads(call('dashboardStatus'))
    assert status['opened'] and status['fits'], status
    assert status.get('contentFits') is True, 'Must measure the actual visible content, not just viewport bounds'
    assert status['distanceShare'] is None and status['timeShare'] is None
    results.append(status)
call('dashboardTab', '6')
subprocess.run(['wtype', '-k', 'Next'], check=True)
keyboard = json.loads(call('dashboardStatus'))
assert keyboard['page'] == 1, 'PageDown must reach the native popup'
subprocess.run(['wtype', '-M', 'ctrl', '-k', 'Right', '-m', 'ctrl'], check=True)
keyboard = json.loads(call('dashboardStatus'))
assert keyboard['section'] == 'Map', 'Ctrl+Right must navigate native sections'
assert keyboard['view'] == 'data'
call('cockpit')
assert json.loads(call('dashboardStatus'))['view'] == 'cockpit', "the cockpit is the panel's other view"
print(json.dumps(results, indent=2))
