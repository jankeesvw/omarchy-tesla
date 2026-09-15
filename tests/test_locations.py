import importlib.util
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parents[1] / 'bin' / 'locations.py'

class LocationsTests(unittest.TestCase):
    def load_module(self):
        self.assertTrue(SCRIPT.exists(), 'private locations store is not implemented')
        spec = importlib.util.spec_from_file_location('locations', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_explicit_zero_persists_privately_and_retains_tariff_history(self):
        m = self.load_module()
        with tempfile.TemporaryDirectory() as tmp:
            p = pathlib.Path(tmp) / 'private' / 'locations.json'
            first = m.save(p, {'name':'Fixture Home','address':'Synthetic address','price':'0','currency':'USD'})
            self.assertEqual(first['locations'][0]['tariffs'][0]['price'], 0)
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertEqual(p.parent.stat().st_mode & 0o777, 0o700)
            second = m.save(p, {'id':first['locations'][0]['id'], 'name':'Fixture Home','address':'Synthetic address','price':'0.25','currency':'USD'})
            self.assertEqual(len(second['locations']), 1)
            self.assertEqual(len(second['locations'][0]['tariffs']), 2)
            self.assertEqual(m.load(p), second)

    def test_cli_saves_one_line_without_waiting_for_parent_to_close_stdin(self):
        import json, os, subprocess, sys
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, OMARCHY_TESLA_CONFIG_DIR=tmp)
            proc = subprocess.Popen([sys.executable, str(SCRIPT), 'save'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
            try:
                proc.stdin.write(json.dumps({'name':'Fixture', 'price':0, 'currency':'USD'}) + '\n')
                proc.stdin.flush()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.fail('CLI waited for EOF instead of saving the complete JSON line')
                self.assertTrue(json.loads(proc.stdout.read())['ok'])
            finally:
                if proc.poll() is None: proc.kill()
                proc.communicate()

    def test_blank_or_lowercase_currency_is_dollars_or_upper_case(self):
        m = self.load_module()
        with tempfile.TemporaryDirectory() as tmp:
            p = pathlib.Path(tmp) / 'locations.json'
            data = m.save(p, {'name':'Home', 'price':'0', 'currency':''})
            self.assertEqual(data['locations'][0]['tariffs'][0]['currency'], 'USD')
            data = m.save(p, {'name':'Work', 'price':'0.2', 'currency':' eur '})
            self.assertEqual(data['locations'][1]['tariffs'][0]['currency'], 'EUR')

    def test_cli_error_names_the_field_and_never_echoes_the_value(self):
        import json, os, subprocess, sys
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, OMARCHY_TESLA_CONFIG_DIR=tmp)
            out = subprocess.run([sys.executable, str(SCRIPT), 'save'], input=json.dumps({'name':'X', 'price':'garbage-secret', 'currency':'USD'}),
                                 capture_output=True, text=True, env=env).stdout
            self.assertEqual(json.loads(out), {'ok': False, 'error': 'invalid price'})
            self.assertNotIn('garbage-secret', out)

    def test_unknown_is_not_free_and_invalid_prices_never_change_store(self):
        m = self.load_module()
        with tempfile.TemporaryDirectory() as tmp:
            p = pathlib.Path(tmp) / 'locations.json'
            data = m.save(p, {'name':'Public charger', 'price':'', 'currency':'USD'})
            self.assertIsNone(data['locations'][0]['tariffs'][0]['price'])
            before = p.read_bytes()
            for price in ['-1', 'NaN', 'Infinity', 'garbage', True]:
                with self.assertRaises(ValueError):
                    m.save(p, {'name':'Invalid', 'price':price, 'currency':'USD'})
                self.assertEqual(p.read_bytes(), before)
            for name in ['', '   ', 'x'*121]:
                with self.assertRaises(ValueError):
                    m.save(p, {'name':name, 'price':'0', 'currency':'USD'})
            with self.assertRaises(ValueError):
                m.save(p, {'name':'X', 'price':0, 'currency':'<img>'})
            with self.assertRaises(ValueError):
                m.save(p, {'id':'not-present', 'name':'X', 'price':0, 'currency':'USD'})

if __name__ == '__main__': unittest.main()
