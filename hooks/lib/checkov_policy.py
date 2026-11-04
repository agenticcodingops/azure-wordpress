"""Build a passive-only Checkov configuration, never forwarding arbitrary YAML."""
from contextlib import contextmanager
from pathlib import Path
import sys
import tempfile


def passive_policy(source=None):
    # Imported here, as in scan_config.load_yaml, so hooks that never read a Checkov
    # policy do not need PyYAML when pre-push.py loads this module.
    import yaml
    try:
        data = {} if source is None else yaml.safe_load(Path(source).read_text(encoding='utf-8'))
    except (yaml.YAMLError, UnicodeError) as exc:
        raise ValueError('Checkov policy has invalid YAML or encoding') from exc
    if data is None:
        data = {}
    if not isinstance(data, dict):
        raise ValueError('Checkov policy must be a mapping')
    booleans = {'deep-analysis', 'evaluate-variables', 'skip-download',
                'download-external-modules', 'quiet', 'compact'}
    lists = {'framework', 'skip-framework', 'skip-check', 'skip-path', 'output'}
    # Configs written by earlier setup releases carry output-file-path. The caller owns
    # output, so drop it rather than rejecting every existing consumer config.
    if isinstance(data.get('output-file-path'), str):
        data.pop('output-file-path')
    if isinstance(data.get('output'), str):
        data['output'] = [data['output']]
    for key, value in data.items():
        if key in booleans and type(value) is bool:
            if key == 'download-external-modules' and value:
                raise ValueError('Checkov policy must disable external module downloads')
            continue
        if key in lists and isinstance(value, list) and all(isinstance(item, str) for item in value):
            if key == 'output' and any(item not in ('cli', 'json', 'sarif', 'junitxml', 'github_failed_only') for item in value):
                raise ValueError('Checkov policy has an unsupported output format')
            continue
        raise ValueError(f'Checkov policy option is not passive or has an invalid value: {key}')
    # The caller owns output and scanner control flags. Always supply an explicit
    # file, even with no policy, so Checkov cannot discover a different config.
    data.pop('output', None)
    data.update({'download-external-modules': False, 'skip-download': True})
    return data


@contextmanager
def prepared_policy(source=None):
    import yaml
    data = passive_policy(source)
    with tempfile.TemporaryDirectory(prefix='scan-checkov-') as directory:
        path = Path(directory) / 'policy.yaml'
        path.write_text(yaml.safe_dump(data), encoding='utf-8')
        yield path


if __name__ == '__main__':
    import yaml
    try:
        # Shell wrappers invoke this only to write into their own private temp dir.
        print(yaml.safe_dump(passive_policy(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None)), end='')
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f'Checkov policy rejected: {exc}', file=sys.stderr)
        raise SystemExit(1)
