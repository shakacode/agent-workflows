#!/usr/bin/env python3
"""One 18-run changelog pilot; host auth never enters the disposable executor."""
import argparse
import copy
import stat
import tempfile
import hashlib
import io
import json
import os
from pathlib import Path
import selectors
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
PROTOCOL = json.loads((HERE / 'protocol.json').read_text())
DOCKER = shutil.which('docker') or '/usr/local/bin/docker'
CODEX = shutil.which('codex')
UNKNOWN = 'UNKNOWN'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


def run(argv, **kwargs):
    kwargs.setdefault('timeout', 45)
    return subprocess.check_output([str(x) for x in argv], text=True, **kwargs)


def write(root, name, text, executable=False):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755 if executable else 0o644)


GH = '''#!/usr/bin/python3
import json,sys,subprocess
from pathlib import Path
a=sys.argv[1:]; rows=json.loads(Path('/workspace/prs.json').read_text()); target=json.loads(Path('/workspace/scenario.json').read_text())['target']
if a[:2]==['repo','view']:
 print('main' if 'defaultBranchRef' in ' '.join(a) else 'synthetic/pilot')
elif a[:2]==['auth','status']: print('Offline fixture responder; no credentials')
elif a and a[0]=='api' and '/commits/' in ' '.join(a):
 endpoint=next(x for x in a if '/commits/' in x); sha=endpoint.split('/commits/')[1].split('/')[0]
 subject=subprocess.check_output(['git','show','-s','--format=%s',sha],text=True)
 found=[dict(r,merged_at='2026-01-04T00:00:00Z',base={'ref':target}) for r in rows if r['number'] is not None and '(#'+str(r['number'])+')' in subject]
 print(json.dumps(found))
elif a[:2]==['pr','view'] or (a and a[0]=='api' and '/pulls/' in ' '.join(a)):
 n=int(a[2]) if a[:2]==['pr','view'] else int(next(x for x in a if '/pulls/' in x).split('/pulls/')[1].split('/')[0])
 r=next(r for r in rows if r['number']==n)
 print(json.dumps(dict(r,url='https://example.invalid/pilot/pull/'+str(n),state='MERGED',mergedAt='2026-01-04T00:00:00Z',baseRefName=target,files=[{'path':'changes/'+str(n)+'.txt'}],labels=[])))
else:
 print('Unsupported offline fixture gh operation: '+repr(a),file=sys.stderr);sys.exit(2)
'''
STAMP = '''#!/usr/bin/python3
import sys
from pathlib import Path
v=sys.argv[1] if len(sys.argv)==2 else ''
assert v=='1.1.0.rc.3', 'fixture stamp accepts only explicit rc.3'
p=Path('CHANGELOG.md');s=p.read_text();assert '## [1.1.0.rc.3]' not in s
s=s.replace('## [Unreleased]','## [Unreleased]\\n\\n## [1.1.0.rc.3] - 2026-01-04',1)
s=s.replace('v1.1.0.rc.2...develop','v1.1.0.rc.3...develop')
s+='[1.1.0.rc.3]: https://example.invalid/pilot/compare/v1.1.0.rc.2...v1.1.0.rc.3\\n'
p.write_text(s);Path('tmp/stamp-invocation').write_text(v+'\\n')
'''
CHECK = '''#!/usr/bin/python3
from pathlib import Path
import re
s=Path('CHANGELOG.md').read_text();assert s.endswith('\\n')
versions=re.findall(r'^## \\[([^]]+)\\]',s,re.M);assert len(versions)==len(set(versions))
for part in re.split(r'^## ',s,flags=re.M):
 cats=re.findall(r'^### (.+)$',part,re.M);assert len(cats)==len(set(cats))
print('changelog structure passed')
'''


def container(fixture, runtime, image, name, owned):
    argv = [DOCKER, 'run', '--rm', '-d', '--name', name, '--network', 'none',
            '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
            '--user', '1000:1000', '--pids-limit', '128', '--memory', '2g',
            '--mount', f'type=bind,src={fixture},dst=/workspace',
            '--mount', f'type=bind,src={runtime},dst=/opt/runtime,readonly',
            '--workdir', '/workspace', '--env', 'HOME=/workspace/home',
            '--env', 'CODEX_HOME=/workspace/codex', '--env', 'TMPDIR=/workspace/tmp',
            '--env', 'PATH=/opt/runtime/bin:/opt/runtime/codex-path:/usr/local/bin:/usr/bin:/bin',
            image, '/opt/runtime/bin/codex', 'exec-server', '--listen', 'ws://127.0.0.1:8765']
    # None means creation may have happened without returning an owned ID.
    # Never infer absence or delete by the shared name in that uncertain state.
    owned.append(None)
    container_id = run(argv).strip()
    owned[-1] = container_id  # Record ownership before verification can fail.
    info = json.loads(run([DOCKER, 'inspect', name]))[0]
    require(info['HostConfig']['NetworkMode'] == 'none' and info['HostConfig']['ReadonlyRootfs'], 'network/root boundary mismatch')
    require(info['Config']['User'] == '1000:1000' and info['HostConfig']['CapDrop'] == ['ALL'] and
            info['HostConfig']['SecurityOpt'] == ['no-new-privileges'], 'user/capability boundary mismatch')
    require(info['Image'] == image and
            dex(name, '/bin/cat', '/proc/1/cmdline').split('\0') ==
            ['/opt/runtime/bin/codex', 'exec-server', '--listen', 'ws://127.0.0.1:8765', ''],
            'persistent PID1/image mismatch')
    require(len(info['Mounts']) == 2 and
            {m['Destination']: (str(Path(m['Source']).resolve()), m['RW']) for m in info['Mounts']} ==
            {'/workspace': (str(fixture.resolve()), True), '/opt/runtime': (str(runtime.resolve()), False)},
            'fixture/runtime mount mismatch')
    return container_id


def dex(name, *argv, timeout=45):
    return run([DOCKER, 'exec', name, *argv], timeout=timeout)


def prepare(root, scenario, variant, runtime, image):
    root.mkdir(parents=True)
    root.chmod(0o777)
    for folder in ['home', 'codex', 'tmp', 'changes']:
        (root / folder).mkdir(); (root / folder).chmod(0o777)
    write(root, '.gitignore', 'home/\ncodex/\ntmp/\norigin.git/\n')
    write(root, 'AGENTS.md', PROTOCOL['common_policy'])
    write(root, 'CHANGELOG.md', scenario['changelog'])
    write(root, 'prs.json', json.dumps(scenario['prs'], indent=2) + '\n')
    write(root, 'scenario.json', json.dumps({'target': scenario['target'], 'compare': scenario['compare']}) + '\n')
    write(root, 'bin/gh', GH, True)
    write(root, 'bin/stamp-changelog', STAMP, True)
    write(root, 'bin/check-changelog', CHECK, True)
    seam = f"base_branch: main\nchangelog: CHANGELOG.md\npr_target_branch: {scenario['target']}\ncompare_branch: {scenario['compare']}\nchangelog_stamp_command: bin/stamp-changelog VERSION\n"
    write(root, '.agents/agent-workflow.yml', seam)
    write(root, 'README.md', 'Synthetic changelog fixture. PR target and compare branch are independently specified in the seam. Version stamping task: bin/stamp-changelog VERSION. No release publication.\n')
    ref = PROTOCOL[variant]
    names = run(['git', 'ls-tree', '-r', '--name-only', ref, 'skills/update-changelog'], cwd=REPO).splitlines()
    for path in names:
        if '/agents/' in path or path.endswith('-test.rb'):
            continue
        data = subprocess.check_output(['git', 'show', ref + ':' + path], cwd=REPO)
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        target.chmod(0o755 if '/bin/' in path else 0o644)
    # Files are synthetic and writable by the unprivileged container user.
    for path in root.rglob('*'):
        path.chmod(0o777 if path.is_dir() or os.access(path, os.X_OK) else 0o666)
    name = 'aw793-prepare'
    owned = []
    try:
        container(root, runtime, image, name, owned)
        def git(*args):
            return dex(name, 'git', *args)
        git('init', '-b', 'main')
        git('config', 'user.name', 'Pilot Fixture'); git('config', 'user.email', 'pilot@example.invalid')
        git('config', 'core.hooksPath', '/dev/null')
        git('add', '.')
        # Fixed dates make history deterministic across repetitions.
        def commit(subject):
            dex(name, 'env', 'GIT_AUTHOR_DATE=2026-01-01T00:00:00Z', 'GIT_COMMITTER_DATE=2026-01-01T00:00:00Z', 'git', 'commit', '-m', subject)
        commit('Synthetic baseline'); git('tag', 'v1.0.0')
        for index, pr in enumerate(scenario['prs']):
            dex(name, 'sh', '-c', f"printf '%s\\n' 'synthetic public change {index}' > changes/{index}.txt")
            git('add', 'changes'); commit(pr['title'] + (f" (#{pr['number']})" if pr['number'] else ''))
        if scenario['id'] == 'prerelease':
            git('tag', 'v1.1.0.rc.1'); git('tag', 'v1.1.0.rc.2')
            git('branch', 'maintenance'); git('branch', 'develop')
        git('clone', '--bare', '.', 'origin.git')
        git('remote', 'add', 'origin', '/workspace/origin.git'); git('fetch', 'origin', '--tags')
        git('checkout', '-b', 'pilot', 'origin/' + scenario['target'])
        # gh lives on the fixed filter PATH, through fixture HOME/bin is not used.
        # Invoke enumeration with an explicit fixture PATH in prompt and checks.
        rows = json.loads(dex(name, 'env', 'PATH=/workspace/bin:/usr/bin:/bin', 'ruby',
                              'skills/update-changelog/bin/changelog-merged-prs',
                              'v1.0.0..origin/' + scenario['target'], '--target-branch', scenario['target']))
        assert len(rows) == len(scenario['prs'])
        assert [r['pr'] for r in rows] == [p['number'] if p['number'] else UNKNOWN for p in scenario['prs']]
        dex(name, 'bin/check-changelog')
        hashes = {str(p.relative_to(root)): digest(p.read_bytes()) for p in root.rglob('*')
                  if p.is_file() and not any(x in p.relative_to(root).parts for x in ['.git', 'origin.git', 'home', 'codex', 'tmp'])}
        return {'files': hashes, 'helper_rows': rows, 'head': git('rev-parse', 'HEAD').strip()}
    finally:
        if owned and owned[0]:
            subprocess.run([DOCKER, 'rm', '-f', owned[0]], stdout=subprocess.DEVNULL, check=True, timeout=20)
        # Exec-server preparation creates runtime arg0 symlinks. Remove its disposable
        # scratch only after it exits, so prepared inputs contain no symlinks at all.
        for scratch in ['home', 'codex', 'tmp']:
            shutil.rmtree(root / scratch)
            (root / scratch).mkdir(); (root / scratch).chmod(0o777)


class RPC:
    def __init__(self, argv, log, events, cwd=None):
        self.proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, env=controller_environment())
        self.sel = selectors.DefaultSelector(); self.sel.register(self.proc.stdout, selectors.EVENT_READ)
        self.buf = b''; self.seq = 0; self.events = events; self.transport_failure = None
        self.peers = []

    def send(self, obj):
        self.proc.stdin.write((json.dumps(obj) + '\n').encode()); self.proc.stdin.flush()

    def next(self, timeout):
        end = time.monotonic() + timeout
        while True:
            for peer in getattr(self, 'peers', []):
                require(peer.poll() is None, 'executor owner or SSH tunnel disconnected')
            if b'\n' in self.buf:
                line, self.buf = self.buf.split(b'\n', 1)
                if line:
                    obj = json.loads(line); self.events.write(json.dumps(obj) + '\n'); self.events.flush()
                    failure = dispatch_failure(obj)
                    if failure: self.transport_failure = failure
                    return obj
            remaining = end - time.monotonic()
            if remaining <= 0: raise TimeoutError('app-server event deadline')
            if not self.sel.select(min(remaining, .25)): continue
            chunk = os.read(self.proc.stdout.fileno(), 1048576)
            if not chunk: raise RuntimeError('app-server disconnected')
            self.buf += chunk

    def call(self, method, params):
        self.seq += 1; seq = self.seq
        self.send({'id': seq, 'method': method, 'params': params})
        end = time.monotonic() + 30
        while True:
            obj = self.next(max(0, end - time.monotonic()))
            if obj.get('id') == seq:
                if 'error' in obj: raise RuntimeError(str(obj['error']))
                return obj['result']


def stop(proc):
    if proc:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()


def toml(value):
    if isinstance(value, dict):
        return '{' + ','.join(json.dumps(k) + '=' + toml(v) for k, v in value.items()) + '}'
    return json.dumps(value)


def canonical(path):
    previous = os.getcwd()
    try:
        os.chdir(path)
        return Path(os.getcwd())
    finally:
        os.chdir(previous)


def controller_config(adapter, state):
    import tomllib  # M5 Python >=3.11; the M1 executor never reads home config.
    config = dict(PROTOCOL['controller_overrides'])
    # Disable the actual M5 inventory, not a list copied from another host.
    for path in controller_sources(state):
        if Path(path).is_file():
            for name in tomllib.loads(Path(path).read_text()).get('mcp_servers', {}):
                require(name and all(c in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in name),
                        'unsupported installed MCP name; cannot safely construct disabled override')
                config['mcp_servers.' + name + '.enabled'] = False
    # Declare exactly the 18 physical cwd spellings before any thread exists.
    # Process-only trust prevents thread/start from persisting new home config.
    config['projects'] = {str(canonical(state / 'trials' / row['id'])):
                          {'trust_level': 'trusted'} for row in trial_rows()}
    return config


RUNTIME_FILES = {'bin/codex', 'bin/websocat', 'codex-path/rg',
                 'bin/codex-code-mode-host', 'codex-resources/bwrap',
                 'codex-resources/zsh/bin/zsh', 'codex-package.json'}
VERIFIED = ['live_fixture_freeze', 'runtime_inventory', 'effective_config',
            'empty_mcp_inventory', 'persistent_session', 'shell_and_patch_dispatch', 'fail_closed',
            'split_host_routing', 'process_only_trust', 'installed_sources_unchanged',
            'tunnel_loss_cleanup', 'owner_loss_cleanup']


def require(condition, message):
    if not condition: raise RuntimeError(message)


def tree_snapshot(root):
    """Hash live files, modes and directories, including BOTH Git object/ref stores.

    No ignored directories: edited history/config, empty directories and symlinks
    must not be hidden behind an unchanged manifest. Never follow fixture symlinks.
    """
    require(root.is_dir() and not root.is_symlink(), 'invalid fixture root')
    result = {}
    for path in sorted(root.rglob('*')):
        mode = path.lstat().st_mode
        require(not stat.S_ISLNK(mode), 'unexpected symlink: ' + str(path))
        require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), 'unexpected special file')
        result[str(path.relative_to(root))] = {'mode': stat.S_IMODE(mode),
            'sha256': digest(path.read_bytes()) if stat.S_ISREG(mode) else 'directory'}
    return result


def runtime_inventory(runtime):
    files = {k: v for k, v in tree_snapshot(runtime).items() if v['sha256'] != 'directory'}
    require(set(files) == RUNTIME_FILES, 'public runtime must contain exactly seven files')
    return files


def controller_environment():
    # Authentication remains in the controller's existing home, never the executor.
    # Do not inherit arbitrary CODEX_* or proxy/config overrides from the launcher.
    return {'HOME': str(Path.home()), 'PATH': '/usr/local/bin:/usr/bin:/bin',
            'TMPDIR': '/private/tmp'}


def controller_sources(state):
    # Include absent locations so adding a project/user/system config also stales review.
    files = {Path.home() / '.codex' / n for n in ['config.toml', 'requirements.toml']}
    files.update(Path('/etc/codex') / n for n in ['config.toml', 'requirements.toml', 'managed_config.toml'])
    for cwd in [state] + [state / 'trials' / f'run-{i:02}' for i in range(1, 19)]:
        for parent in [cwd] + list(cwd.parents): files.add(parent / '.codex/config.toml')
    result = {}
    for p in sorted(files):
        if p.is_file():
            info = p.stat()
            result[str(p)] = dict(sha256=digest(p.read_bytes()), dev=info.st_dev, ino=info.st_ino,
                mode=stat.S_IMODE(info.st_mode), size=info.st_size,
                mtime_ns=info.st_mtime_ns, ctime_ns=info.st_ctime_ns)
        else:
            result[str(p)] = 'ABSENT'
    return result


def executor_binding(state, adapter, image, runtime):
    require(image == PROTOCOL['runtime_image_id'], 'immutable Ruby image differs from protocol')
    inventory = runtime_inventory(runtime)
    require(inventory == PROTOCOL['runtime_inventory'], 'runtime differs from protocol')
    filter_hash = digest((adapter / 'filter-persistent-exec.py').read_bytes())
    require(filter_hash == digest(PROTOCOL['transport_filter_source'].encode()), 'filter differs from public source')
    return {'runner_sha256': digest(Path(__file__).read_bytes()),
            'protocol_sha256': digest((HERE / 'protocol.json').read_bytes()), 'image': image,
            'runtime_inventory': inventory,
            'host_websocat_sha256': digest((adapter / 'websocat').read_bytes()),
            'filter_sha256': filter_hash,
            'state': str(canonical(state)), 'adapter': str(canonical(adapter)),
            'docker_version': json.loads(run([DOCKER, 'version', '--format', '{{json .Server}}'])),
            'fixture_manifest_sha256': digest((state / 'fixture-manifests.json').read_bytes()),
            'fixtures': {key: tree_snapshot(state / 'fixtures' / key)
                         for key in json.loads((state / 'fixture-manifests.json').read_text())}}


SSH_OPTIONS = ['-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no', '-o', 'PermitLocalCommand=no',
    '-o', 'RemoteCommand=none', '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ControlPersist=no',
    '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2']


def executor_config(adapter):
    value = json.loads((adapter / 'm1-executor.json').read_text())
    require(set(value) == {'host', 'runner', 'state', 'adapter'}, 'invalid fixed M1 executor config')
    require(value['host'] == 'm1', 'this pilot uses the existing m1 SSH alias')
    require(all(isinstance(value[k], str) and value[k].startswith('/') for k in ['runner', 'state', 'adapter']),
            'executor paths must be absolute')
    return value


def ssh_command(adapter, image, phase, row=None):
    config = executor_config(adapter)
    require(phase in ['executor-bind', 'executor-trial'], 'unsupported executor phase')
    command = ['python3', config['runner'], phase, '--state', config['state'],
               '--adapter', config['adapter'], '--image', image]
    if row is not None:
        require(row in trial_rows(), 'unknown frozen row')
        command += ['--row', row['id']]
    return ['ssh', *SSH_OPTIONS, config['host'], shlex.join(['zsh', '-lc', shlex.join(command)])]


def binding(state, adapter, image, runtime):
    ssh_effective = run(['ssh', '-G', *SSH_OPTIONS, executor_config(adapter)['host']])
    require(not any(line.split(' ', 1)[0] in ['localforward', 'remoteforward', 'dynamicforward']
                    for line in ssh_effective.splitlines()), 'unexpected configured SSH forwarding')
    remote = json.loads(run(ssh_command(adapter, image, 'executor-bind'), timeout=45))
    require(remote['runner_sha256'] == digest(Path(__file__).read_bytes()) and
            remote['protocol_sha256'] == digest((HERE / 'protocol.json').read_bytes()), 'M1 task code differs')
    return {'runner_sha256': digest(Path(__file__).read_bytes()),
            'protocol_sha256': digest((HERE / 'protocol.json').read_bytes()),
            'host_codex_sha256': digest(Path(CODEX).resolve().read_bytes()),
            'config': controller_config(adapter, state), 'controller_sources': controller_sources(state),
            'controller_environment': controller_environment(), 'executor': remote,
            'ssh_config': executor_config(adapter), 'ssh_options': SSH_OPTIONS,
            'ssh_effective_config': ssh_effective,
            'ssh_binary_sha256': digest(Path(shutil.which('ssh')).read_bytes())}


def validate_gate(receipt, release, current, receipt_sha):
    # This extends the existing exact executor receipt, not an alternate approval path.
    require(isinstance(receipt, dict), 'missing independent receipt')
    require(str(receipt.get('decision', '')).startswith('PASS:') and
            receipt.get('runner_review_status') == 'PASS' and receipt.get('trial_release') is False,
            'independent exact-runner PASS required; adapter-only PASS cannot release')
    require(all(receipt.get('runner_verified', {}).get(k) is True for k in VERIFIED), 'incomplete independent scope')
    require(receipt.get('runner_binding') == current, 'independent runtime/runner/filter/config/freeze mismatch')
    require(isinstance(receipt.get('approved_effective_config'), dict) and
            bool(receipt['approved_effective_config']), 'missing actual effective configuration')
    effective = receipt['approved_effective_config']
    require(all(k in effective for k in ['model', 'model_provider', 'model_reasoning_effort', 'service_tier', 'features', 'mcp_servers']),
            'incomplete effective configuration')
    require({k: effective[v] for k, v in [('model', 'model'), ('provider', 'model_provider'),
            ('effort', 'model_reasoning_effort'), ('service_tier', 'service_tier')]} == PROTOCOL['route'],
            'approved route mismatch')
    require(effective['features'].get('code_mode_host') is True and
            effective['features'].get('skip_host_skill_discovery') is True and
            all(v.get('enabled') is False for v in effective['mcp_servers'].values()), 'unapproved controller tool surface')
    require(isinstance(release, dict) and release.get('owner') == 'M5' and
            release.get('target') == 'shakacode/agent-workflows:issue:793' and
            release.get('trial_release') is True and release.get('independent_receipt_sha256') == receipt_sha,
            'missing or mismatched separate M5 release')


def readiness(state, adapter, image, runtime):
    receipt_path = adapter / 'independent-executor-final-review.json'
    require(receipt_path.is_file(), 'missing independent receipt')
    raw = receipt_path.read_bytes(); receipt = json.loads(raw)
    release_path = adapter / 'm5-trial-release.json'
    release = json.loads(release_path.read_text()) if release_path.is_file() else None
    validate_gate(receipt, release, receipt.get('runner_binding'), digest(raw))
    current = binding(state, adapter, image, runtime)
    require(current == json.loads((state / 'freeze.json').read_text()), 'live freeze mismatch')
    validate_gate(receipt, release, current, digest(raw))
    return receipt


def approved_surface(app, cwd, receipt, started_thread=None):
    # Full effective config, not six historical MCP overrides. Read for the actual
    # trial cwd after initialization and again after thread creation, before turn/start.
    actual = app.call('config/read', {'cwd': str(cwd), 'includeLayers': False})['config']
    expected = receipt['approved_effective_config']
    projects = expected.get('projects', {})
    require(projects.get(str(canonical(cwd))) == {'trust_level': 'trusted'},
            'exact process-only cwd trust missing before thread/start')
    if started_thread is not None:
        require(started_thread.get('cwd') == str(canonical(cwd)), 'thread cwd differs from predeclared physical path')
    require(actual == expected, 'effective controller configuration changed')
    require(all(v.get('enabled') is False for v in actual.get('mcp_servers', {}).values()),
            'unexpected enabled MCP configuration')
    inventory = app.call('mcpServerStatus/list', {})
    require(inventory.get('nextCursor') is None and isinstance(inventory.get('data'), list), 'incomplete MCP inventory')
    for server in inventory['data']:
        require(server.get('tools') == {} and server.get('resources') == [] and
                server.get('resourceTemplates') == [], 'live MCP tool/resource/template exposure')
    route = {'model': actual.get('model', UNKNOWN), 'provider': actual.get('model_provider', UNKNOWN),
             'effort': actual.get('model_reasoning_effort', UNKNOWN), 'service_tier': actual.get('service_tier', UNKNOWN)}
    require(route == PROTOCOL['route'], 'resolved controller route changed or unavailable')
    return {'effective_config_sha256': digest(json.dumps(actual, sort_keys=True).encode()),
            'mcp_inventory': inventory, 'resolved_route': route, 'process_trusted_cwd': str(canonical(cwd))}


def observed_thread_route(thread):
    # Pinned app-server fields may be absent/null. Effective config binds the full
    # route, including tier; independently compare every thread field it exposes.
    observed = {}
    for field, route_key in [('model', 'model'), ('modelProvider', 'provider'),
                             ('reasoningEffort', 'effort'), ('serviceTier', 'service_tier')]:
        value = thread.get(field)
        observed[field] = UNKNOWN if value is None else value
        if value is not None:
            require(value == PROTOCOL['route'][route_key], 'exposed thread route mismatch: ' + field)
    return observed


def dispatch_failure(event):
    # Structured failures can arrive without commandExecution completion. A normal
    # nonzero helper exit alone is not a transport failure. Keep controller stderr too.
    if isinstance(event, dict):
        if event.get('error') or event.get('failure') or event.get('method') == 'error':
            return json.dumps(event)
        # A completed shell process can report status=failed solely for exit 1.
        # Keep that as task evidence; explicit transport errors are still scanned.
        if event.get('status') == 'failed' and (event.get('type') == 'fileChange' or
                (event.get('type') == 'commandExecution' and type(event.get('exitCode')) is not int)):
            return json.dumps(event)
        return next((failure for value in event.values() if (failure := dispatch_failure(value))), None)
    if isinstance(event, list):
        return next((failure for value in event if (failure := dispatch_failure(value))), None)
    if isinstance(event, str) and any(term in event.lower() for term in [
            'unknown session id', 'exec-server transport disconnected', 'exec-server transport closed', 'createprocess',
            'connection refused', 'failed to dispatch', 'failed to connect', 'recovery timeout',
            'transport disconnected', 'executor disconnected']):
        return event
    return None


def trial_rows():
    rows = []
    for si, scenario in enumerate(PROTOCOL['scenarios']):
        for rep in range(3):
            variants = ['baseline', 'candidate'] if (si + rep) % 2 == 0 else ['candidate', 'baseline']
            for variant in variants:
                rows.append({'id': f'run-{len(rows)+1:02}', 'scenario': scenario['id'],
                             'variant': variant, 'repetition': rep+1})
    return rows


class JSONLines:
    def __init__(self, stream):
        self.stream = stream; self.buf = b''
        self.sel = selectors.DefaultSelector(); self.sel.register(stream, selectors.EVENT_READ)

    def read(self, seconds, check=lambda: None):
        deadline = time.monotonic() + seconds
        while b'\n' not in self.buf:
            check()
            require(time.monotonic() < deadline, 'executor owner deadline')
            if not self.sel.select(.25): continue
            chunk = os.read(self.stream.fileno(), 65536)
            require(bool(chunk), 'executor owner EOF')
            self.buf += chunk
            require(len(self.buf) <= 16 * 1024 * 1024, 'oversized executor record')
        line, self.buf = self.buf.split(b'\n', 1)
        return json.loads(line)


def send_json(stream, value):
    stream.write((json.dumps(value) + '\n').encode()); stream.flush()


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def wait_listener(port, proc):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        require(proc.poll() is None, 'relay/tunnel startup failure')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.2): return
        except OSError: time.sleep(.1)
    raise RuntimeError('relay/tunnel listener deadline')


def executor_trial(state, adapter, image, runtime, row):
    """M1 only: one fixture/container/relay, fixed JSON commands, no controller.

    SSH stdin EOF, TERM and a hard per-owner deadline all enter the same cleanup.
    Paths and the frozen row come from task configuration, never model output.
    """
    name = 'aw793-split-' + row['id']; relay = None; result = None; owned = []
    container_validated = False; finalizing = False
    require(not (state / ('owner-' + row['id'] + '.json')).exists() and
            not (state / 'trials' / row['id']).exists(), 'M1 trial already attempted; preserve original evidence')
    incoming = JSONLines(sys.stdin.buffer)
    def interrupted(signum, frame):
        if not finalizing: raise RuntimeError('executor owner terminated or deadline expired')
    old_handlers = {sig: signal.signal(sig, interrupted) for sig in [signal.SIGTERM, signal.SIGALRM]}
    signal.alarm(PROTOCOL['run_timeout_seconds'] + 120)
    try:
        request = incoming.read(15)
        require(set(request) == {'binding'}, 'owner requires exact binding first')
        current = executor_binding(state, adapter, image, runtime)
        require(current == request['binding'], 'M1 binding changed before executor launch')
        trial_dir = state / 'trials' / row['id']; trial_dir.mkdir(parents=True)
        fixture = state / 'fixtures' / row['scenario'] / row['variant']
        expected = current['fixtures'][row['scenario'] + '/' + row['variant']]
        work = trial_dir / 'fixture'; shutil.copytree(fixture, work, symlinks=True); work.chmod(0o777)
        require(tree_snapshot(work) == expected, 'M1 fixture changed during copy')
        container(work, runtime, image, name, owned)
        container_validated = True
        port = free_port()
        relay = subprocess.Popen([str(adapter / 'websocat'), '-t', '--linemode-strip-newlines', '--exit-on-eof',
            f'ws-l:127.0.0.1:{port}', 'exec:/usr/bin/python3', '--exec-args',
            str(adapter / 'filter-persistent-exec.py'), name],
            stdout=subprocess.DEVNULL, stderr=(trial_dir / 'relay.log').open('w'))
        wait_listener(port, relay)
        send_json(sys.stdout.buffer, {'kind': 'ready', 'port': port, 'binding': current})
        command = incoming.read(PROTOCOL['run_timeout_seconds'] + 60,
                                lambda: require(relay.poll() is None, 'M1 relay disconnected'))
        require(command in [{'command': 'finish'}, {'command': 'cancel'}], 'unknown executor command')
        result = {'kind': 'result' if command['command'] == 'finish' else 'cancelled'}
    except Exception as exc:
        result = {'kind': 'error', 'error': str(exc)}
    finally:
        finalizing = True  # Let bounded cleanup and its receipt survive termination signals.
        signal.alarm(0)
        stop(relay)
        if container_validated:
            for field, args in [('diff', ('git', 'diff', '--no-ext-diff', '--no-color', 'HEAD')),
                                ('git_status', ('git', 'status', '--porcelain')),
                                ('final_changelog', ('cat', 'CHANGELOG.md'))]:
                try:
                    result[field] = dex(name, *args, timeout=5)
                except Exception as exc:
                    result.setdefault('collection_errors', {})[field] = str(exc)
            if result.get('collection_errors') and result['kind'] == 'result':
                result.update(kind='error', error='M1 result collection incomplete')
        clean = not owned
        if owned and owned[0]:
            try:
                subprocess.run([DOCKER, 'rm', '-f', owned[0]], capture_output=True, timeout=20)
                absent = subprocess.run([DOCKER, 'inspect', owned[0]], capture_output=True, timeout=20)
                clean = absent.returncode != 0 and b'no such object' in absent.stderr.lower()
            except subprocess.TimeoutExpired:
                clean = False
        started = UNKNOWN if owned and not owned[0] else bool(owned)
        result = dict(result or {'kind': 'error'}, executor_started=started, cleanup_verified=clean)
        if not clean:
            result.update(kind='error', cleanup_error='M1 container cleanup not verified')
            result.setdefault('error', 'M1 container cleanup not verified')
        save(state / ('owner-' + row['id'] + '.json'), result)
        for sig, handler in old_handlers.items(): signal.signal(sig, handler)
    send_json(sys.stdout.buffer, result)


def trial(state, adapter, image, runtime, row):
    receipt = readiness(state, adapter, image, runtime)  # BEFORE controller launch
    trial_dir = canonical(state / 'trials' / row['id'])
    require(not any(trial_dir.iterdir()), 'trial already attempted or contains unexpected files')
    require(receipt['runner_binding']['config']['projects'].get(str(trial_dir)) == {'trust_level': 'trusted'},
            'exact process-only trust absent; refuse before controller or executor launch')
    app = owner = tunnel = None; owner_reader = None; owner_finished = False
    result = dict(row, status='failed', elapsed_seconds=UNKNOWN, token_usage=UNKNOWN, quality=UNKNOWN)
    start = time.monotonic()
    save(trial_dir / 'attempt.json', dict(row, started_at=time.time()))
    try:
        owner = subprocess.Popen(ssh_command(adapter, image, 'executor-trial', row),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(trial_dir / 'owner.log').open('w'))
        owner_reader = JSONLines(owner.stdout)
        send_json(owner.stdin, {'binding': receipt['runner_binding']['executor']})
        ready = owner_reader.read(60)
        if ready.get('kind') in ['result', 'cancelled', 'error']:
            owner_finished = True
            result['executor_cleanup_verified'] = ready.get('cleanup_verified') is True
            result.update({k: ready[k] for k in
                           ['diff', 'git_status', 'final_changelog', 'collection_errors', 'cleanup_error'] if k in ready})
        require(ready.get('kind') == 'ready' and ready.get('binding') == receipt['runner_binding']['executor'],
                'M1 executor did not report the approved ready binding: ' + str(ready.get('error', '')))
        require(type(ready.get('port')) is int and 1024 <= ready['port'] <= 65535, 'invalid remote relay port')
        port = free_port()
        tunnel = subprocess.Popen(['ssh', *SSH_OPTIONS, '-N', '-L',
            f"127.0.0.1:{port}:127.0.0.1:{ready['port']}", executor_config(adapter)['host']],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=(trial_dir / 'tunnel.log').open('w'))
        wait_listener(port, tunnel)
        argv = [CODEX, 'app-server', '--stdio']
        for k, v in controller_config(adapter, state).items(): argv += ['-c', k + '=' + toml(v)]
        result['controller_argv'] = argv
        app = RPC(argv, (trial_dir / 'controller.log').open('w'), (trial_dir / 'events.jsonl').open('w'), cwd=trial_dir)
        app.peers = [owner, tunnel]
        app.call('initialize', {'clientInfo': {'name': 'aw793-pilot', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        app.send({'method': 'initialized'})
        result['controller_surface'] = approved_surface(app, trial_dir, receipt)
        app.call('environment/add', {'environmentId': 'pilot', 'execServerUrl': f'ws://127.0.0.1:{port}', 'connectTimeoutMs': 5000})
        env = [{'environmentId': 'pilot', 'cwd': '/workspace', 'runtimeWorkspaceRoots': ['/workspace']}]
        thread = app.call('thread/start', {'model': PROTOCOL['route']['model'], 'modelProvider': 'openai',
                         'ephemeral': True, 'cwd': str(trial_dir), 'approvalPolicy': 'never',
                         'sandbox': 'danger-full-access', 'dynamicTools': [], 'environments': env,
                         'developerInstructions': 'Use only the disposable external environment. No subagents or publication. Read /workspace/AGENTS.md first. All shell tools must use login=false. The fixture gh responder is /workspace/bin/gh: prepend /workspace/bin to PATH when invoking gh or the changelog helper.'})
        result['observed_thread_route'] = observed_thread_route(thread)
        scenario = next(s for s in PROTOCOL['scenarios'] if s['id'] == row['scenario'])
        prompt = 'Read and follow /workspace/skills/update-changelog/SKILL.md for this task: ' + scenario['invocation']
        result['prompt'] = prompt
        tid = thread['thread']['id']
        result['controller_surface_before_turn'] = approved_surface(app, trial_dir, receipt, thread['thread'])
        require(controller_sources(state) == receipt['runner_binding']['controller_sources'], 'installed config changed at thread/start')
        require(not app.transport_failure, 'controller error before turn/start')
        require(not dispatch_failure((trial_dir / 'controller.log').read_text()), 'controller stderr error before turn/start')
        app.call('turn/start', {'threadId': tid, 'input': [{'type': 'text', 'text': prompt}],
                               'effort': PROTOCOL['route']['effort'], 'environments': env})
        end = time.monotonic() + PROTOCOL['run_timeout_seconds']
        while True:
            event = app.next(max(0, end - time.monotonic()))
            if event.get('method') == 'thread/tokenUsage/updated': result['token_usage'] = event['params']['tokenUsage']
            require(not app.transport_failure, 'tool dispatch failure; stop batch')
            require(not dispatch_failure((trial_dir / 'controller.log').read_text()), 'controller stderr dispatch failure')
            if event.get('method') == 'turn/completed':
                result['turn'] = event['params']['turn']; result['status'] = result['turn']['status']; break
        # End the controller before removing the relay, so shutdown cannot race
        # an automatic connection attempt against an already-collected executor.
        stop(app.proc)
        send_json(owner.stdin, {'command': 'finish'})
        remote_result = owner_reader.read(60)
        result.update({k: remote_result[k] for k in
                       ['diff', 'git_status', 'final_changelog', 'collection_errors'] if k in remote_result})
        result['executor_cleanup_verified'] = remote_result.get('cleanup_verified') is True
        owner_finished = remote_result.get('kind') in ['result', 'cancelled', 'error']
        require(remote_result.get('kind') == 'result' and remote_result.get('cleanup_verified') is True,
                'M1 result/cleanup failed: ' + str(remote_result.get('error', '')))
    except KeyboardInterrupt:
        result['status'] = 'interrupted'
        raise
    except Exception as exc:
        result['error'] = str(exc)
    finally:
        if app and app.transport_failure:
            result['transport_failure'] = app.transport_failure
        stop(app.proc if app else None); stop(tunnel)
        if owner and not owner_finished:
            try:
                try: send_json(owner.stdin, {'command': 'cancel'})
                except OSError: pass  # An exited owner can still have a buffered terminal reply.
                deadline = time.monotonic() + 60
                cancelled = owner_reader.read(max(0, deadline - time.monotonic()))
                if cancelled.get('kind') == 'ready':
                    cancelled = owner_reader.read(max(0, deadline - time.monotonic()))
                require(cancelled.get('kind') in ['result', 'cancelled', 'error'], 'missing terminal owner reply')
                result['executor_cleanup_verified'] = cancelled.get('cleanup_verified') is True
                result.update({k: cancelled[k] for k in
                               ['diff', 'git_status', 'final_changelog', 'collection_errors'] if k in cancelled})
            except (OSError, RuntimeError, ValueError):
                result['executor_cleanup_verified'] = False
        if owner:
            try: owner.stdin.close()
            except OSError: pass  # Preserve the owner-loss result even after a broken pipe.
            try: owner.wait(timeout=45)
            except subprocess.TimeoutExpired: stop(owner)
        log_path = trial_dir / 'controller.log'
        log_failure = dispatch_failure(log_path.read_text()) if log_path.exists() else None
        if log_failure: result['transport_failure'] = log_failure
        result['installed_sources_unchanged'] = controller_sources(state) == receipt['runner_binding']['controller_sources']
        if not result['installed_sources_unchanged']:
            result['error'] = 'installed controller configuration changed'
        if owner and result.get('executor_cleanup_verified') is not True:
            result.setdefault('cleanup_error', 'executor cleanup not verified; stop batch')
            result.setdefault('error', result['cleanup_error'])
        result['elapsed_seconds'] = round(time.monotonic() - start, 3)
        save(trial_dir / 'result.json', result)
    return result


def self_test(state):
    """Deterministic gate/dispatch tests. Synthetic approvals exist only in memory.

    Process entrypoints fail by default; fault simulations use inert mocks.
    No controller, network, model, approval receipt or release is created.
    """
    checks = []
    def forbidden(*args, **kwargs):
        raise AssertionError('self-test attempted process launch')
    def refused(name, fn):
        try: fn()
        except (RuntimeError, FileNotFoundError, KeyError): checks.append(name)
        else: raise AssertionError('gate accepted ' + name)
    original_popen = subprocess.Popen; subprocess.Popen = forbidden
    try:
        current = {k: 'synthetic' for k in ['runner_sha256', 'protocol_sha256', 'executor',
            'host_codex_sha256', 'config', 'controller_sources', 'controller_environment',
            'ssh_config', 'ssh_options', 'ssh_effective_config', 'ssh_binary_sha256']}
        receipt = {'decision': 'PASS: SYNTHETIC UNIT TEST ONLY', 'runner_review_status': 'PASS',
                   'trial_release': False, 'runner_verified': dict.fromkeys(VERIFIED, True),
                   'runner_binding': current, 'approved_effective_config': {
                       'model': PROTOCOL['route']['model'], 'model_provider': PROTOCOL['route']['provider'],
                       'model_reasoning_effort': PROTOCOL['route']['effort'], 'service_tier': PROTOCOL['route']['service_tier'],
                       'features': {'code_mode_host': True, 'skip_host_skill_discovery': True}, 'mcp_servers': {}}}
        release = {'owner': 'M5', 'target': 'shakacode/agent-workflows:issue:793',
                   'trial_release': True, 'independent_receipt_sha256': 'synthetic-hash'}
        def gate(r=receipt, rel=release, actual=current): validate_gate(r, rel, actual, 'synthetic-hash')
        refused('missing receipt', lambda: gate(None))
        refused('failed receipt', lambda: gate(dict(receipt, decision='FAIL')))
        refused('adapter-only receipt', lambda: gate(dict(receipt, runner_review_status='REQUIRED')))
        refused('incomplete receipt', lambda: gate(dict(receipt, runner_verified={})))
        refused('missing effective config', lambda: gate(dict(receipt, approved_effective_config={})))
        refused('incomplete effective config', lambda: gate(dict(receipt, approved_effective_config={'model': 'partial'})))
        for key in current:
            refused('mismatch ' + key, lambda key=key: gate(actual=dict(current, **{key: 'changed'})))
        refused('missing M5 release', lambda: gate(rel=None))
        refused('wrong receipt release', lambda: gate(rel=dict(release, independent_receipt_sha256='other')))
        refused('non-M5 release', lambda: gate(rel=dict(release, owner='worker')))
        gate(); checks.append('positive gate only, process launch forbidden')
        with tempfile.TemporaryDirectory(dir=state) as tmp:
            adapter = Path(tmp)
            refused('readiness missing receipt before any SSH/controller process',
                    lambda: readiness(state, adapter, PROTOCOL['runtime_image_id'], None))
            receipt_path = adapter / 'independent-executor-final-review.json'
            original_file, original_bytes = Path.is_file, Path.read_bytes
            synthetic = receipt
            Path.is_file = lambda p: True if p == receipt_path else original_file(p)
            Path.read_bytes = lambda p: json.dumps(synthetic).encode() if p == receipt_path else original_bytes(p)
            try:
                refused('readiness missing separate release before any SSH/controller process',
                        lambda: readiness(state, adapter, PROTOCOL['runtime_image_id'], None))
                synthetic = dict(receipt, runner_review_status='REQUIRED')
                refused('readiness adapter-only receipt before any SSH/controller process',
                        lambda: readiness(state, adapter, PROTOCOL['runtime_image_id'], None))
            finally:
                Path.is_file, Path.read_bytes = original_file, original_bytes
        with tempfile.TemporaryDirectory(dir=state) as tmp:
            root = Path(tmp)
            for name in ['skills/helper', 'skills/SKILL.md', 'scenario.json', '.git/refs/heads/main']:
                write(root, name, 'original')
            write(root, 'origin.git/objects/object', 'original'); expected = tree_snapshot(root)
            for name in ['skills/helper', 'skills/SKILL.md', 'scenario.json', '.git/refs/heads/main', 'origin.git/objects/object']:
                (root / name).write_text('edited')
                refused('live mutation ' + name, lambda: require(tree_snapshot(root) == expected, 'live mismatch'))
                (root / name).write_text('original')
            (root / 'unexpected').symlink_to(root / 'skills/helper')
            refused('unexpected fixture symlink', lambda: tree_snapshot(root))
        class MockRPC:
            def __init__(self, config, inventory): self.config = config; self.inventory = inventory
            def call(self, method, params):
                return {'config': self.config} if method == 'config/read' else self.inventory
        cfg = {'model': PROTOCOL['route']['model'], 'model_provider': PROTOCOL['route']['provider'],
               'model_reasoning_effort': PROTOCOL['route']['effort'], 'service_tier': PROTOCOL['route']['service_tier'],
               'mcp_servers': {}, 'projects': {str(canonical(state)): {'trust_level': 'trusted'}}}
        approved = {'approved_effective_config': cfg}
        approved_surface(MockRPC(cfg, {'data': []}), state, approved)
        approved_surface(MockRPC(cfg, {'data': []}), state, approved, {'cwd': str(canonical(state))})
        checks.append('exact process-only trust accepted before and after thread/start')
        for label, config in [('absent', dict(cfg, projects={})),
                ('untrusted', dict(cfg, projects={str(canonical(state)): {'trust_level': 'untrusted'}}))]:
            refused(label + ' cwd trust', lambda config=config: approved_surface(
                MockRPC(config, {'data': []}), state, {'approved_effective_config': config}))
        refused('changed effective config', lambda: approved_surface(MockRPC(dict(cfg, extra=True), {'data': []}), state, approved))
        refused('unexpected thread cwd', lambda: approved_surface(MockRPC(cfg, {'data': []}), state, approved, {'cwd': '/'}))
        for key, value in [('tools', {'unexpected': {}}), ('resources', [{}]), ('resourceTemplates', [{}])]:
            server = dict(tools={}, resources=[], resourceTemplates=[]); server[key] = value
            refused('live MCP ' + key, lambda server=server: approved_surface(MockRPC(cfg, {'data': [server]}), state, approved))
        refused('incomplete MCP pagination', lambda: approved_surface(MockRPC(cfg, {'data': [], 'nextCursor': 'more'}), state, approved))
        for name, event in [
                ('structured RPC error', {'id': 4, 'error': {'code': -1, 'message': 'dispatch unavailable'}}),
                ('CreateProcess without completion', {'method': 'item/updated', 'params': {'output': 'CreateProcess failed'}}),
                ('patch structured failure', {'method': 'item/updated', 'params': {'item': {'type': 'fileChange', 'status': 'failed'}}}),
                ('completed turn with error', {'method': 'turn/completed', 'params': {'turn': {'status': 'completed', 'error': {'message': 'lost executor'}}}}),
                ('controller stderr', 'ERROR failed to connect exec-server: connection refused')]:
            require(bool(dispatch_failure(event)), 'undetected ' + name); checks.append(name)
        closed_stderr = ('ERROR: apply_patch verification failed: Failed to read file to update '
                         '/workspace/CHANGELOG.md: exec-server transport closed')
        require(dispatch_failure(closed_stderr) == closed_stderr, 'transport-closed stderr not preserved')
        checks.append('exact patch transport-closed stderr recognized and preserved without fileChange event')
        context_stderr = ('ERROR: apply_patch verification failed: Failed to find expected lines '
                          'in /workspace/CHANGELOG.md: synthetic context')
        require(dispatch_failure(context_stderr) is None, 'ordinary patch context rejection misclassified')
        checks.append('ordinary Failed to find expected lines patch stderr remains task evidence')
        fake = RPC.__new__(RPC); fake.events = io.StringIO(); fake.transport_failure = None
        fake.buf = (json.dumps({'method': 'item/updated', 'params': {'error': {'message': 'patch dispatch failed'}}}) + '\n' +
                    json.dumps({'method': 'turn/completed', 'params': {'turn': {'status': 'completed'}}}) + '\n').encode()
        fake.next(1); fake.next(1)
        require(bool(fake.transport_failure), 'completed turn erased preceding dispatch failure')
        checks.append('structured dispatch error persists after completed turn')
        class DeadPeer:
            def poll(self): return 1
        fake.peers = [DeadPeer()]
        refused('owner or tunnel loss before buffered event', lambda: fake.next(1))
        # Match the actual item/completed envelope and failed status of a remote
        # ordinary exit-1 command; the previous test omitted status and missed this.
        ordinary = {'method': 'item/completed', 'params': {'threadId': 'synthetic-thread',
            'turnId': 'synthetic-turn', 'item': {'type': 'commandExecution', 'id': 'call-1',
            'command': 'grep missing fixture.txt', 'cwd': '/workspace', 'status': 'failed',
            'exitCode': 1, 'aggregatedOutput': '', 'durationMs': 8}}}
        for name, output in [('grep no match', ''), ('helper negative exit', 'No eligible entries'),
                             ('benign canary denial', 'cat: /host-only-canary: No such file or directory')]:
            event = copy.deepcopy(ordinary); event['params']['item']['aggregatedOutput'] = output
            require(dispatch_failure(event) is None, 'ordinary exit misclassified: ' + name)
            checks.append('ordinary status=failed exitCode=1: ' + name)
        for name, changes in [
                ('executor loss with nonzero exit', {'aggregatedOutput': 'exec-server transport disconnected'}),
                ('CreateProcess without exit code', {'exitCode': None, 'aggregatedOutput': 'CreateProcess failed'}),
                ('structured routing failure', {'error': {'message': 'executor unavailable'}})]:
            event = copy.deepcopy(ordinary); event['params']['item'].update(changes)
            require(bool(dispatch_failure(event)), 'routing error missed: ' + name)
            checks.append('actual event shape: ' + name)
        fake = RPC.__new__(RPC); fake.events = io.StringIO(); fake.transport_failure = None
        fake.buf = (json.dumps(ordinary) + '\n').encode(); fake.next(1)
        require(fake.transport_failure is None, 'RPC flagged ordinary nonzero exit')
        checks.append('ordinary failed command retained by RPC without transport stop')
        exposed = {'model': PROTOCOL['route']['model'], 'modelProvider': PROTOCOL['route']['provider'],
                   'reasoningEffort': PROTOCOL['route']['effort']}
        require(observed_thread_route(exposed)['serviceTier'] == UNKNOWN, 'missing tier must be UNKNOWN')
        require(observed_thread_route(dict(exposed, serviceTier=None))['serviceTier'] == UNKNOWN, 'null tier must be UNKNOWN')
        require(observed_thread_route(dict(exposed, serviceTier=PROTOCOL['route']['service_tier']))['serviceTier'] ==
                PROTOCOL['route']['service_tier'], 'exposed tier not verified')
        checks.append('missing/null tier UNKNOWN; exposed matching tier verified')
        for field in ['model', 'modelProvider', 'reasoningEffort', 'serviceTier']:
            refused('exposed thread route mismatch ' + field,
                    lambda field=field: observed_thread_route(dict(exposed, **{field: 'unexpected'})))
        from types import SimpleNamespace
        from unittest.mock import patch
        # Exercise real failure paths with every process/network entry mocked.
        for fault in ['startup-timeout', 'validation-failure', 'cancel', 'partial-finish',
                      'owner EOF', 'owner deadline', 'relay loss', 'termination during cleanup']:
            with tempfile.TemporaryDirectory(dir=state) as tmp:
                root = Path(tmp); row = trial_rows()[0]
                fixture = root / 'fixtures' / row['scenario'] / row['variant']
                fixture.mkdir(parents=True)
                current = {'fixtures': {row['scenario'] + '/' + row['variant']: {}}}
                incoming = iter([{'binding': current}, {'command': 'finish' if fault == 'partial-finish' else 'cancel'}])
                sent = []; removed = []; snapshots = []
                def read_owner(seconds, check=lambda: None):
                    if sent and fault in ['owner EOF', 'owner deadline', 'relay loss']:
                        raise RuntimeError('synthetic ' + fault)
                    return next(incoming)
                def start(argv, **kwargs):
                    if argv[1] == 'run':
                        if fault == 'startup-timeout': raise subprocess.TimeoutExpired(argv, 30)
                        return 'owned-test-id\n'
                    raise RuntimeError('synthetic validation failure')
                def created(fixture, runtime, image, name, owned): owned.append('owned-test-id')
                def snapshot(name, *args, **kwargs):
                    snapshots.append(args)
                    if fault == 'partial-finish' and args[:2] == ('git', 'status'):
                        raise RuntimeError('synthetic status read failure')
                    return 'synthetic diff' if args[:2] == ('git', 'diff') else 'synthetic state'
                def cleanup(argv, **kwargs):
                    require(argv[-1] == 'owned-test-id', 'cleanup touched unknown ownership')
                    removed.append(argv[1])
                    return SimpleNamespace(returncode=1, stderr=b'No such object')
                fake_relay = SimpleNamespace(poll=lambda: None)
                def stop_relay(*args):
                    if fault == 'termination during cleanup':
                        for sig in [signal.SIGTERM, signal.SIGALRM]: signal.getsignal(sig)(sig, None)
                changes = {'executor_binding': lambda *a: current, 'tree_snapshot': lambda *a: {},
                    'JSONLines': lambda *a: SimpleNamespace(read=read_owner),
                    'send_json': lambda stream, value: sent.append(value), 'run': start,
                    'dex': snapshot, 'free_port': lambda: 23456, 'wait_listener': lambda *a: None,
                    'stop': stop_relay}
                if fault not in ['startup-timeout', 'validation-failure']: changes['container'] = created
                with patch.dict(globals(), changes), patch.object(subprocess, 'Popen', return_value=fake_relay), \
                        patch.object(subprocess, 'run', side_effect=cleanup):
                    executor_trial(root, root, 'sha256:synthetic', root, row)
                result = sent[-1]
                if fault == 'startup-timeout':
                    require(result['executor_started'] == UNKNOWN and result['cleanup_verified'] is False,
                            'indeterminate creation falsely confirmed absent')
                    require(not removed and 'timed out' in result['error'], 'unknown ownership removed or error lost')
                else:
                    require(removed == ['rm', 'inspect'] and result['cleanup_verified'], 'known ID not cleaned')
                    if fault != 'validation-failure':
                        require(len(snapshots) == 3 and result['diff'] == 'synthetic diff' and
                                result['final_changelog'] == 'synthetic state', 'snapshot evidence lost')
                        if fault == 'partial-finish':
                            require(result['kind'] == 'error' and 'git_status' in result['collection_errors'],
                                    'partial finish reported complete')
                        elif fault in ['cancel', 'termination during cleanup']: require(result['kind'] == 'cancelled', 'cancel outcome changed')
                        else: require(result['error'] == 'synthetic ' + fault, 'primary owner error lost')
                    else: require(not snapshots, 'snapshot attempted before boundary validation')
                checks.append('executor failure evidence: ' + fault)
        for cancellation_fault in ['none', 'broken-pipe', 'delayed-ready']:
            with tempfile.TemporaryDirectory(dir=state) as tmp:
                root = Path(tmp); row = trial_rows()[0]
                trial_dir = root / 'trials' / row['id']; trial_dir.mkdir(parents=True)
                expected_sources = {'synthetic': True}
                receipt = {'runner_binding': {'executor': {}, 'controller_sources': expected_sources,
                           'config': {'projects': {str(canonical(trial_dir)): {'trust_level': 'trusted'}}}}}
                def send_cancel(stream, value):
                    if cancellation_fault == 'broken-pipe' and value == {'command': 'cancel'}: raise BrokenPipeError('synthetic closed owner')
                replies = iter(([RuntimeError('synthetic startup deadline')] if cancellation_fault == 'delayed-ready' else []) +
                               [{'kind': 'ready', 'binding': {}, 'port': 0},
                                {'kind': 'cancelled', 'cleanup_verified': True, 'diff': 'preserved diff',
                                 'collection_errors': {'git_status': 'synthetic read failure'}}])
                def read_reply(*args):
                    value = next(replies)
                    if isinstance(value, Exception): raise value
                    return value
                owner = SimpleNamespace(stdin=SimpleNamespace(close=lambda: None), stdout=None, wait=lambda **k: 0)
                with patch.dict(globals(), {'readiness': lambda *a: receipt, 'ssh_command': lambda *a: ['synthetic'],
                        'JSONLines': lambda *a: SimpleNamespace(read=read_reply),
                        'send_json': send_cancel, 'stop': lambda *a: None,
                        'controller_sources': lambda *a: expected_sources}), \
                        patch.object(subprocess, 'Popen', return_value=owner):
                    result = trial(root, root, 'sha256:synthetic', root, row)
                require(result['status'] == 'failed' and result['diff'] == 'preserved diff' and
                        result['collection_errors'] == {'git_status': 'synthetic read failure'} and
                        result['executor_cleanup_verified'], 'M5 cancellation discarded partial evidence')
                checks.append('M5 cancellation preserves partial snapshot and cleanup: ' + cancellation_fault)
        for clean in [True, False]:
            with tempfile.TemporaryDirectory(dir=state) as tmp:
                root = Path(tmp); row = trial_rows()[0]
                trial_dir = root / 'trials' / row['id']; trial_dir.mkdir(parents=True)
                receipt = {'runner_binding': {'executor': {}, 'controller_sources': {},
                           'config': {'projects': {str(canonical(trial_dir)): {'trust_level': 'trusted'}}}}}
                terminal = {'kind': 'error', 'error': 'synthetic boundary failure', 'cleanup_verified': clean}
                sent = []
                owner = SimpleNamespace(stdin=SimpleNamespace(close=lambda: None), stdout=None, wait=lambda **k: 0)
                with patch.dict(globals(), {'readiness': lambda *a: receipt, 'ssh_command': lambda *a: ['synthetic'],
                        'JSONLines': lambda *a: SimpleNamespace(read=lambda *a: terminal),
                        'send_json': lambda stream, value: sent.append(value), 'stop': lambda *a: None,
                        'controller_sources': lambda *a: {}}), patch.object(subprocess, 'Popen', return_value=owner):
                    result = trial(root, root, 'sha256:synthetic', root, row)
                require(len(sent) == 1 and result['executor_cleanup_verified'] is clean and
                        'synthetic boundary failure' in result['error'], 'terminal startup evidence lost')
                require(clean or 'cleanup_error' in result, 'cleanup uncertainty not recorded separately')
                checks.append('M5 terminal startup preserves error and cleanup=' + str(clean))
    finally:
        subprocess.Popen = original_popen
    save(state / 'self-test-result.json', {'checks_passed': checks, 'model_calls': 0,
         'controller_launches': 0, 'approval_artifacts_created': 0,
         'runner_sha256': digest(Path(__file__).read_bytes())})
    print(json.dumps({'checks_passed': len(checks), 'model_calls': 0, 'controller_launches': 0}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'executor-bind', 'executor-trial', 'freeze', 'gate-check', 'self-test', 'run'])
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--adapter', type=Path, required=True)
    parser.add_argument('--image', required=True, help='Exact local image sha256 ID')
    parser.add_argument('--row', choices=[row['id'] for row in trial_rows()])
    args = parser.parse_args(); args.state = args.state.resolve(); args.adapter = args.adapter.resolve()
    require(not args.state.is_relative_to(REPO), 'private state must be outside repository')
    args.state.mkdir(parents=True, exist_ok=True)
    assert args.image.startswith('sha256:')
    runtime = args.adapter / 'runtime/package/vendor/aarch64-unknown-linux-musl'
    if args.phase == 'self-test':
        self_test(args.state); return
    if args.phase == 'executor-bind':
        print(json.dumps(executor_binding(args.state, args.adapter, args.image, runtime))); return
    if args.phase == 'executor-trial':
        require(args.row is not None, 'executor row required')
        executor_trial(args.state, args.adapter, args.image, runtime, next(r for r in trial_rows() if r['id'] == args.row)); return
    if args.phase == 'freeze':
        require(not any(args.state.iterdir()), 'freeze requires new empty M5 state')
        for row in trial_rows(): (args.state / 'trials' / row['id']).mkdir(parents=True)
        save(args.state / 'freeze.json', binding(args.state, args.adapter, args.image, runtime))
        print('Both hosts frozen; no controller, thread or model launch.'); return
    if args.phase == 'gate-check':
        readiness(args.state, args.adapter, args.image, runtime)
        print('Gate valid only; no controller or model launch.'); return
    if args.phase == 'prepare':
        require(not any(args.state.iterdir()), 'prepare requires NEW empty state; never overwrite a freeze')
        require(args.image == PROTOCOL['runtime_image_id'], 'unreviewed Ruby image')
        require(runtime_inventory(runtime) == PROTOCOL['runtime_inventory'], 'runtime inventory differs')
        manifests = {}
        for scenario in PROTOCOL['scenarios']:
            for variant in ['baseline', 'candidate']:
                manifests[scenario['id'] + '/' + variant] = prepare(args.state / 'fixtures' / scenario['id'] / variant, scenario, variant, runtime, args.image)
        save(args.state / 'fixture-manifests.json', manifests)
        save(args.state / 'executor-freeze.json', executor_binding(args.state, args.adapter, args.image, runtime))
        print('Prepared six fixtures, helper checks passed; no model calls. Freeze saved.')
    else:
        readiness(args.state, args.adapter, args.image, runtime)
        receipt_path = args.adapter / 'independent-executor-final-review.json'
        if (args.state / 'run-started.json').exists(): raise RuntimeError('Run already attempted; do not silently repeat trials')
        save(args.state / 'run-started.json', {'started_at': time.time(), 'receipt_sha256': digest(receipt_path.read_bytes())})
        rows = trial_rows()
        results = []
        for row in rows:
            (args.state / 'STATUS.md').write_text(f"Running {row['id']} of 18: {row['scenario']} / {row['variant']}. Completed {len(results)}. GitHub owner M5.\n")
            results.append(trial(args.state, args.adapter, args.image, runtime, row))
            save(args.state / 'results-private.json', results)
            if results[-1].get('transport_failure') or results[-1].get('error') or results[-1]['status'] != 'completed':
                (args.state / 'STATUS.md').write_text('BLOCKED: transport/runtime failure; preserve attempts and reverify before any restart.\n')
                return
        (args.state / 'STATUS.md').write_text('18 attempts finished; grading, scrubbing and validation pending.\n')


if __name__ == '__main__':
    main()
