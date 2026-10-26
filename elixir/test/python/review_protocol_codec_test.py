import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[2] / 'priv/ticket_push_history_validator_v19.py'
spec = importlib.util.spec_from_file_location('review_history', path)
history = importlib.util.module_from_spec(spec)
spec.loader.exec_module(history)


class ReviewCodecTest(unittest.TestCase):
    def test_legacy_and_receipt_bound_finding_identities(self):
        worker = {'request_key': 'review-request', 'output_sha256': 'a' * 64}
        binding = {'expected_sha': 'b' * 40, 'schema': {'properties': {}, 'required': []}}
        output = {'findings': ['value-free logging ✓', 'value-free logging ✓']}
        legacy = history.review_finding_entries('contract', worker, binding, output, {})
        self.assertEqual(len(legacy), 1)
        expected = hashlib.sha256(json.dumps(['contract', output['findings'][0]], separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(legacy[0]['id'], expected)
        binding['schema']['properties']['review_report'] = {}
        binding['schema']['required'].append('review_report')
        output['review_report'] = {'candidate_sha': binding['expected_sha']}
        packet = {'review_protocol': {'version': 1}}
        structured = history.review_finding_entries('contract', worker, binding, output, packet)
        self.assertEqual(len(structured), 2)
        for index, finding in enumerate(structured):
            expected = hashlib.sha256(json.dumps(['contract', worker['request_key'], worker['output_sha256'], index], separators=(',', ':')).encode()).hexdigest()
            self.assertEqual(finding['id'], expected)
        with self.assertRaises((ValueError, KeyError)):
            history.review_finding_entries('contract', worker, binding, output, {})
        del output['review_report']
        with self.assertRaises(ValueError):
            history.review_finding_entries('contract', worker, binding, output, packet)

    def test_single_repair_budget_and_each_binding_mutation(self):
        prior = {'code_repair_round': 11, 'verifier_round': 4, 'implementation_iteration': 24}
        input = {key: key for key in 'run_id candidate_sha spec_revision contract_sha256 verifier_request_key verifier_output_sha256 authorization_reference'.split()}
        entry = dict(input, kind='ONE_VERIFIER_REPAIR', verifier_round=4, prior_code_repair_round=11, next_code_repair_round=12, configured_limit=10)
        auth = {'version': 2, 'budget_exception': entry, 'configured_limits': {'maximum_implementation_iterations': 25, 'maximum_code_repair_rounds': 10}, 'limits': {'maximum_implementation_iterations': 25, 'maximum_code_repair_rounds': 12}}
        history.validate_operator_budget(auth, input, prior)
        for key, value in entry.items():
            wrong = copy.deepcopy(auth)
            wrong['budget_exception'][key] = value + 1 if type(value) is int else value + '-wrong'
            with self.subTest(key=key), self.assertRaises(ValueError):
                history.validate_operator_budget(wrong, input, prior)
        for key in ('budget_exception', 'configured_limits'):
            wrong = copy.deepcopy(auth)
            del wrong[key]
            with self.assertRaises(ValueError):
                history.validate_operator_budget(wrong, input, prior)
        wrong = copy.deepcopy(auth)
        wrong['limits']['maximum_code_repair_rounds'] = 13
        with self.assertRaises(ValueError):
            history.validate_operator_budget(wrong, input, prior)
        wrong = copy.deepcopy(auth)
        wrong['version'] = 1
        with self.assertRaises(ValueError):
            history.validate_operator_budget(wrong, input, prior)


if __name__ == '__main__':
    unittest.main()
