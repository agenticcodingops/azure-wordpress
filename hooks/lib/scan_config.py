"""Validate configuration shapes before hook code reads optional values."""
from pathlib import Path
import sys


def require(value, kind, key):
    if not isinstance(value, kind):
        expected = {dict: 'a mapping', list: 'a list', str: 'a string', bool: 'a boolean'}[kind]
        raise ValueError(f'{key} must be {expected}')
    return value


def load_yaml(path):
    import yaml
    try:
        value = yaml.safe_load(Path(path).read_text(encoding='utf-8'))
    except (yaml.YAMLError, UnicodeError) as exc:
        raise ValueError(f'{Path(path).name}: invalid YAML or encoding') from exc
    return require(value, dict, f'{Path(path).name}.<root>')


def load_scan_config(path):
    """Check every shape consumed by the push runner and shared config readers.

    Missing optional keys retain defaults; present nulls/scalars/containers of the
    wrong type are errors, even when a different key would disable scanning.
    """
    config = load_yaml(path)
    global_config = require(config.get('global', {}), dict, 'global')
    for section, prefix in ((config, ''), (global_config, 'global.')):
        if 'local_hooks_enabled' in section:
            require(section['local_hooks_enabled'], bool, prefix + 'local_hooks_enabled')
    languages = require(config.get('languages', {}), dict, 'languages')
    for name, language in languages.items():
        key = f'languages.{name}'
        require(language, dict, key)
        build = require(language.get('build', {}), dict, key + '.build')
        for field in ('working_dir', 'solution'):
            if field in build:
                require(build[field], str, key + '.build.' + field)
    return config


def read_value(config, key, default):
    current = config
    parts = key.split('.')
    for index, part in enumerate(parts):
        require(current, dict, '.'.join(parts[:index]) or '<root>')
        if part not in current:
            return default
        current = current[part]
    if key == 'languages.csharp.enabled':
        require(current, bool, key)
        return str(current).lower()
    require(current, str, key)
    return current if current else default


if __name__ == '__main__':
    try:
        key, filename = sys.argv[1:3]
        # Windows PowerShell omits empty native arguments; default is optional.
        default = sys.argv[3] if len(sys.argv) > 3 else ''
        print(read_value(load_scan_config(filename), key, default))
    except (OSError, ValueError, ImportError) as exc:
        print('[scan-config] ERROR: ' + ' '.join(str(exc).splitlines()), file=sys.stderr)
        raise SystemExit(1)
