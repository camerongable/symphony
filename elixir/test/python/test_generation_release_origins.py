import copy
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import tempfile
import unittest

PRIV = pathlib.Path(__file__).resolve().parents[2] / 'priv'


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


class GenerationReleaseOrigins(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='generation-release-boundary-')
        self.root = pathlib.Path(self.directory.name).resolve()
        self.old = self.root / 'sealed-a'
        self.new = self.root / 'sealed-b' / 'dev/lib/symphony_elixir/priv'
        self.old_priv = self.old / 'dev/lib/symphony_elixir/priv'
        for target in (self.new, self.old_priv):
            target.mkdir(parents=True)
            for name in ('controller_generation_executor_v2.py', 'controller_generation_executor_v3.py', 'worker_file_companion.py'):
                shutil.copyfile(PRIV / name, target / name)
        shutil.copyfile(PRIV / 'ticket_push_history_validator_v10.py', self.new / 'ticket_push_history_validator_v10.py')
        spec = importlib.util.spec_from_file_location('new_history', self.new / 'ticket_push_history_validator_v10.py')
        self.reader = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.reader)
        artifact = {'lib/symphony_elixir/priv/' + p.name: {'sha256': digest(p.read_bytes())} for p in self.old_priv.iterdir()}
        self.manifest = self.old / 'evidence/release-manifest.json'
        self.manifest.parent.mkdir()
        self.manifest.write_text(json.dumps({'release': str(self.old), 'artifact': artifact, 'kind': 'TEST_SEALED_RELEASE_V1'}))
        entries = []
        for version in (2, 3):
            helper = self.old_priv / ('controller_generation_executor_v%d.py' % version)
            companion = self.old_priv / 'worker_file_companion.py'
            entries.append({'kind': 'RELEASE_GENERATION_ARTIFACT_V1', 'manifest_path': str(self.manifest),
                            'manifest_sha256': digest(self.manifest.read_bytes()), 'release_root': str(self.old),
                            'manifest_kind': 'TEST_SEALED_RELEASE_V1', 'helper_path': str(helper),
                            'helper_sha256': digest(helper.read_bytes()), 'companion_path': str(companion),
                            'companion_sha256': digest(companion.read_bytes())})
        raw = json.dumps({'version': 1, 'entries': entries}).encode()
        (self.new / 'ticket_generation_origins_v1.json').write_bytes(raw)
        self.reader.GENERATION_ORIGINS_SHA = digest(raw)
        self.run = {'run_id': 'run', 'worktree': str(self.root / 'source')}

    def tearDown(self):
        self.directory.cleanup()

    def session(self, version, directory=None):
        helper = (directory or self.old_priv) / ('controller_generation_executor_v%d.py' % version)
        prepared = {'intent_key': 'intent', 'intent_sha256': 'a' * 64, 'request_key': 'request', 'run_id': 'run',
                    'started_type': 'EXECUTION_STARTED', 'toolset': {}, 'operation': 'GAZELLE_DIFF',
                    'helper_path': str(helper), 'helper_sha256': digest(helper.read_bytes()),
                    'companion_path': str(helper.parent / 'worker_file_companion.py'),
                    'companion_sha256': digest((helper.parent / 'worker_file_companion.py').read_bytes()),
                    'root': self.run['worktree'], 'invocation': 'b' * 64}
        if version == 3:
            prepared['generation_version'] = 3
        raw = json.dumps(prepared)
        receipt = {'version': 1, 'helper_pid': 123, 'binding_json': raw}
        values = {('EXECUTION_PREPARED', ''): prepared,
                  ('EXECUTION_STARTED', ''): {'helper_pid': 123, 'binding_json': raw}}
        intent = {'intent_key': 'intent', 'binding_sha256': 'a' * 64, 'request_key': 'request', 'operation': 'GAZELLE_DIFF'}
        return intent, values, receipt

    def validate(self, version, session=None):
        intent, values, receipt = session or self.session(version)
        self.reader.generation_session(intent, values, '', receipt, self.run, self.new, {}, version == 3)

    def test_generated_only_sealed_a_journal_is_readable_in_sealed_b(self):
        self.validate(3)

    def test_ordinary_sealed_a_journal_is_readable_in_sealed_b(self):
        self.validate(2)

    def test_current_artifact_paths_remain_accepted(self):
        for version in (2, 3):
            self.validate(version, self.session(version, self.new))

    def test_ordinary_and_generated_apply_journals_cross_the_same_release_boundary(self):
        for version in (2, 3):
            intent, values, receipt = self.session(version)
            prepared = values[('EXECUTION_PREPARED', '')]
            prepared['started_type'] = 'APPLY_STARTED'
            raw = json.dumps(prepared)
            receipt['binding_json'] = raw
            values = {('APPLY_PREPARED', 'pkg/BUILD'): prepared,
                      ('APPLY_STARTED', 'pkg/BUILD'): {'helper_pid': 123, 'binding_json': raw}}
            self.reader.generation_session(intent, values, 'pkg/BUILD', receipt, self.run, self.new, {}, version == 3)

    def test_unregistered_same_bytes_path_is_not_an_origin(self):
        third = self.root / 'third'
        shutil.copytree(self.old_priv, third)
        with self.assertRaises(ValueError):
            self.validate(3, self.session(3, third))

    def test_manifest_byte_change_refuses(self):
        self.manifest.write_bytes(self.manifest.read_bytes() + b' ')
        with self.assertRaises(ValueError):
            self.validate(3)

    def test_manifest_wrong_canonical_location_refuses(self):
        self.manifest.rename(self.manifest.with_suffix('.retained'))
        self.manifest.symlink_to(self.manifest.with_suffix('.retained'))
        with self.assertRaises((ValueError, OSError)):
            self.validate(2)

    def test_helper_byte_change_refuses(self):
        session = self.session(3)
        path = self.old_priv / 'controller_generation_executor_v3.py'
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaises(ValueError):
            self.validate(3, session)

    def test_companion_byte_change_refuses(self):
        session = self.session(2)
        path = self.old_priv / 'worker_file_companion.py'
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaises(ValueError):
            self.validate(2, session)

    def test_session_receipt_tamper_still_refuses(self):
        session = self.session(3)
        session[2]['binding_json'] += ' '
        with self.assertRaises(ValueError):
            self.validate(3, session)

    def test_catalog_bytes_are_not_caller_authority(self):
        path = self.new / 'ticket_generation_origins_v1.json'
        path.write_bytes(path.read_bytes() + b' ')
        with self.assertRaises(ValueError):
            self.validate(3)

    def test_first_cold_read_does_not_reject_its_own_atime_update(self):
        path = self.root / 'cold-file'
        path.write_bytes(b'never read')
        os.utime(path, ns=(1, 1))
        self.assertEqual(self.reader.generation_regular(str(path), 64), b'never read')

    def test_file_identity_still_binds_content_metadata(self):
        path = self.root / 'identity-file'
        path.write_bytes(b'a')
        before = self.reader.generation_file_identity(path.stat())
        path.write_bytes(b'changed')
        self.assertNotEqual(before, self.reader.generation_file_identity(path.stat()))


if __name__ == '__main__':
    unittest.main()
