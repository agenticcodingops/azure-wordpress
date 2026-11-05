#!/usr/bin/env python3
"""Scan immutable push tips, keeping the runner's complete Git transaction."""
from __future__ import annotations

import argparse
import copy
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'lib'))
try:
    from scan_config import load_scan_config, load_yaml, require
    from checkov_policy import passive_policy
    HOOKS = tuple((HERE / 'lib/push-hook-ids.txt').read_text().split())
except (OSError, ValueError, ImportError) as exc:
    print('[pre-push] ERROR: ' + ' '.join(str(exc).splitlines()) + '; scan incomplete', file=sys.stderr)
    raise SystemExit(1)
# Every supported push hook explicitly declares this stage in the manifest.
# Config-wide default_stages only applies when a manifest has no stages.
MANIFEST_STAGES = {hook: ['pre-push'] for hook in HOOKS}
PLATFORM_REPOSITORY = 'https://github.com/agenticcodingops/auto-code-scanning'


def git(*args: str) -> bytes:
    # Replacement refs are local overlays, never the objects sent to the remote.
    return subprocess.check_output(['git', '--no-replace-objects', *args], stderr=subprocess.PIPE)


def bash() -> str:
    if os.name == 'nt':
        # Native subprocess lookup can select the WSL launcher instead of Git Bash.
        candidate = Path(os.fsdecode(git('--exec-path')).strip()).parents[2] / 'usr/bin/bash.exe'
        if candidate.is_file():
            return str(candidate)
    executable = shutil.which('bash')
    if not executable:
        raise ValueError('Bash is required for the hook runner')
    return executable


def select_shell(requested: str, *, windows: bool | None = None) -> tuple[str, str]:
    windows = os.name == 'nt' if windows is None else windows
    if requested == 'ps1' or (requested == 'auto' and windows):
        executable = shutil.which('pwsh') or shutil.which('powershell')
        if executable:
            return 'ps1', executable
        if requested == 'ps1':
            raise ValueError('PowerShell is required for the selected implementation')
    return 'sh', bash()


def policy_directory(root: Path) -> str:
    configured = os.environ.get('SCAN_CONFIG_DIR', '.scanning/configs')
    path = Path(configured)
    if path.is_absolute():
        try:
            path = path.resolve().relative_to(root)
        except ValueError as exc:
            raise ValueError('Push policies must be tracked inside the repository') from exc
    portable = PurePosixPath(path.as_posix().replace('\\', '/'))
    if '..' in portable.parts or ':' in portable.as_posix():
        raise ValueError('Push policy directory must remain inside the pushed tree')
    return portable.as_posix()


def tips(records: str) -> list[tuple[str, str]]:
    result = []
    for line in records.splitlines():
        fields = line.split()
        if len(fields) != 4:
            raise ValueError('Malformed pre-push record')
        _, local, _, remote = fields
        if not all(re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', oid) for oid in (local, remote)):
            raise ValueError('Malformed pre-push object ID')
        if set(local) == {'0'}:  # deletion has no local tree to scan
            continue
        # Peel annotated tags. Reject blob tags and unavailable objects.
        git('rev-parse', '--verify', local + '^{tree}')
        if (local, remote) not in result:
            result.append((local, remote))
    return result


def fetch_sources(ref: str, specs: list[str]) -> set[str]:
    """Invert positive fetch mappings, applying negative specs to source refs."""
    sources = set()
    for spec in specs:
        if spec.startswith('^'):
            continue
        source, separator, target = spec.removeprefix('+').partition(':')
        if not separator or not target or source.count('*') != target.count('*') or target.count('*') > 1:
            continue
        match = re.fullmatch(re.escape(target).replace(r'\*', '(.*)'), ref)
        if match:
            sources.add(source.replace('*', match[1]) if '*' in target else source)
    return {source for source in sources if not any(
        re.fullmatch(re.escape(spec[1:]).replace(r'\*', '.*'), source)
        for spec in specs if spec.startswith('^'))}


def destination_refs(remote_name: str | None) -> tuple[list[str], list[str]]:
    """Only direct, unambiguously owned refs/remotes/ refs prove ancestry.

    A destination with any fetch target outside refs/remotes/ is ambiguous:
    local branches, tags and other writable refs cannot prove what it holds.
    Discard all its tracking/default refs, including otherwise safe mappings,
    so new branches scan all ancestry and existing branches scan their range.
    """
    if remote_name is None:
        return [], []
    remotes = git('remote').decode().splitlines()
    names = {name for name in remotes if name == remote_name or
             git('remote', 'get-url', name).decode().strip() == remote_name}
    if not names:
        return [], []
    mappings = {}
    for name in remotes:
        try:
            mappings[name] = git('config', '--get-all', f'remote.{name}.fetch').decode().splitlines()
        except subprocess.CalledProcessError as exc:
            if exc.returncode != 1:
                raise
            mappings[name] = []
    for name in names:
        for spec in mappings[name]:
            if not spec.startswith('^'):
                _, separator, target = spec.removeprefix('+').partition(':')
                if separator and target and not target.startswith('refs/remotes/'):
                    return [], []
    refs = dict(line.split('\0', 1) for line in
                git('for-each-ref', '--format=%(refname)%00%(symref)').decode().splitlines())
    tracking = []
    for ref, symbolic_target in refs.items():
        if symbolic_target or not ref.startswith('refs/remotes/'):
            continue
        owners = {name for name, specs in mappings.items() if fetch_sources(ref, specs)}
        # A namespace can be shared by slash-separated remote names or custom
        # refspecs. Ambiguous ownership must increase scanning, never exclude it.
        if owners and owners <= names:
            tracking.append(ref)
    defaults = [ref for ref, target in refs.items() if target in tracking and
                any(ref == f'refs/remotes/{name}/HEAD' for name in names)]
    return tracking, defaults


def changed_paths(local: str, remote: str, remote_name: str | None = None) -> list[str]:
    """Select the transaction's range, independent of HEAD and the index."""
    if set(remote) == {'0'}:
        # A tag can point directly to a tree, which has no commit ancestry.
        # rev-list silently emits nothing for it; scan its files instead.
        if git('cat-file', '-t', local + '^{}').strip() == b'tree':
            return [os.fsdecode(name) for name in git('ls-tree', '-rz', '--name-only',
                    '--full-tree', local).split(b'\0') if name]
        # Only the destination's refs can establish what it already holds.
        # An unknown destination must conservatively scan all reachable commits.
        tracking, defaults = destination_refs(remote_name)
        if len(defaults) == 1:
            try:
                base = git('merge-base', local, defaults[0]).decode().strip()
            except subprocess.CalledProcessError as exc:
                if exc.returncode != 1:
                    raise
            else:
                return diff_paths(base, local)
        # Without a usable default/merge base, exclude just the destination's
        # tracked commits. With no destination refs, include all ancestry.
        commits = git('rev-list', local, *(['--not', *tracking] if tracking else [])).decode().splitlines()
        names = set()
        for commit in commits:
            names.update(filter(None, git('diff-tree', '--root', '-r', '-m', '--no-commit-id',
                '--no-ext-diff', '--no-textconv', '--no-renames', '--name-only', '-z',
                '--diff-filter=ACMT', commit, '--').split(b'\0')))
        return sorted(os.fsdecode(name) for name in names)
    return diff_paths(remote, local)


def diff_paths(base: str, local: str) -> list[str]:
    return [os.fsdecode(name) for name in git('diff', '--no-ext-diff', '--no-textconv',
        '--no-renames', '--name-only', '-z', '--diff-filter=ACMT', base, local, '--').split(b'\0') if name]


def materialize(oid: str, destination: Path, selected: set[str] | None = None) -> list[str]:
    """Copy blobs verbatim: no checkout filters, attributes, hooks or local index."""
    names = []
    entries = git('ls-tree', '-rz', '--full-tree', oid).split(b'\0')
    with subprocess.Popen(['git', '--no-replace-objects', 'cat-file', '--batch'], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE) as blobs:
        try:
            for entry in filter(None, entries):
                meta, raw_name = entry.split(b'\t', 1)
                mode, kind, blob = meta.split()
                name = os.fsdecode(raw_name)
                # Directory scanners must not pick up unchanged siblings or
                # nested sources, regardless of their file type.
                if selected is not None and name not in selected:
                    continue
                path = PurePosixPath(name)
                if (path.is_absolute() or any(p in ('..', '.git') or ':' in p or '\\' in p
                                              for p in path.parts)):
                    raise ValueError('Unsafe path in pushed tree')
                # Following a symlink or borrowing an unpinned submodule checkout
                # would read bytes outside this tree. Require explicit remediation.
                if kind != b'blob' or mode not in (b'100644', b'100755'):
                    raise ValueError('Push snapshot contains a symlink or submodule; scan incomplete')
                target = destination.joinpath(*path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists():
                    raise ValueError('Pushed paths collide on this filesystem')
                blobs.stdin.write(blob + b'\n')
                blobs.stdin.flush()
                header = blobs.stdout.readline().split()
                if len(header) != 3 or header[1] != b'blob':
                    raise ValueError('Cannot read pushed blob')
                size = int(header[2])
                with target.open('wb') as output:
                    remaining = size
                    while remaining:
                        data = blobs.stdout.read(min(remaining, 1024 * 1024))
                        if not data:
                            raise ValueError('Truncated pushed blob')
                        output.write(data)
                        remaining -= len(data)
                if blobs.stdout.read(1) != b'\n':
                    raise ValueError('Invalid blob response')
                if mode == b'100755':
                    target.chmod(0o755)
                names.append(name)
        except BaseException:
            # A failed destination write can leave the child blocked on a full
            # output pipe. Stop it before waiting, including on interruption.
            blobs.kill()
            raise
        finally:
            try:
                blobs.stdin.close()
            finally:
                blobs.stdout.close()
                blobs.wait()
    return names


def assert_report_path(path: Path) -> None:
    """Keep report cleanup and publication inside unlinked filesystem paths."""
    for part in (*reversed(path.parents), path):
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise OSError('Refusing a symlink or reparse point in report path')


def clear_report(path: Path) -> None:
    assert_report_path(path)
    path.unlink(missing_ok=True)


def export_report(source: Path, destination: Path) -> None:
    """Publish before snapshot cleanup, without exposing a partially copied report."""
    assert_report_path(source)
    assert_report_path(destination)
    if not source.is_file():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    prepared = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.scan-report-', dir=destination.parent, delete=False) as output:
            prepared = Path(output.name)
            with source.open('rb') as report:
                shutil.copyfileobj(report, output)
        assert_report_path(destination)
        prepared.replace(destination)
    finally:
        if prepared is not None and prepared.exists():
            prepared.unlink()


def scan(records: str, hooks: list[tuple[str, list[str]]], shell: str, *, from_git: bool = False,
         remote_name: str | None = None) -> int:
    root = Path(os.fsdecode(git('rev-parse', '--show-toplevel')).strip()).resolve()
    report = root / '.scanning/last-scan.json'
    # No report from an earlier transaction may survive a skipped or failed run.
    clear_report(report)
    objects = tips(records)
    if not records.strip() and not from_git:
        raise ValueError('Missing Git pre-push records; use the transaction-aware runner')
    if not objects or not hooks:
        return 0
    status = 0
    implementation, executable = select_shell(shell)
    policy_dir = policy_directory(root)
    for oid, remote in objects:
        clear_report(report)
        with tempfile.TemporaryDirectory(prefix='scan-push-') as temporary:
            # The system temp base is trusted and may have linked ancestors
            # (for example /var on macOS). Resolve it before adding tree paths;
            # links created inside the snapshot must still be rejected.
            temporary = Path(temporary).resolve(strict=True)
            snapshot = temporary / 'tree'
            snapshot.mkdir()
            selected = set(changed_paths(oid, remote, remote_name))
            # Policy is read from the pushed tip even when it did not change.
            required_policy = {'scan-config.yaml', '.snyk', str(PurePosixPath(policy_dir) / '.checkov.yaml'),
                               str(PurePosixPath(policy_dir) / '.trivyignore')}
            available = materialize(oid, snapshot, selected | required_policy)
            names = [name for name in available if name in selected]
            config = {}
            if (snapshot / 'scan-config.yaml').is_file():
                config = load_scan_config(snapshot / 'scan-config.yaml')
                enabled = config.get('global', {}).get('local_hooks_enabled', config.get('local_hooks_enabled', True))
                if enabled is False:
                    print(f'[pre-push] local scanning explicitly disabled in object {oid}', flush=True)
                    continue
            manifest = temporary / 'paths'
            manifest.write_bytes(b''.join(os.fsencode(p) + b'\0' for p in names))
            env = dict(os.environ, SCAN_PUSH_SNAPSHOT='1', SCAN_PUSH_FILES=str(manifest),
                       SCAN_CONFIG_FILE='scan-config.yaml', SCAN_CONFIG_DIR=policy_dir,
                       SCAN_CONSUMER_ROOT=str(root))
            for key in tuple(env):
                if key.startswith('GIT_'):
                    del env[key]
            for hook, extra in hooks:
                if hook not in HOOKS:
                    raise ValueError('Unknown pre-push scanner')
                extensions = ('.cs', '.csproj') if hook == 'dotnet-build' else ('.tf', '.tf.json')
                if not any(name.lower().endswith(extensions) for name in names):
                    continue
                clear_report(report)
                snapshot_report = snapshot / '.scanning/last-scan.json'
                # A tracked report or a previous scanner's output is not this run's output.
                clear_report(snapshot_report)
                if hook == 'tflint':
                    # Changing cwd must not make consumer-owned executable inputs
                    # look external merely because the scan runs in a snapshot.
                    for setting in ('SCAN_TFLINT_CONFIG', 'SCAN_TFLINT_PLUGIN_DIR'):
                        trusted = Path(env.get(setting, ''))
                        if not trusted.is_absolute():
                            raise ValueError(f'{setting} must be an external absolute path')
                        try:
                            trusted.resolve().relative_to(root)
                        except ValueError:
                            pass
                        else:
                            raise ValueError(f'{setting} must remain outside the consumer repository')
                # Executable linter configuration remains externally provisioned.
                policy = {'checkov': '.checkov.yaml', 'checkov-strict': '.checkov.yaml'}.get(hook)
                if policy and not (snapshot / policy_dir / policy).is_file():
                    raise ValueError(f'{hook} requires tracked {policy_dir}/{policy}; no fallback policy is allowed')
                if policy:
                    passive_policy(snapshot / policy_dir / policy)
                    if extra:
                        raise ValueError('Checkov extra arguments are disabled; configure passive policy instead')
                if hook == 'dotnet-build':
                    build = config.get('languages', {}).get('csharp', {}).get('build', {})
                    for field in ('working_dir', 'solution'):
                        configured = build.get(field, '')
                        path = PurePosixPath(configured.replace('\\', '/'))
                        if path.is_absolute() or '..' in path.parts or ':' in configured:
                            raise ValueError('Build paths must remain inside the pushed snapshot')
                if hook in ('dotnet-build', 'tflint'):
                    # Builds and module linting need unchanged inputs as context.
                    # TFLint filters findings to the transaction's selected files.
                    complete = temporary / 'complete'
                    if not complete.exists():
                        complete.mkdir()
                        materialize(oid, complete)
                    hook_snapshot = complete
                else:
                    hook_snapshot = snapshot
                snapshot_report = hook_snapshot / '.scanning/last-scan.json'
                clear_report(snapshot_report)
                print(f'[pre-push] {hook}: scanning object {oid}', flush=True)
                script = str(HERE / f'{hook}.{implementation}')
                command = ([executable, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script] if implementation == 'ps1'
                           else [executable, script])
                try:
                    result = subprocess.run(command + extra, cwd=hook_snapshot, env=env)
                finally:
                    export_report(snapshot_report, report)
                status = max(status, int(result.returncode != 0))
    return status


def platform_hook(repo: dict, hook: dict) -> bool:
    if hook.get('id') not in HOOKS:
        return False
    location = repo.get('repo', '').rstrip('/')
    if location in (PLATFORM_REPOSITORY, PLATFORM_REPOSITORY + '.git'):
        return True
    if location == 'local':
        entry = shlex.split(hook.get('entry', ''))
        return any(part.replace('\\', '/') == 'hooks/dispatcher.sh' and
                   entry[index + 1:index + 2] == [hook['id']]
                   for index, part in enumerate(entry))
    return False


def runner_configuration(source: str) -> str:
    """Read the generated runner's literal arguments without executing shell code."""
    template, marker, _ = source.partition('# end templated')
    assignment = re.search(r'^ARGS=\((.*)\)\s*$', template, re.MULTILINE | re.DOTALL)
    if not marker or assignment is None:
        raise ValueError('Original runner template is unrecognized')
    arguments = shlex.split(assignment[1])
    config = '.pre-commit-config.yaml'
    for index, argument in enumerate(arguments):
        if argument.startswith('--config='):
            config = argument.split('=', 1)[1]
        elif argument in ('--config', '-c'):
            if index + 1 == len(arguments):
                raise ValueError('Original runner configuration path is missing')
            config = arguments[index + 1]
    if not config:
        raise ValueError('Original runner configuration path is missing')
    return config


def push_configuration(config_path: str = '.pre-commit-config.yaml') -> tuple[list[tuple[str, list[str]]], dict]:
    config = load_yaml(config_path)
    # Validate once before filtering or adapting any entry, including entries
    # forwarded to the original runner and fields used in membership checks.
    repos = require(config.get('repos'), list, 'repos')
    for index, repo in enumerate(repos):
        key = f'repos[{index}]'
        require(repo, dict, key)
        require(repo.get('repo'), str, key + '.repo')
        for number, hook in enumerate(require(repo.get('hooks'), list, key + '.hooks')):
            hook_key = f'{key}.hooks[{number}]'
            require(hook, dict, hook_key)
            require(hook.get('id'), str, hook_key + '.id')
            if 'entry' in hook:
                require(hook['entry'], str, hook_key + '.entry')
            for field in ('args', 'stages'):
                if field in hook:
                    for item in require(hook[field], list, hook_key + '.' + field):
                        require(item, str, hook_key + '.' + field + '[]')
    forwarded = copy.deepcopy(config)
    skipped = set(os.environ.get('SKIP', '').split(','))
    selected = []
    retained_repos = []
    for repo in forwarded['repos']:
        retained = []
        for hook in repo['hooks']:
            if platform_hook(repo, hook) and any(stage in ('pre-push', 'push')
                    for stage in hook.get('stages', MANIFEST_STAGES[hook['id']])):
                # Remove adapted hooks from the forwarded config even when skipped.
                if hook['id'] not in skipped:
                    selected.append((hook['id'], hook.get('args', [])))
            else:
                retained.append(hook)
        if retained:
            repo['hooks'] = retained
            retained_repos.append(repo)
    forwarded['repos'] = retained_repos
    return selected, forwarded


def configured_hooks() -> list[tuple[str, list[str]]]:
    return push_configuration()[0]


def install() -> int:
    path = Path(os.fsdecode(git('rev-parse', '--git-path', 'hooks/pre-push')).strip())
    original = path.with_name('pre-push.pre-commit')
    marker = '# scan push transaction adapter'
    if not path.exists():
        subprocess.run(['pre-commit', 'install', '--hook-type', 'pre-push'], check=True)
    content = path.read_text(encoding='utf-8')
    if marker in content:
        if not original.is_file():
            raise ValueError('Original pre-push runner is missing; restore it before reinstalling')
        return 0
    if 'File generated by pre-commit' not in content:
        raise ValueError('Refusing to replace an unrecognized pre-push hook')
    if '# end templated' not in content:
        raise ValueError('Unrecognized runner template; cannot safely preserve its configuration')
    if original.exists():
        if 'File generated by pre-commit' not in original.read_text(encoding='utf-8'):
            raise ValueError('Unrecognized pre-push backup; review before reinstalling')
        # A normal runner reinstall may have saved our adapter as .legacy.
        # It must not be called recursively by the restored original runner.
        legacy = path.with_name('pre-push.legacy')
        if legacy.is_file() and marker in legacy.read_text(encoding='utf-8'):
            legacy.unlink()
    # Prepare and back up before atomically replacing the active hook.
    # Use open(newline=...) consistently for byte-stable adapter publication.
    prepared = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', newline='\n',
                                         prefix='.scan-push-', dir=path.parent, delete=False) as output:
            prepared = Path(output.name)
            output.write('#!/usr/bin/env bash\n' + marker + '\n'
                         'for py in python3 python py; do\n'
                         '  if command -v "$py" >/dev/null && "$py" -E -P -c "" 2>/dev/null; then\n'
                         '    exec "$py" -E -P hooks/pre-push.py --pre-commit-runner "$@"\n'
                         '  fi\ndone\necho "Python is required for push snapshots" >&2\nexit 1\n')
        prepared.chmod(0o755)
        shutil.copy2(path, original)
        prepared.replace(path)
    finally:
        if prepared is not None and prepared.exists():
            prepared.unlink()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--install-pre-commit', action='store_true')
    parser.add_argument('--pre-commit-runner', action='store_true')
    parser.add_argument('--stdin-from-git', action='store_true')
    parser.add_argument('--remote', help='destination remote name or URL supplied by Git')
    parser.add_argument('--shell', choices=('auto', 'sh', 'ps1'), default='auto')
    parser.add_argument('--hooks', default='checkov,tflint,dotnet-build')
    args, extra = parser.parse_known_args()
    if args.install_pre_commit:
        return install()
    records = sys.stdin.read()
    if args.pre_commit_runner:
        import yaml
        original = os.fsdecode(git('rev-parse', '--git-path', 'hooks/pre-push.pre-commit')).strip()
        source = Path(original).read_text(encoding='utf-8')
        hooks, forwarded = push_configuration(runner_configuration(source))
        status = scan(records, hooks, args.shell, from_git=True,
                      remote_name=args.remote or (extra[0] if extra else None))
        if status:
            return status
        source = source.replace('# end templated', '# end templated\nARGS+=(--config "$SCAN_PUSH_FILTERED_CONFIG")', 1)
        with tempfile.TemporaryDirectory(prefix='scan-push-config-') as directory:
            path = Path(directory).resolve(strict=True) / 'pre-commit-config.yaml'
            with path.open('w', encoding='utf-8', newline='\n') as output:
                yaml.safe_dump(forwarded, output)
            env = dict(os.environ, SCAN_PUSH_FILTERED_CONFIG=str(path))
            # Keep the saved runner's interpreter, hook directory, arguments and
            # legacy chaining. Only its config is overridden in this invocation.
            return subprocess.run([bash(), '-c', source, original, *extra],
                                  input=records, text=True, env=env).returncode
    remote_name = args.remote
    if len(extra) == 2 and all(not value.startswith('-') for value in extra):
        # Directly installed shell wrappers receive Git's remote name and URL.
        # Consume them here rather than forwarding them as scanner options.
        remote_name = remote_name or extra[0]
        extra = []
    return scan(records, [(h, extra) for h in args.hooks.split(',')], args.shell,
                from_git=args.stdin_from_git, remote_name=remote_name)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError, ImportError) as exc:
        print('[pre-push] ERROR: ' + ' '.join(str(exc).splitlines()) + '; scan incomplete', file=sys.stderr)
        raise SystemExit(1)
