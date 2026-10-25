#!/usr/bin/env python3
"""Verify the direct Responses envelope without a CLI, login or real model."""
import json
import unittest
import test_summary_probe as probe_tests


class SummaryEnvelopeTest(unittest.TestCase):
    fixture = probe_tests.MeasurementBoundsTest.fixture
    probe = probe_tests.MeasurementBoundsTest.probe
    def test_envelope_has_only_fixed_request_fields_and_content_free_accounting(self):
        with self.fixture() as (folder, env), probe_tests.responses_server() as (url, requests):
            result = self.probe(env, 'envelope', '--responses-url', url)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('envelope_input=12 prompt_estimate=3 cached=3 output=4', result.stdout)
            self.assertEqual(len(requests), 1)
            _, authorization, body = requests[0]
            self.assertEqual(authorization, 'Bearer invented-summary-token')
            self.assertEqual(body, {'model': 'gpt-5.6-luna', 'reasoning': {'effort': 'low'},
                                    'input': [{'role': 'user', 'content': 'Invented.'}],
                                    'store': False, 'stream': True})
            record = json.loads((folder / 'summary-attempts.jsonl').read_text())
            self.assertEqual(record['transport'], 'responses')
            self.assertEqual(record['fixedEnvelopeTokens'], 64)
            self.assertNotIn('Invented.', json.dumps(record))
            self.assertNotIn('invented-summary-token', json.dumps(record))


if __name__ == '__main__':
    unittest.main()
