#!/usr/bin/env python3
"""Run passive commit scanners against selected, immutable index blobs."""
import argparse
import importlib.util
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('push_snapshot', HERE / 'pre-push.py')
push = importlib.util.module_from_spec(spec)
spec.loader.exec_module(push)

EXTENSIONS = {
    'semgrep-csharp': ('.cs',),
    'semgrep-typescript': ('.ts', '.tsx', '.js', '.jsx'),
    'trivy-iac-critical': ('.tf', '.tf.json'),
}


def index_tree():
    """Capture index bytes without writing to the index shared by parallel hooks."""
    source = Path(os.fsdecode(push.git('rev-parse', '--git-path', 'index')).strip()).absolute()
    with tempfile.TemporaryDirectory(prefix='scan-index-capture-') as directory:
        private = Path(directory) / 'index'
        if source.exists():
            shutil.copyfile(source, private)
        environment = dict(os.environ, GIT_INDEX_FILE=str(private))
        return subprocess.check_output(
            ['git', '--no-replace-objects', '-c', 'core.splitIndex=false', 'write-tree'],
            env=environment, stderr=subprocess.PIPE).decode().strip()


def rule_inputs(root, tree, hook):
    """Bind consumer-local rule files/directories to the captured index too."""
    setting = {'semgrep-csharp': 'SEMGREP_RULESET_CSHARP',
               'semgrep-typescript': 'SEMGREP_RULESET_TYPESCRIPT'}.get(hook)
    configured = os.environ.get(setting, '') if setting else ''
    if not configured:
        return set(), {}
    target = Path(os.path.abspath(root / configured))
    try:
        relative = target.relative_to(root).as_posix()
    except ValueError:
        # Preserve explicitly external rules when cwd changes to the snapshot.
        return set(), {setting: str(target)}
    names = {os.fsdecode(name) for name in push.git('ls-tree', '-rz', '--name-only', tree).split(b'\0') if name}
    if relative == '.':
        # Semgrep loads the YAML files of a rules directory; the root has no name prefix.
        inputs = {name for name in names if name.lower().endswith(('.yml', '.yaml'))}
    else:
        inputs = {name for name in names if name == relative or name.startswith(relative.rstrip('/') + '/')}
    if not inputs and (Path(configured).is_absolute() or target.exists()):
        # A local rule file the snapshot cannot see would fail later with an unrelated
        # Semgrep error; registry references never exist on disk and pass through.
        raise ValueError(f'{setting} names {relative}, which is not staged; stage it or use a path outside the repository')
    # Registry references remain unchanged. Absolute consumer paths must never
    # keep reading worktree bytes, even when the rule file is absent in the index.
    override = {setting: relative} if inputs or Path(configured).is_absolute() else {}
    return inputs, override


def scan(hook, arguments, shell):
    root = Path(os.fsdecode(push.git('rev-parse', '--show-toplevel')).strip()).resolve()
    report = root / '.scanning/last-scan.json'
    push.clear_report(report)
    tree = index_tree()
    os.chdir(root)
    # The captured tree binds selection and export to one index version.
    try:
        base = os.fsdecode(push.git('rev-parse', '--verify', '-q', 'HEAD^{tree}')).strip()
    except subprocess.CalledProcessError:
        base = subprocess.check_output(['git', 'mktree'], input=b'').decode().strip()
    selected = {name for name in push.diff_paths(base, tree)
                if name.lower().endswith(EXTENSIONS[hook])}
    if not selected:
        return 0
    policy_dir = push.policy_directory(root)
    policy = {'scan-config.yaml', '.semgrepignore', '.gitignore',
              str(PurePosixPath(policy_dir) / '.trivyignore')}
    rules, rule_environment = rule_inputs(root, tree, hook)
    policy.update(rules)
    implementation, executable = push.select_shell(shell)
    with tempfile.TemporaryDirectory(prefix='scan-index-') as directory:
        temporary = Path(directory).resolve(strict=True)
        snapshot = temporary / 'tree'
        snapshot.mkdir()
        available = push.materialize(tree, snapshot, selected | policy)
        manifest = temporary / 'paths'
        manifest.write_bytes(b''.join(os.fsencode(p) + b'\0' for p in available if p in selected))
        env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        env.update(SCAN_INDEX_SNAPSHOT='1', SCAN_PUSH_FILES=str(manifest),
                   SCAN_CONFIG_FILE='scan-config.yaml', SCAN_CONFIG_DIR=policy_dir,
                   SCAN_CONSUMER_ROOT=str(root))
        env.update(rule_environment)
        script = str(HERE / f'{hook}.{implementation}')
        command = ([executable, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script]
                   if implementation == 'ps1' else [executable, script])
        try:
            return subprocess.run(command + arguments, cwd=snapshot, env=env).returncode
        finally:
            push.export_report(snapshot / '.scanning/last-scan.json', report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shell', choices=('auto', 'sh', 'ps1'), default='auto')
    parser.add_argument('hook', choices=EXTENSIONS)
    args, extra = parser.parse_known_args()
    try:
        raise SystemExit(scan(args.hook, extra, args.shell))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f'[pre-commit] ERROR: {exc}; scan incomplete', file=sys.stderr)
        raise SystemExit(1)
