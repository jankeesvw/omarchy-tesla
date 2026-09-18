#!/usr/bin/env python3
"""Local-only tariff notebook. No Tesla, maps, geocoding or other network calls."""
import datetime
import fcntl
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import uuid


def load(path):
    if not path.exists():
        return {'version': 1, 'locations': []}
    return json.loads(path.read_text())


def save(path, entry):
    name = entry.get('name')
    address = entry.get('address', '')
    currency = entry.get('currency', 'USD')
    # Blank means dollars, and lower case is not a different currency.
    if isinstance(currency, str):
        currency = currency.strip().upper() or 'USD'
    if not isinstance(name, str) or not name.strip() or len(name) > 120:
        raise ValueError('invalid name')
    if not isinstance(address, str) or len(address) > 500:
        raise ValueError('invalid address')
    if not isinstance(currency, str) or len(currency) != 3 or not currency.isascii() or not currency.isalpha() or currency != currency.upper():
        raise ValueError('invalid currency')
    raw_price = entry.get('price')
    if isinstance(raw_price, bool):
        raise ValueError('invalid price')
    try:
        price = float(raw_price) if raw_price not in (None, '') else None
    except (TypeError, ValueError):
        # float()'s own message would echo what was typed; ours does not.
        raise ValueError('invalid price')
    if price is not None and (not math.isfinite(price) or price < 0):
        raise ValueError('invalid price')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    with open(path.parent / '.locations.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = load(path)
        ident = entry.get('id') or str(uuid.uuid4())
        current = next((item for item in data['locations'] if item['id'] == ident), None)
        if entry.get('id') and current is None:
            raise ValueError('unknown location')
        if current is None:
            current = {'id': ident, 'tariffs': []}
            data['locations'].append(current)
        current.update(name=name.strip(), address=address)
        tariff = {'price': price, 'currency': currency,
                  'effective_from': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        current['tariffs'].append(tariff)
        fd, temporary = tempfile.mkstemp(prefix='.locations-', dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(data, out, indent=2)
                out.write('\n')
                out.flush()
                os.fsync(out.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return data


if __name__ == '__main__':
    path = Path(os.environ.get('OMARCHY_TESLA_CONFIG_DIR', str(Path.home() / '.config/omarchy-tesla'))) / 'locations.json'
    try:
        result = save(path, json.loads(sys.stdin.readline())) if sys.argv[1:] == ['save'] else load(path)
        print(json.dumps({'ok': True, 'data': result}))
    except ValueError as error:
        # Our own validation messages name the field and nothing else.
        print(json.dumps({'ok': False, 'error': str(error) if str(error).startswith(('invalid ', 'unknown ')) else 'invalid entry'}))
    except Exception:
        # Never echo private entry contents or filesystem paths on errors.
        print(json.dumps({'ok': False, 'error': 'Location could not be saved/read. Check fields and private storage.'}))
