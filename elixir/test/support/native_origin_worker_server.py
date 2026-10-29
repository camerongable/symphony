"""Owned external-process fixture deriving storage only from actual child ENV/CLI."""
import json
import os
from pathlib import Path
import sys

trace, default_sqlite, control_path = map(Path, sys.argv[1:4])


def record(value):
    with trace.open('a') as output:
        output.write(json.dumps(value) + '\n')


record({'method': 'spawn', 'pid': os.getpid(), 'argv': sys.argv})
overrides = {}
for index, value in enumerate(sys.argv[:-1]):
    if value in ('--config', '-c'):
        key, separator, encoded = sys.argv[index + 1].partition('=')
        if separator:
            try:
                overrides[key] = json.loads(encoded)
            except ValueError:
                pass
home = os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))
sqlite = overrides.get('sqlite_home', os.environ.get('CODEX_SQLITE_HOME', str(default_sqlite)))
phase = 'actual' if 'default_permissions' in overrides else 'preflight'
record({'method': 'actor', 'phase': phase, 'pid': os.getpid(), 'codex_home': home,
        'sqlite_home': sqlite, 'sqlite_env': os.environ.get('CODEX_SQLITE_HOME')})
behavior = json.loads(control_path.read_text()).get(phase, {}) if control_path.exists() else {}
marker = (Path(sqlite) / 'marker').read_text() if (Path(sqlite) / 'marker').exists() else 'A'
thread = 'worker-' + marker


def send(identifier, result):
    print(json.dumps({'id': identifier, 'result': result}), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    record({'phase': phase, 'pid': os.getpid(), **request})
    identifier = request.get('id')
    if method == 'initialize':
        send(identifier, {'codexHome': behavior.get('home', home), 'platformFamily': 'unix',
                          'platformOs': 'macos', 'userAgent': 'symphony-orchestrator/0.160.0 (fixture)'})
    elif method == 'config/read':
        features = {name: overrides.get('features.' + name, enabled) for name, enabled in {
            'shell_tool': False, 'unified_exec': False, 'code_mode_host': True,
            'apps': False, 'multi_agent': False, 'browser_use': False,
            'browser_use_external': False, 'computer_use': False, 'image_generation': False,
            'request_permissions_tool': False, 'hooks': False}.items()}
        config = {'mcp_servers': {}, 'plugins': {}, 'features': features, 'web_search': 'disabled'}
        if not behavior.get('missing_sqlite'):
            config['sqlite_home'] = behavior.get('sqlite', sqlite)
        if behavior.get('replace') and not Path(behavior['replace'] + '-original').exists():
            path = Path(behavior['replace'])
            path.rename(str(path) + '-original')
            path.mkdir(mode=0o700)
        send(identifier, {} if behavior.get('missing_config_response') else {'config': config})
    elif method == 'account/read':
        send(identifier, {'account': {'type': behavior.get('account', 'chatgpt')}})
    elif method == 'mcpServerStatus/list':
        send(identifier, {'data': behavior.get('catalog', []), 'nextCursor': None})
    elif method in ('thread/start', 'thread/resume'):
        if method == 'thread/resume' and behavior.get('active_writer'):
            print(json.dumps({'id': identifier, 'error': {'code': -32600, 'message': 'thread already has an active writer'}}), flush=True)
            continue
        params = request['params']
        if method == 'thread/resume':
            thread = params['threadId']
        send(identifier, {'thread': {'id': thread, 'cwd': os.getcwd()}, 'cwd': os.getcwd(),
                          'runtimeWorkspaceRoots': [os.getcwd()], 'reasoningEffort': 'medium',
                          'activePermissionProfile': {'id': params['permissions']},
                          'approvalPolicy': 'never', 'model': 'gpt-6-luna'})
    elif method == 'turn/start':
        send(identifier, {'turn': {'id': 'turn-' + marker}})
        item = {'id': 'item-' + marker, 'type': 'agentMessage', 'phase': 'final_answer',
                'text': json.dumps({'status': 'PASS', 'findings': [], 'required_questions': []})}
        print(json.dumps({'method': 'item/completed', 'params': {'threadId': thread,
                         'turnId': 'turn-' + marker, 'item': item}}), flush=True)
        print(json.dumps({'method': 'turn/completed', 'params': {'threadId': thread,
                         'turn': {'id': 'turn-' + marker, 'status': 'completed', 'items': [item]}}}), flush=True)
    elif method == 'thread/read':
        if behavior.get('exit_on_read'):
            sys.exit(behavior['exit_on_read'])
        if behavior.get('replace_on_read') and not Path(behavior['replace_on_read'] + '-original').exists():
            path = Path(behavior['replace_on_read'])
            path.rename(str(path) + '-original')
            path.mkdir(mode=0o700)
        send(identifier, {'thread': {'id': thread, 'origin': marker, 'updatedAt': 1,
                          'status': {'type': 'idle'}, 'turns': []}})
    elif method == 'thread/turns/list':
        send(identifier, {'data': [{'id': 'turn-' + marker, 'status': 'completed', 'error': None, 'items': []}], 'nextCursor': None})
    elif method == 'thread/queue/list':
        send(identifier, {'data': [], 'nextCursor': None})
    elif method == 'thread/unsubscribe':
        send(identifier, {'status': 'unsubscribed'})
