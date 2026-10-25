#!/usr/bin/env python3
"""Exercise summary measurement through invented tokens and a local Responses server."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent
START, END = 1791817200, 1791903600


@contextlib.contextmanager
def responses_server(failed=False, status=200):
    requests = []

    class Endpoint(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append((self.path, self.headers.get('Authorization'), body))
            response = {'usage': {'input_tokens': 0 if failed else 12,
                                 'input_tokens_details': {'cached_tokens': 0 if failed else 3},
                                 'output_tokens': 0 if failed else 4},
                        'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': ''}]}]}
            if failed:
                response['error'] = {'code': 'invented_stream_failure'}
            event = {'type': 'response.failed' if failed else 'response.completed', 'response': response}
            if status != 200:
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}/v1/responses', requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class MeasurementBoundsTest(unittest.TestCase):
    @contextlib.contextmanager
    def fixture(self, empty=False):
        parent = Path(os.environ['ACTIVITYPROBE_TEST_ROOT']).resolve()
        self.assertTrue(parent.is_relative_to(Path('/tmp').resolve()))
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            folder = Path(directory)
            home = folder / 'person'
            home.mkdir()
            env = dict(os.environ, ACTIVITYPROBE_TEST_ROOT=str(folder),
                       ACTIVITYPROBE_DB=str(folder / 'isolated.sqlite'),
                       CFFIXED_USER_HOME=str(home), HOME=str(home), TMPDIR=str(folder), TZ='Asia/Seoul')
            source = folder / 'invented.sqlite'
            with contextlib.closing(sqlite3.connect(source)) as db, db:
                db.execute('PRAGMA user_version=1')
            bootstrap = self.probe(env, 'dry-run', source, START, END)
            self.assertEqual(bootstrap.returncode, 0, bootstrap.stderr)
            with contextlib.closing(sqlite3.connect(folder / 'converted.sqlite')) as db, db:
                db.executemany('INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) VALUES (?,"","Invented","","",1,0,0,0,0,0,0)',
                               [(START + second,) for second in range(0 if empty else 600)])
            yield folder, env

    def probe(self, env, *args):
        return subprocess.run([str(ROOT / '.build/debug/SummaryProbe'), *map(str, args)],
                              env=env, capture_output=True, text=True)

    def test_pending_call_is_not_previous_context(self):
        with self.fixture() as (folder, env):
            self.assertEqual(self.probe(env, 'tables', START, END).returncode, 0)
            with contextlib.closing(sqlite3.connect(folder / 'sample-1.sqlite')) as db, db:
                for a, b, name, pending in [(START - 120, START - 60, 'Invented completed context', 0),
                                           (START - 60, START, 'Invented pending context', 1)]:
                    db.execute('INSERT INTO model_calls(ts,start_ts,end_ts,model,input_tokens,cached_tokens,output_tokens,succeeded,pending) VALUES (?,?,?,"invented",0,0,0,1,?)', (b, a, b, pending))
                    db.execute('INSERT INTO intervals(start_ts,end_ts,name,description,kind,project,state) VALUES (?,?,?,"","work","","named")', (a, b, name))
            self.assertEqual(self.probe(env, 'tables', START, END).returncode, 0)
            rows = json.loads((folder / 'table-analysis.json').read_text())
            self.assertTrue(rows)
            self.assertIn('Invented completed context', rows[0]['context'])
            self.assertNotIn('Invented pending context', rows[0]['context'])

    def test_numeric_facts_and_billing_survive_deletion_except_overlap(self):
        with self.fixture() as (folder, env), responses_server() as (url, _), contextlib.ExitStack() as connections:
            measured = self.probe(env, 'measure', 1, START, END, '--responses-url', url)
            self.assertEqual(measured.returncode, 0, measured.stderr)
            database = folder / 'sample-1.sqlite'
            with contextlib.closing(sqlite3.connect(database)) as db, db:
                db.execute('INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) VALUES (?,"","Invented","","",1,0,0,0,0,0,0)', (START + 61,))
                before = db.execute('SELECT * FROM model_calls').fetchall()
                columns = [row[1] for row in db.execute('PRAGMA table_info(model_calls)')]
            self.assertEqual(len(before), 1)
            facts_index = columns.index('table_facts')
            facts = json.loads(before[0][facts_index])
            self.assertEqual(facts['through'], END)
            self.assertEqual(facts['sentRanges'][0]['start'], START)
            self.assertIn(START + 60, facts['activeMinutes'])
            self.assertEqual([before[0][columns.index(key)] for key in ('input_tokens', 'cached_tokens', 'output_tokens')], [12, 3, 4])
            # Keep the WAL sidecars available while the separate read-only preview opens.
            witness = connections.enter_context(contextlib.closing(sqlite3.connect(database)))
            witness.execute('SELECT count(*) FROM model_calls').fetchall()
            app_data = folder
            isolated = dict(env, ACTIVITYPROBE_DB=str(database))
            command = [str(ROOT / '.build/debug/ActivityProbe'), 'privacy', 'forget', str(START + 60), str(START + 120),
                       '--isolated-root', str(folder.parent), '--app-data', str(app_data)]
            preview = subprocess.run(command, env=isolated, capture_output=True, text=True)
            self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
            code = re.search(r'Confirmation code: ([a-f0-9]+)', preview.stdout)
            self.assertIsNotNone(code)
            deleted = subprocess.run([*command, '--confirm', code[1]], env=isolated, capture_output=True, text=True)
            self.assertEqual(deleted.returncode, 0, deleted.stdout + deleted.stderr)
            with contextlib.closing(sqlite3.connect(database)) as db, db:
                after = db.execute('SELECT * FROM model_calls').fetchall()
            self.assertEqual(len(after), 1)
            self.assertEqual(before[0][:facts_index] + before[0][facts_index + 1:],
                             after[0][:facts_index] + after[0][facts_index + 1:])
            expected = dict(facts)
            expected['sentRanges'] = [{'start': START, 'end': START + 60},
                                      {'start': START + 120, 'end': facts['sentRanges'][0]['end']}]
            expected['activeMinutes'] = [minute for minute in facts['activeMinutes'] if minute != START + 60]
            expected['restMinutes'] = [minute for minute in facts['restMinutes'] if minute != START + 60]
            self.assertEqual(json.loads(after[0][facts_index]), expected)

    def check_measurement(self, connected=True, empty=False, failed=False):
        with self.fixture(empty=empty) as (folder, env), responses_server(failed) as (url, requests):
            result = self.probe(env, 'measure', 1, START, END, '--responses-url', url,
                                *([] if connected else ['--signed-out']))
            if connected and not failed:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f'sample=1 calls={0 if empty else 1}', result.stdout)
                self.assertIn('account_kind=invented', result.stdout)
                with contextlib.closing(sqlite3.connect(folder / 'sample-1.sqlite')) as db, db:
                    self.assertEqual(db.execute("SELECT value FROM settings WHERE key='subscription.connected'").fetchone(), ('1',))
            else:
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('summary_unbilled_exec_failure' if failed else 'summary_not_connected', result.stdout)
                self.assertNotIn('sample=1 calls=', result.stdout)
            self.assertEqual(len(requests), 1 if connected and not empty else 0)
            for path, authorization, body in requests:
                self.assertEqual(path, '/v1/responses')
                self.assertEqual(authorization, 'Bearer invented-summary-token')
                self.assertEqual(body['model'], 'gpt-5.6-luna')
                self.assertEqual(body['reasoning'], {'effort': 'low'})
                self.assertFalse(body['store'])
                self.assertTrue(body['stream'])
                self.assertNotIn('tools', body)
            if (folder / 'summary-attempts.jsonl').exists():
                self.assertNotIn('invented-summary-token', (folder / 'summary-attempts.jsonl').read_text())

    def test_measurement_uses_responses_and_transactional_consent(self):
        self.check_measurement()

    def test_disconnected_measurement_is_not_a_result(self):
        self.check_measurement(connected=False)

    def test_empty_disconnected_measurement_is_not_a_result(self):
        self.check_measurement(connected=False, empty=True)

    def test_empty_connected_measurement_checks_token_without_request(self):
        self.check_measurement(empty=True)

    def test_unbilled_failure_is_not_a_measurement_result(self):
        self.check_measurement(failed=True)

    def test_paused_plan_is_not_a_measurement_result(self):
        with self.fixture() as (_, env), responses_server(status=429) as (url, requests):
            result = self.probe(env, 'measure', 1, START, END, '--responses-url', url)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn('summary_plan_paused', result.stdout)
            self.assertNotIn('sample=1 calls=', result.stdout)
            self.assertEqual(len(requests), 1)

    def test_account_selection_required_before_preparation(self):
        with self.fixture() as (folder, env):
            before = set(folder.iterdir())
            for mode in [('measure', 1, START, END), ('envelope',), ('invented',)]:
                result = self.probe(env, *mode)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout.strip(), 'measurement_account_required')
                self.assertEqual(set(folder.iterdir()), before)

    def test_remote_fake_endpoint_is_rejected_before_preparation(self):
        with self.fixture() as (folder, env):
            before = set(folder.iterdir())
            for url in ['https://example.invalid/v1/responses', 'http://localhost/v1/responses', 'http://invented@127.0.0.1/v1/responses']:
                result = self.probe(env, 'envelope', '--responses-url', url)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout.strip(), 'loopback_responses_url_required')
                self.assertEqual(set(folder.iterdir()), before)

    def test_product_account_opt_in_checks_bounds_before_access(self):
        with self.fixture() as (folder, env):
            before = set(folder.iterdir())
            result = self.probe(env, 'measure', 1, START + 14400, END + 14400, '--product-account')
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout.splitlines(), ['account_kind=app', 'measurement_requires_midnight_day_bounds'])
            self.assertEqual(set(folder.iterdir()), before)

    def test_midnight_day_is_accepted(self):
        with self.fixture() as (_, env):
            result = self.probe(env, 'dry-run', Path(env['ACTIVITYPROBE_TEST_ROOT']) / 'invented.sqlite', START, END)
            self.assertEqual(result.returncode, 0)
            self.assertIn('day samples=600 evidence=0', result.stdout)

    def test_isolated_four_am_default_is_refused(self):
        with self.fixture() as (_, env):
            result = self.probe(env, 'dry-run', '/unused', START + 14400, END + 14400)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout.strip(), 'measurement_requires_midnight_day_bounds')


if __name__ == '__main__':
    unittest.main()
