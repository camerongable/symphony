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
    def test_focused_writer_readiness_is_not_physical_verifier_acceptance(self):
        codec_spec = importlib.util.spec_from_file_location('writer_readiness', path.with_name('ticket_push_history_validator_v22.py'))
        codec = importlib.util.module_from_spec(codec_spec)
        codec_spec.loader.exec_module(codec)
        origin = {'request_key': 'prior', 'output_sha256': 'digest', 'candidate_sha': 'old', 'criteria': [{'id': 'AC-1', 'status': 'PASS', 'evidence': ['prior verified behavior']}]}
        packet = {'role': 'feature-writer', 'review_protocol': {'version': 2, 'criterion_ids': ['AC-1'], 'finding_obligations': [], 'review_scope': {'mode': 'FOCUSED', 'criterion_ids': ['AC-1'], 'carried_evidence': [origin]}}}
        binding = {'expected_sha': 'candidate', 'schema': {'type': 'object', 'properties': {'review_report': {'type': 'object'}}}}
        output = {'status': 'COMPLETE', 'blockers': [], 'review_report': {'version': 2, 'candidate_sha': 'candidate', 'block_reason': 'NONE', 'criteria': [{'id': 'AC-1', 'status': 'NOT_CHECKED', 'evidence': ['No new test run']}], 'closures': [], 'boundary_sweeps': [{'id': 'AC-1', 'status': 'UNAVAILABLE', 'evidence': ['Historical verification only'], 'paths': []}], 'affected_path_checks': [{'id': 'source implementation', 'status': 'CHECKED', 'evidence': ['handler.go:42']}], 'findings': []}}
        codec.validate_report(packet, binding, output)

        def replace(target, keys, value):
            for key in keys[:-1]:
                target = target[key]
            target[keys[-1]] = value

        mutations = [
            ('duplicate supplemental ID', 'output', ['review_report', 'affected_path_checks'], output['review_report']['affected_path_checks'] * 2),
            ('blank supplemental ID', 'output', ['review_report', 'affected_path_checks', 0, 'id'], ' '),
            ('empty supplemental evidence', 'output', ['review_report', 'affected_path_checks', 0, 'evidence'], []),
            ('unavailable supplemental check', 'output', ['review_report', 'affected_path_checks', 0, 'status'], 'UNAVAILABLE'),
            ('uninspected PASS', 'output', ['review_report', 'criteria', 0, 'status'], 'PASS'),
            ('failed implementation', 'output', ['review_report', 'criteria', 0, 'status'], 'FAIL'),
            ('checked without path', 'output', ['review_report', 'boundary_sweeps', 0, 'status'], 'CHECKED'),
            ('blank path', 'output', ['review_report', 'boundary_sweeps', 0, 'paths'], [' ']),
            ('missing boundary evidence', 'output', ['review_report', 'boundary_sweeps', 0, 'evidence'], []),
            ('stale candidate', 'output', ['review_report', 'candidate_sha'], 'stale'),
            ('comprehensive scope', 'packet', ['review_protocol', 'review_scope', 'mode'], 'COMPREHENSIVE'),
            ('no historical evidence', 'packet', ['review_protocol', 'review_scope', 'carried_evidence'], []),
            ('failed prior', 'packet', ['review_protocol', 'review_scope', 'carried_evidence', 0, 'criteria', 0, 'status'], 'FAIL'),
            ('unchecked prior', 'packet', ['review_protocol', 'review_scope', 'carried_evidence', 0, 'criteria', 0, 'status'], 'NOT_CHECKED'),
            ('missing prior evidence', 'packet', ['review_protocol', 'review_scope', 'carried_evidence', 0, 'criteria', 0, 'evidence'], []),
            ('missing prior criterion', 'packet', ['review_protocol', 'review_scope', 'carried_evidence', 0, 'criteria'], []),
            ('explicit empty paths', 'packet', ['review_protocol', 'review_scope', 'affected_paths'], []),
            ('missing bound path', 'packet', ['review_protocol', 'review_scope', 'affected_paths'], ['handler.go']),
            ('later failed prior', 'packet', ['review_protocol', 'review_scope', 'carried_evidence'], [origin, dict(origin, criteria=[dict(origin['criteria'][0], status='FAIL')])]),
        ]
        mutations += [('missing origin ' + key, 'packet', ['review_protocol', 'review_scope', 'carried_evidence', 0, key], '') for key in ('request_key', 'output_sha256', 'candidate_sha')]
        for name, target, keys, value in mutations:
            changed = {'packet': copy.deepcopy(packet), 'output': copy.deepcopy(output)}
            replace(changed[target], keys, value)
            with self.subTest(name=name), self.assertRaises((ValueError, KeyError)):
                codec.validate_report(changed['packet'], binding, changed['output'])

        verifier = dict(packet, role='change-verifier')
        checked = copy.deepcopy(output)
        checked.update(status='PASS', candidate_sha='candidate')
        with self.assertRaises(ValueError):
            codec.validate_report(verifier, binding, checked)
        checked['review_report']['affected_path_checks'] = []
        with self.assertRaises(ValueError):
            codec.validate_report(verifier, binding, checked)
        checked['review_report']['criteria'][0]['status'] = 'PASS'
        checked['review_report']['boundary_sweeps'][0].update(status='CHECKED', paths=['handler.go'])
        codec.validate_report(verifier, binding, checked)
        finding = {'id': 'F-1', 'description': 'Writer privacy observation', 'classification': 'NEW', 'disposition': 'REQUIRED_REPAIR', 'basis': {'kind': 'SAFETY_INVARIANT', 'reference': 'PRIVACY'}}
        checked['review_report']['findings'] = [finding]
        with self.assertRaises(ValueError):
            codec.validate_report(verifier, binding, checked)
        checked.update(status='COMPLETE', blockers=[])
        codec.validate_report(packet, binding, checked)
        predecessor_spec = importlib.util.spec_from_file_location('predecessor', path.with_name('ticket_push_history_validator_v21.py'))
        predecessor = importlib.util.module_from_spec(predecessor_spec)
        predecessor_spec.loader.exec_module(predecessor)
        predecessor.validate_report(packet, binding, checked)
        legacy_packet = copy.deepcopy(packet)
        legacy_packet['review_protocol'].update(version=1, repairs_used=0)
        legacy_output = copy.deepcopy(checked)
        legacy_output['review_report'].update(version=1, finding_classifications=[])
        del legacy_output['review_report']['findings']
        legacy_output['findings'] = []
        codec.validate_report(legacy_packet, binding, legacy_output)
        predecessor.validate_report(legacy_packet, binding, legacy_output)

    def test_successor_physical_helpers_pin_new_history_and_retain_old_programs(self):
        codec_spec = importlib.util.spec_from_file_location('writer_programs', path.with_name('ticket_push_history_validator_v22.py'))
        codec = importlib.util.module_from_spec(codec_spec)
        codec_spec.loader.exec_module(codec)
        local = path.parent
        for version, history_version in ((27, 21), (28, 21), (29, 22), (30, 22)):
            helper = local / f'ticket_push_executor_v{version}.py'
            validator = local / f'ticket_push_history_validator_v{history_version}.py'
            execution = {'helper_path': str(helper), 'helper_sha256': hashlib.sha256(helper.read_bytes()).hexdigest(), 'history_program_sha256': hashlib.sha256(validator.read_bytes()).hexdigest()}
            with self.subTest(version=version):
                self.assertTrue(codec.large_push(execution))
                codec.push_program_origin(execution, local)
                for field in ('helper_sha256', 'history_program_sha256'):
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        codec.push_program_origin(dict(execution, **{field: '0' * 64}), local)

    def test_typed_physical_codec_projects_required_findings_once_and_preserves_v1(self):
        typed_path = path.with_name('ticket_push_history_validator_v21.py')
        typed_spec = importlib.util.spec_from_file_location('typed_review_history', typed_path)
        typed = importlib.util.module_from_spec(typed_spec)
        typed_spec.loader.exec_module(typed)
        worker = {'request_key': 'review-request', 'output_sha256': 'a' * 64}
        binding = {'expected_sha': 'b' * 40, 'schema': {'properties': {'review_report': {}}, 'required': ['review_report']}}
        finding = {'id': 'F-1', 'description': 'Privacy defect', 'classification': 'NEW', 'disposition': 'REQUIRED_REPAIR', 'basis': {'kind': 'SAFETY_INVARIANT', 'reference': 'PRIVACY'}}
        observation = dict(finding, id='OBS-1', description='Readability preference', disposition='OBSERVATION', basis={'kind': 'PREFERENCE', 'reference': 'Readability'})
        output = {'status': 'REPAIR', 'candidate_sha': binding['expected_sha'], 'review_report': {'version': 2, 'candidate_sha': binding['expected_sha'], 'findings': [observation, finding]}}
        packet = {'review_protocol': {'version': 2, 'criterion_ids': ['AC-1'], 'finding_obligations': []}}
        self.assertEqual(typed.review_finding_entries('contract', worker, binding, output, packet), [{'id': 'F-1', 'finding': 'Privacy defect'}])
        self.assertEqual(typed.required_findings(output), ['Privacy defect'])
        with self.assertRaises((ValueError, KeyError)):
            history.review_finding_entries('contract', worker, binding, output, packet)
        for mutation in [dict(finding, id=''), dict(finding, disposition='OBSERVATION'), dict(finding, basis={'kind': 'ACCEPTANCE_CRITERION', 'reference': 'AC-stale'})]:
            invalid = copy.deepcopy(output)
            invalid['review_report']['findings'] = [mutation]
            with self.assertRaises(ValueError):
                typed.review_finding_entries('contract', worker, binding, invalid, packet)

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
