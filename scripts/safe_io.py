"""Writes reject linked path components, including Windows reparse points."""
import os
from pathlib import Path
import shutil
import stat
import tempfile


def assert_safe_path(path):
    path = Path(os.path.abspath(path))
    for part in (*reversed(path.parents), path):
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise OSError('Refusing a symlink or reparse point in output path')
    return path


def assert_safe_tree(path):
    path = assert_safe_path(path)
    if path.is_dir():
        for folder, dirs, files in os.walk(path, followlinks=False):
            for name in dirs + files:
                assert_safe_path(Path(folder) / name)
    return path


def write_text(path, text, encoding='utf-8'):
    path = assert_safe_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    assert_safe_path(path)
    descriptor, temporary = tempfile.mkstemp(prefix='.scan-write-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding=encoding) as stream:
            stream.write(text)
        assert_safe_path(path)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def append_text(path, text):
    path = assert_safe_path(path)
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(descriptor, 'a', encoding='utf-8') as stream:
        stream.write(text)


def copy_file(source, destination):
    assert_safe_path(source)
    destination = assert_safe_path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    write_text_bytes(source, destination)


def write_text_bytes(source, destination):
    descriptor, temporary = tempfile.mkstemp(prefix='.scan-copy-', dir=destination.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream, open(source, 'rb') as original:
            shutil.copyfileobj(original, stream)
        shutil.copystat(source, temporary)
        assert_safe_path(destination)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def copy_tree(source, destination):
    assert_safe_tree(source)
    assert_safe_tree(destination)
    for folder, dirs, files in os.walk(source):
        target = Path(destination) / Path(folder).relative_to(source)
        assert_safe_path(target).mkdir(parents=True, exist_ok=True)
        for name in files:
            copy_file(Path(folder) / name, target / name)
