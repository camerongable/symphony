"""Build an inactive, versioned local factory release from one clean commit."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile


BASE = Path('/Users/cgable/Library/Application Support/ai-factory/releases/symphony-review-report-first-publication-20261029')
BASE_SHA = 'e98243f6fe6d271fd86c392f06418385711a09bbf6e4e05de83618203d74c232'
BASELINE_COMMIT = '15021478779145049f54d37b2d4b5adfb59f8924'
ROOT = Path(__file__).resolve().parent
EXCLUDE = {'.git', '_build', 'deps', 'bin', 'log', 'logs', 'cover', '__pycache__'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def inventory(root, source=False):
    return {path.relative_to(root).as_posix(): {'sha256': sha(path)}
            for path in sorted(root.rglob('*')) if path.is_file()
            and (not source or not set(path.relative_to(root).parts) & EXCLUDE)}


def artifact_inventory(root):
    relative = 'lib/symphony_elixir/.mix/.mix_test_failures'
    cache = root / relative
    if cache.exists() or cache.is_symlink():
        metadata = cache.lstat()
        assert stat.S_ISREG(metadata.st_mode) and metadata.st_size <= 1_048_576
    return {name: value for name, value in inventory(root).items() if name != relative}


def command(args, cwd, env=None, timeout=60):
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True,
                          check=True, timeout=timeout).stdout.strip()


def clean_env(build=None):
    env = {key: value for key, value in os.environ.items() if key not in
           ('ELIXIR_ERL_OPTIONS', 'ERL_AFLAGS', 'ERL_ZFLAGS', 'ERL_LIBS',
            'MIX_BUILD_PATH', 'MIX_ENV', 'MIX_TARGET', 'ERL_FLAGS')}
    env.update(ERL_FLAGS='+S 4:4', MIX_ENV='dev', MIX_TARGET='host',
               PYTHONDONTWRITEBYTECODE='1')
    if build:
        env['MIX_BUILD_PATH'] = str(build)
    return env


def render_launcher(build, source, guard_eval):
    launcher = '''#!/bin/zsh
set -euo pipefail
export PATH='/Applications/ChatGPT.localized/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS:/Applications/ChatGPT.localized/ChatGPT.app/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
unset ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_ZFLAGS ERL_LIBS MIX_TARGET ERL_FLAGS
export MIX_ENV=dev
export MIX_BUILD_PATH=@BUILD@
cd @SOURCE@
guard_eval=@GUARD@
case "${SYMPHONY_PUSH_HANDOFF_QUALIFY:-}" in
  "") guard_eval+=':ok = SymphonyElixir.Workflow.set_workflow_file_path(List.last(System.argv())); :ok = SymphonyElixir.Factory.NativeRuntimeCompatibility.check_workflow(List.last(System.argv())); SymphonyElixir.CLI.main(System.argv())' ;;
  1) guard_eval+='IO.puts("FACTORY_REVIEW_REPORT_COLD_BOOT_ATTESTED")' ;;
  *) exit 78 ;;
esac
exec /opt/homebrew/bin/mise exec -- mix run --no-compile --no-deps-check --no-start -e "${guard_eval}" -- --i-understand-that-this-will-be-running-without-the-usual-guardrails --logs-root "${SYMPHONY_FACTORY_LOGS_ROOT:-/Users/cgable/Library/Logs/ai-factory}" "${1:-/Users/cgable/Repos/symphony/elixir/WORKFLOW.local.md}"
'''
    quote = lambda value: "'" + value.replace("'", "'\\''") + "'"
    return launcher.replace('@BUILD@', quote(str(build))).replace('@SOURCE@', quote(str(source / 'elixir'))).replace('@GUARD@', quote(guard_eval))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--worktree', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    worktree = args.worktree.resolve()
    assert worktree.is_dir()
    assert args.name.startswith('symphony-review-report-')
    assert all(ch.isalnum() or ch == '-' for ch in args.name)
    assert command(['git', 'rev-parse', 'HEAD'], worktree) == args.commit
    assert command(['git', 'status', '--porcelain', '--untracked-files=normal'], worktree) == ''
    command(['git', 'merge-base', '--is-ancestor', BASELINE_COMMIT, args.commit], worktree)
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)

    assert sha(BASE / 'evidence/release-manifest.json') == BASE_SHA
    base = json.loads((BASE / 'evidence/release-manifest.json').read_bytes())
    assert artifact_inventory(BASE / 'dev') == base['artifact']
    assert all(sha(Path(base['source_root']) / name) == digest
               for name, digest in base['source_hashes'].items())
    dependency_source = Path(base['source_root']) / 'elixir/deps'
    dependencies = inventory(dependency_source)
    assert hashlib.sha256(encode(dependencies)).hexdigest() == base['dependency_source_sha256']

    release = BASE.parent / args.name
    source = BASE.parent.parent / 'source-snapshots' / args.name
    assert not release.exists() and not source.exists()
    source.mkdir()
    with tempfile.TemporaryFile() as archive:
        subprocess.run(['git', 'archive', '--format=tar', args.commit], cwd=worktree,
                       stdout=archive, check=True, timeout=30)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as files:
            files.extractall(source, filter='data')
    source_map = inventory(source, True)
    assert 'elixir/lib/symphony_elixir/factory/ticket_mr_operation.ex' in source_map
    retained_helpers = {name: digest for name, digest in base['source_hashes'].items()
                        if name.startswith('elixir/priv/')}
    assert all(source_map[name]['sha256'] == digest
               for name, digest in retained_helpers.items())
    shutil.copytree(dependency_source, source / 'elixir/deps', symlinks=False)
    def transient_build_files(directory, _names):
        path = Path(directory)
        if path.name == 'symphony_elixir' and path.parent.name == 'phoenix-colocated':
            return {'node_modules'}
        if path.name == '.mix' and path.parent.name == 'symphony_elixir':
            return {'.mix_test_failures'}
        return set()

    shutil.copytree(BASE / 'dev', release / 'dev', symlinks=False, ignore=transient_build_files)
    for name in source_map:
        if name.startswith('elixir/priv/'):
            target = release / 'dev/lib/symphony_elixir/priv' / Path(name).relative_to('elixir/priv')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, target)
    (release / 'evidence').mkdir()
    env = clean_env(release / 'dev')
    compile_command = ['/opt/homebrew/bin/mise', 'exec', '--', 'mix', 'compile', '--force', '--no-deps-check']
    compiled = subprocess.run(compile_command, cwd=source / 'elixir', env=env,
                              capture_output=True, text=True, timeout=300)
    (evidence / 'release-compile.log').write_text(compiled.stdout + compiled.stderr)
    assert compiled.returncode == 0, (compiled.stdout + compiled.stderr)[-3000:]
    assert inventory(source, True) == source_map
    assert inventory(source / 'elixir/deps') == dependencies
    assert artifact_inventory(BASE / 'dev') == base['artifact']

    origin_script = '''
[source, build] = System.argv()
origins = for path <- Path.wildcard(Path.join(build, "lib/symphony_elixir/ebin/*.beam")) do
  {:ok, {module, [compile_info: info]}} = :beam_lib.chunks(String.to_charlist(path), [:compile_info])
  origin = to_string(info[:source])
  true = String.starts_with?(origin, source <> "/") and File.regular?(origin)
  %{module: to_string(module), source: Path.relative_to(origin, source), path: Path.relative_to(path, build)}
end
{:ok, [{:application, :symphony_elixir, properties}]} = :file.consult(String.to_charlist(Path.join(build, "lib/symphony_elixir/ebin/symphony_elixir.app")))
true = Enum.sort(Enum.map(origins, & &1.module)) == Enum.sort(Enum.map(properties[:modules], &to_string/1))
compatibility = SymphonyElixir.Factory.NativeRuntimeCompatibility
{:module, ^compatibility} = Code.ensure_loaded(compatibility)
true = to_string(:code.which(compatibility)) == Path.join(build, "lib/symphony_elixir/ebin/Elixir.SymphonyElixir.Factory.NativeRuntimeCompatibility.beam")
IO.puts(Jason.encode!(%{origins: origins, native_runtime_formats: compatibility.supported_formats()}))
'''
    compiled_metadata = json.loads(command(['/opt/homebrew/bin/mise', 'exec', '--', 'elixir',
                                  '-pa', str(release / 'dev/lib/jason/ebin'), '-pa', str(release / 'dev/lib/symphony_elixir/ebin'), '-e', origin_script,
                                  '--', str(source), str(release / 'dev')], source / 'elixir', env))
    origins = compiled_metadata['origins']
    assert all(item['source'] in source_map for item in origins)
    artifact = artifact_inventory(release / 'dev')
    factories = {item['module']: artifact[item['path']]['sha256'] for item in origins
                 if item['module'].startswith('Elixir.SymphonyElixir.Factory.')}
    fingerprint_script = '''
digests = IO.read(:stdio, :eof) |> Jason.decode!() |> Enum.sort()
  |> Enum.map(fn {name, hex} -> {name, Base.decode16!(hex, case: :lower)} end)
IO.puts(Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(digests)), case: :lower))
'''
    fingerprint = subprocess.run(['/opt/homebrew/bin/mise', 'exec', '--', 'elixir',
                                  '-pa', str(release / 'dev/lib/jason/ebin'), '-e', fingerprint_script],
                                 cwd=source / 'elixir', env=env, input=json.dumps(factories),
                                 capture_output=True, text=True, check=True, timeout=30).stdout.strip()
    manifest = {'kind': 'FACTORY_REVIEW_REPORT_RELEASE_V1', 'schema_version': 54,
                'native_runtime_formats': compiled_metadata['native_runtime_formats'],
                'build': str(release / 'dev'), 'source_root': str(source), 'release': str(release),
                'source': source_map, 'source_hashes': {name: item['sha256'] for name, item in source_map.items()},
                'factory_modules': factories, 'factory_beam_fingerprint': fingerprint,
                'artifact': artifact, 'compiled_origins': origins, 'source_commit': args.commit,
                'deployed_baseline_commit': BASELINE_COMMIT, 'previous_manifest_sha256': BASE_SHA,
                'base_artifact_manifest_sha256': BASE_SHA, 'dependency_source_sha256': base['dependency_source_sha256'],
                'compile_command': compile_command, 'activation': False}
    manifest_path = release / 'evidence/release-manifest.json'
    manifest_path.write_bytes(encode(manifest))
    guard_path = release / 'release_boot_guard.exs'
    shutil.copy2(ROOT / 'review_release_boot_guard.exs', guard_path)
    guard_eval = (f'path = {json.dumps(str(guard_path))}; raw = File.read!(path); '
                  f'true = Base.encode16(:crypto.hash(:sha256, raw), case: :lower) == "{sha(guard_path)}"; '
                  'Code.eval_string(raw, [], file: path); '
                  f':ok = ReviewReportReleaseBootGuard.load({json.dumps(str(manifest_path))}, "{sha(manifest_path)}"); ')
    launcher = render_launcher(release / 'dev', source, guard_eval)
    launcher_path = release / 'run-local-factory'
    launcher_path.write_text(launcher)
    launcher_path.chmod(0o755)
    result = {'result': 'BUILT_NOT_ACTIVATED', 'release': str(release), 'source': str(source),
              'build': str(release / 'dev'), 'source_commit': args.commit,
              'manifest_sha256': sha(manifest_path), 'guard_sha256': sha(guard_path),
              'launcher_sha256': sha(launcher_path), 'factory_beam_fingerprint': fingerprint,
              'factory_module_count': len(factories), 'schema_version': 54}
    (evidence / 'candidate.json').write_bytes(encode(result))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
