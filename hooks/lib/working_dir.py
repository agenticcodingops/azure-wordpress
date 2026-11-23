#!/usr/bin/env python3
"""Check languages.typescript.build.working_dir for the ESLint and Prettier hooks.

Reads NUL-delimited staged paths. Prints 'inside' if the configured directory exists
and holds one of them, 'outside' if it exists and holds none, and nothing if it does
not exist. Blank means the root, and ./, separators and letter case are tolerated.
This is only a check: selection and execution use the configured value unchanged.

It is a file, not a -c program, because Windows .cmd launchers cut arguments at a
newline. It reads the value itself, so the console encoding does not matter.
"""
import os
from pathlib import Path
import runpy
import sys

# Run the sibling from its source. Putting this directory on sys.path would also let
# a vendored yaml.py, or a planted bytecode cache, run during the scan.
_reader = runpy.run_path(str(Path(__file__).resolve().with_name('scan_config.py')))
load_scan_config, read_value = _reader['load_scan_config'], _reader['read_value']


def state(config, names):
    value = read_value(load_scan_config(config), 'languages.typescript.build.working_dir', '.')
    root = found = Path.cwd()
    for part in Path(value.strip().replace('\\', '/')).parts:
        step = found / part
        if not step.is_dir():
            step = next((p for p in found.iterdir() if p.name.lower() == part.lower() and p.is_dir()), None)
            if step is None:
                return ''
        found = step
    parents = {p for name in names for p in (root / os.fsdecode(name)).parents}
    return 'inside' if any(p.is_dir() and p.samefile(found) for p in parents) else 'outside'


if __name__ == '__main__':
    result = state(sys.argv[1], sys.stdin.buffer.read().split(b'\0'))
    if result:
        print(result)
