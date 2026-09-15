#!/usr/bin/env python3
"""One screen, no scrolling: the whole panel fits the display it opens on.
Run inside the dedicated Test Drive guest, at each display size that matters."""
import json
import subprocess
import time

def call(*args):
    return subprocess.check_output(['omarchy-shell', 'jankeesvw.tesla.test', *args], text=True).strip()

subprocess.run(['omarchy-shell', 'jankeesvw.tesla', 'open'], check=True)
for _ in range(50):
    status = json.loads(call('status'))
    if status['opened']: break
    time.sleep(0.1)
else: raise AssertionError('the panel never opened: %r' % (status,))
time.sleep(0.6)
status = json.loads(call('status'))
assert status['fields'] >= 40, 'every field the car reports must be on the panel: %r' % (status,)
assert status['fits'], 'the panel must fit the screen top to bottom, never scroll: %r' % (status,)
assert status['fitsWidth'], 'the four columns must fit the screen side by side: %r' % (status,)
subprocess.run(['wtype', '-k', 'Escape'], check=True)
time.sleep(0.4)
assert json.loads(call('status'))['opened'] is False, 'Escape must close the panel'
print(json.dumps(status, indent=2))
