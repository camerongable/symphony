"""Fail-closed preparation checks; never controls launchd or opens the live ledger."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class PreparationTests(unittest.TestCase):
    def test_stale_commit_is_rejected_before_evidence_is_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'evidence'
            completed = subprocess.run(
                ['python3', str(ROOT / 'build_review_release.py'),
                 '--worktree', str(ROOT.parents[1]), '--commit', 'not-current-head',
                 '--name', 'symphony-review-report-test', '--evidence', str(target)],
                capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn('AssertionError', completed.stderr)
            self.assertFalse(target.exists())

    def test_release_name_cannot_escape_the_release_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'evidence'
            completed = subprocess.run(
                ['python3', str(ROOT / 'build_review_release.py'),
                 '--worktree', str(ROOT.parents[1]), '--commit', 'irrelevant',
                 '--name', 'symphony-review-report-../../other', '--evidence', str(target)],
                capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(target.exists())

    def test_cutover_requires_broker_paused_and_leaves_monitor_paused(self):
        cutover = module('review_cutover_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            g, _capture = cutover.bind(root)
            g.BROKER, g.MONITOR, g.WORKFLOW = [root / name for name in ('broker.toml', 'monitor.toml', 'workflow.md')]
            g.BROKER.write_text('status="ACTIVE"\nrrule="FREQ=MINUTELY;INTERVAL=1"\n')
            g.MONITOR.write_text('status="PAUSED"\n')
            g.WORKFLOW.write_text('fixture')
            with self.assertRaises(AssertionError):
                g.configuration()
            g.BROKER.write_text('status="PAUSED"\nrrule="FREQ=MINUTELY;INTERVAL=1"\n')
            pins = g.configuration()
            self.assertEqual(set(pins), {str(g.BROKER), str(g.MONITOR), str(g.WORKFLOW)})
            g.MONITOR.write_text('status="ACTIVE"\n')
            with self.assertRaises(AssertionError):
                g.configuration()

    def test_cutover_rejects_changed_artifact_and_source(self):
        cutover = module('review_cutover_artifact_test', ROOT / 'review_cutover.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / 'symphony-review-report-fixture'
            (release / 'evidence').mkdir(parents=True)
            build = release / 'dev'
            build.mkdir()
            artifact = build / 'fixture.beam'
            artifact.write_bytes(b'original compiled bytes')
            source = root / 'source'
            source.mkdir()
            source_file = source / 'fixture.ex'
            source_file.write_text('original source')
            guard, launcher = release / 'release_boot_guard.exs', release / 'run-local-factory'
            guard.write_text('guard fixture')
            launcher.write_text('launcher fixture')
            manifest = {'kind': 'FACTORY_REVIEW_REPORT_RELEASE_V1', 'schema_version': 54,
                        'build': str(build), 'source_root': str(source), 'source_commit': 'commit',
                        'factory_beam_fingerprint': 'fingerprint', 'factory_modules': {'fixture': 'digest'},
                        'previous_manifest_sha256': cutover.OLD_MANIFEST_SHA,
                        'artifact': {'fixture.beam': {'sha256': cutover.sha(artifact)}},
                        'source_hashes': {'fixture.ex': cutover.sha(source_file)}}
            manifest_path = release / 'evidence/release-manifest.json'
            manifest_path.write_text(json.dumps(manifest))
            candidate = {'release': str(release), 'build': str(build), 'source_commit': 'commit',
                         'schema_version': 54, 'factory_beam_fingerprint': 'fingerprint',
                         'factory_module_count': 1, 'manifest_sha256': cutover.sha(manifest_path),
                         'guard_sha256': cutover.sha(guard), 'launcher_sha256': cutover.sha(launcher)}
            (root / 'candidate.json').write_text(json.dumps(candidate))
            with patch.object(cutover, 'OLD_RELEASE', root / 'old-release'):
                g, _capture = cutover.bind(root)
                self.assertEqual(g.candidate()[0], candidate)
                artifact.write_bytes(b'changed compiled bytes')
                with self.assertRaises(AssertionError):
                    g.candidate()
                artifact.write_bytes(b'original compiled bytes')
                source_file.write_text('changed source')
                with self.assertRaises(AssertionError):
                    g.candidate()


if __name__ == '__main__':
    unittest.main()
