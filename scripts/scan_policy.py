"""Shared occurrence identity and exception matching for local scans and CI.

Policy directories are supplied separately from the source tree. CI must supply
the protected base checkout; local scans use the repository containing the input.
"""
from collections import Counter
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

FINGERPRINT = re.compile(r"^v1:[0-9a-f]{64}$")

# Tokenize only enough HCL to associate real comments with top-level definitions.
# Strings and heredocs are opaque: text in them must never authorize a skip.
HCL_HEREDOC_PATTERN = (r'<<(?P<indented>-)?(?P<tag>[^\W\d][\w-]*)[^\n]*\n'
                       r'.*?^(?(indented)[ \t]*)(?P=tag)[ \t]*(?=\n|$)')
HCL_COMMENT = re.compile(r'\#[^\n]*|//[^\n]*|/\*.*?\*/', re.DOTALL)
HCL_TOKEN = re.compile(HCL_HEREDOC_PATTERN +
    r'|"(?:\\.|[^"\\])*"|\#[^\n]*|//[^\n]*|/\*.*?\*/|[\w-]+|[^\s]',
    re.MULTILINE | re.DOTALL)
INLINE_SKIP = re.compile(r'^(?:\#|//)\s*checkov:skip=([A-Za-z0-9_]+)(?::(.*))?$')


def hcl_string_end(text, start):
    """Skip a quoted template; reject unsupported or unterminated literals."""
    position, expressions = start + 1, []
    while position < len(text):
        character = text[position]
        if expressions:
            opaque = HCL_COMMENT.match(text, position)
            if opaque:
                position = opaque.end()
                continue
            if text.startswith('<<', position):
                raise ValueError('Heredoc inside a template expression is unsupported')
        if character == '\\':
            position += 2
            continue
        if not expressions:
            if text[position:position + 3] in ('$${', '%%{'):
                position += 3
                continue
            if character == '"':
                return position + 1
            if text[position:position + 2] in ('${', '%{'):
                expressions.append(1)
                position += 2
                continue
        elif character == '"':
            position = hcl_string_end(text, position)
            continue
        elif character == '{':
            expressions[-1] += 1
        elif character == '}':
            expressions[-1] -= 1
            if expressions[-1] == 0:
                expressions.pop()
        position += 1
    raise ValueError('Unterminated quoted template')


def terraform_inline_skips(text, module_sources=None):
    """Index (check ID, justification) by definition address, never by line number.

    Unknown/ambiguous definitions cannot grant approval. Unsupported template
    nesting invalidates the entire file, including previously indexed approvals.
    This does not infer exceptions from other IaC formats or string contents.
    """
    definitions, header = {}, []
    text = text.replace('\r\n', '\n')
    depth, address, skips, consumed = 0, None, set(), 0
    module_source, source_state, source_count = None, 0, 0
    for match in HCL_TOKEN.finditer(text):
        if match.start() < consumed:
            continue
        token = match.group()
        # The heredoc regex cannot model interpolations or nested terminators.
        # Conservatively reject template openers (even escaped ones) in heredocs.
        if ((token == '<' and text.startswith('<<', match.start())) or
                (token.startswith('<<') and ('${' in token or '%{' in token))):
            if module_sources is not None:
                module_sources.clear()
            return {}
        if token.startswith('"'):
            try:
                consumed = hcl_string_end(text, match.start())
            except (ValueError, RecursionError):
                if module_sources is not None:
                    module_sources.clear()
                return {}
            token = text[match.start():consumed]
        if token.startswith(('#', '//', '/*')):
            skip = INLINE_SKIP.fullmatch(token)
            if address and skip:
                skips.add((skip[1], (skip[2] or '').strip()))
            continue
        if token == '{':
            if depth == 0:
                address, skips = None, set()
                module_source, source_state, source_count = None, 0, 0
                if ((len(header) == 3 and header[0] in ('resource', 'data')) or
                        (len(header) == 2 and header[0] == 'module')):
                    try:
                        labels = [json.loads(label) for label in header[1:]]
                        if all(isinstance(label, str) for label in labels):
                            address = '.'.join(labels)
                            if header[0] == 'data':
                                address = 'data.' + address
                            elif header[0] == 'module':
                                address = 'module.' + address
                    except ValueError:
                        pass
                header = []
            depth += 1
        elif token == '}':
            depth -= 1
            if depth < 0:
                return {}
            if depth == 0 and address:
                # Duplicate addresses are invalid and must not share approval.
                definitions[address] = None if address in definitions else skips
                if module_sources is not None and address.startswith('module.'):
                    name = address[len('module.'):]
                    module_sources[name] = (module_source if source_count == 1 and name not in module_sources else None)
                address = None
        elif depth == 0:
            header.append(token)
        elif depth == 1 and address and address.startswith('module.'):
            if token == 'source':
                source_state = 1
            elif source_state == 1 and token == '=':
                source_state = 2
            elif source_state == 2:
                source_count += 1
                try:
                    module_source = json.loads(token)
                except ValueError:
                    module_source = None
                source_state = 0
            else:
                source_state = 0
    if depth and module_sources is not None:
        module_sources.clear()
    return {} if depth else definitions


def local_inline_base(source_root):
    """Use the current remote default commit, never the PR tip or an older fork."""
    try:
        for ref in ('refs/remotes/origin/HEAD', 'refs/remotes/origin/main'):
            result = subprocess.run(['git', '-C', str(source_root), 'rev-parse', '--verify', ref + '^{commit}'],
                                    capture_output=True, text=True)
            if result.returncode == 0:
                return result.stdout.strip()
    except OSError:
        pass
    return None


def git_source_prefix(source_root):
    """Git object paths stay repository-relative even with a nested policy root."""
    try:
        result = subprocess.run(['git', '-C', str(source_root), 'rev-parse', '--show-prefix'],
                                capture_output=True)
        if result.returncode == 0:
            return result.stdout.decode('utf-8').rstrip('\r\n')
    except (OSError, UnicodeError):
        pass
    return None


def module_resource_address(resource, source_file, source_root, scan_directory, read_trusted, list_trusted, module_cache,
                            caller_file=None):
    """Resolve local module instances only through matching trusted source chains.

    A new/renamed call address or changed module source cannot borrow a declaration's
    approval. Traversal through dynamic, remote or ambiguous sources fails closed.
    Module-block approvals bind the literal source without traversing its target.
    """
    match = re.fullmatch(r'(?P<modules>(?:module\.[\w-]+(?:\[[^\]]+\])?\.)+)'
                         r'(?P<resource>(?:data\.)?[\w-]+\.[\w-]+|[\w-]+)(?:\[[^\]]+\])?', resource)
    call = None
    if not match:
        # Module policies use a bare call name, including evaluated instance keys.
        call = re.fullmatch(r'([\w-]+)(?:\[[^\]]+\])?', resource)
        if not call:
            declaration = re.fullmatch(r'((?:data\.)?[\w-]+\.[\w-]+)(?:\[[^\]]+\])?', resource)
            return declaration[1] if declaration else resource

    def module_sources(directory, trusted):
        directory.relative_to(source_root)
        key = directory, trusted
        if key not in module_cache:
            modules = {}
            paths = (source_root / relative for relative in list_trusted(directory)) if trusted else directory.glob('*.tf')
            for path in paths:
                path.resolve().relative_to(source_root)
                relative = path.relative_to(source_root).as_posix()
                content = read_trusted(relative) if trusted else path.read_text(encoding='utf-8')
                found = {}
                terraform_inline_skips(content or '', module_sources=found)
                for label, target in found.items():
                    modules[label] = None if label in modules else target
            module_cache[key] = modules
        return module_cache[key]

    def module_target(directory, trusted, name):
        source = module_sources(directory, trusted).get(name)
        if not isinstance(source, str) or not source.startswith(('./', '../')):
            return None
        target = (directory / source).resolve()
        target.relative_to(source_root)
        return target

    def unchanged_call(directory, name):
        current = module_sources(directory, False).get(name)
        trusted = module_sources(directory, True).get(name)
        # A block may explicitly approve a remote source, but never an inferred
        # or changed source. This does not authorize traversal into that module.
        return (isinstance(current, str) and bool(current) and
                '${' not in current and '%{' not in current and current == trusted)

    if call:
        return 'module.' + call[1] if unchanged_call(source_file.parent, call[1]) else None

    scan_root = (source_root / scan_directory).resolve()
    scan_root.relative_to(source_root)
    names = re.findall(r'module\.([\w-]+)(?:\[[^\]]+\])?\.', match['modules'])
    # A directory scan can discover root modules below its starting directory.
    # The reported immediate caller anchors the last hop, while the full address
    # still requires every preceding call/source to exist in both trees.
    if caller_file is not None:
        caller_file.relative_to(source_root)
        if caller_file.suffix != '.tf' or not caller_file.is_file():
            return None
        caller_key = 'caller', caller_file
        if caller_key not in module_cache:
            caller_sources = {}
            terraform_inline_skips(caller_file.read_text(encoding='utf-8'), module_sources=caller_sources)
            module_cache[caller_key] = caller_sources
        if names[-1] not in module_cache[caller_key]:
            return None
        if 'roots' not in module_cache:
            module_cache['roots'] = {path.parent.resolve() for path in scan_root.rglob('*.tf')}
        roots = module_cache['roots']
    else:
        roots = {scan_root}
    resolved = []
    for root in roots:
        try:
            directory = root
            approved = True
            for index, name in enumerate(names):
                if index == len(names) - 1 and caller_file is not None and caller_file.parent != directory:
                    break
                sources = module_sources(directory, False)
                if name not in sources:
                    break
                source = sources[name]
                if (not isinstance(source, str) or not source or
                        '${' in source or '%{' in source):
                    resolved.append(False)
                    break
                if source.startswith(('./', '../')):
                    current = module_target(directory, False, name)
                elif Path(source).is_absolute():
                    # Count an absolute current chain for ambiguity, but the
                    # local-only trusted resolver can never approve that hop.
                    current = Path(source).resolve()
                    current.relative_to(source_root)
                else:
                    # An unresolvable alternative cannot borrow the identity of
                    # a verified chain (for example through a cached module).
                    resolved.append(False)
                    break
                try:
                    trusted = module_target(directory, True, name)
                except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError):
                    trusted = None
                approved = approved and current == trusted
                directory = current
            else:
                if directory == source_file.parent:
                    if '.' not in match['resource']:
                        try:
                            approved = approved and unchanged_call(directory, match['resource'])
                        except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError):
                            approved = False
                    # Count current chains even if they lack base approval: the
                    # scanner identity cannot distinguish a new duplicate root.
                    resolved.append(approved)
        except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError):
            # An unsafe/unreadable candidate cannot approve anything, but must
            # not veto an independent, fully verified chain in another root.
            continue
    declaration = match['resource']
    if '.' not in declaration:
        declaration = 'module.' + declaration
    return declaration if len(resolved) == 1 and resolved[0] else None


def checkov_checks(results, source_root, policy_root=None, scan_directory='.', allow_inline=False,
                   base_commit=None):
    """Keep failed/new skips; honour only identical trusted-base inline skips.

    CI supplies a separate base checkout. Local scans without that checkout read
    the remote default tip from Git objects so worktree/PR edits cannot approve themselves.
    Missing source/base identity fails closed by retaining the skipped finding.
    """
    pending = list(results.get('failed_checks', []))
    if allow_inline:
        return pending
    source_root = Path(source_root).resolve()
    if not results.get('skipped_checks'):
        return pending
    if policy_root is None and base_commit is None:
        base_commit = local_inline_base(source_root)
    prefix = git_source_prefix(source_root)
    trusted_cache = {}
    def list_trusted(directory):
        relative = directory.relative_to(source_root)
        git_directory = (prefix or '') + (relative.as_posix() + '/' if relative.parts else '')
        if policy_root is not None:
            base_root = Path(policy_root).resolve()
            base_directory = (base_root / git_directory).resolve()
            base_directory.relative_to(base_root)
            return [(relative / path.name).as_posix() for path in base_directory.glob('*.tf')]
        if not base_commit or prefix is None:
            return []
        result = subprocess.run(['git', '-C', str(source_root), 'ls-tree', '-r', '-z',
                                 '--name-only', '--full-tree', base_commit, '--', ':(top)' + git_directory],
                                check=True, capture_output=True)
        # Git -z preserves raw filenames. Unrelated paths must not invalidate
        # approval merely because their names cannot be decoded as UTF-8.
        directory_bytes = git_directory.rstrip('/').encode('utf-8')
        names = []
        for raw in result.stdout.split(b'\0'):
            parent, _, filename = raw.rpartition(b'/')
            if parent == directory_bytes and filename.endswith(b'.tf') and len(filename) > 3:
                names.append(raw.decode('utf-8')[len(prefix):])
        return names
    def read_trusted(relative):
        """Read the corresponding repository path from the trusted base only."""
        git_relative = (prefix or '') + relative
        if relative in trusted_cache:
            return trusted_cache[relative]
        content = None
        if policy_root is not None:
            base_root = Path(policy_root).resolve()
            base = (base_root / git_relative).resolve()
            base.relative_to(base_root)
            content = base.read_text(encoding='utf-8') if base.is_file() else None
        elif base_commit and prefix is not None:
            result = subprocess.run(['git', '-C', str(source_root), 'show',
                                     f'{base_commit}:{git_relative}'], capture_output=True)
            if result.returncode == 0:
                content = result.stdout.decode('utf-8')
        trusted_cache[relative] = content
        return content
    cache, module_cache = {}, {}
    for check in results.get('skipped_checks', []):
        relative = scanner_path(check.get('file_path', ''), 'checkov', source_root, scan_directory)
        if relative not in cache:
            current, trusted = {}, {}
            try:
                source = (source_root / relative).resolve()
                source.relative_to(source_root)
                if source.suffix == '.tf':
                    current = terraform_inline_skips(source.read_text(encoding='utf-8'))
                    trusted = terraform_inline_skips(read_trusted(relative) or '')
            except (OSError, ValueError, UnicodeError):
                pass
            cache[relative] = current, trusted
        current, trusted = cache[relative]
        resource = check.get('resource', '')
        try:
            caller = check.get('caller_file_path')
            caller_file = ((source_root / scanner_path(caller, 'checkov', source_root, scan_directory)).resolve()
                           if caller else None)
            resource = module_resource_address(resource, (source_root / relative).resolve(),
                                               source_root, scan_directory, read_trusted, list_trusted, module_cache,
                                               caller_file=caller_file)
        except (OSError, ValueError, UnicodeError, subprocess.CalledProcessError):
            resource = None
        current_reasons = {reason for rule, reason in current.get(resource) or set()
                           if rule == check.get('check_id')}
        trusted_reasons = {reason for rule, reason in trusted.get(resource) or set()
                           if rule == check.get('check_id')}
        if not current_reasons or current_reasons != trusted_reasons:
            pending.append(check)
    return pending


def scanner_path(raw, tool, source_root=".", scan_directory="."):
    """Convert scanner-specific paths to a repository-relative path."""
    root = Path(source_root).resolve()
    value = str(raw)
    if os.name == "nt":
        value = value.replace("\\", "/")
    if value.startswith("/github/workspace/"):
        value = value[len("/github/workspace/"):]
    context = (root / scan_directory).resolve()
    candidate = root / value
    if tool == "checkov" and value.startswith("/") and not candidate.is_file():
        candidate = context / value.lstrip("/")
    elif not Path(value).is_absolute():
        context_relative = context.relative_to(root).as_posix()
        if context_relative != "." and not value.startswith(context_relative + "/"):
            candidate = context / value
    try:
        return candidate.resolve().relative_to(root).as_posix()
    except ValueError:
        return value


def source_path(finding, root):
    root = Path(root).resolve()
    value = str(finding.get("file", finding.get("file_path", "")))
    if os.name == "nt":
        value = value.replace("\\", "/")
    path = Path(value)
    # Checkov's file_path uses a leading slash for paths relative to its scan root.
    if finding.get("tool") == "checkov" and value.startswith("/") and not path.is_file():
        path = Path(value.lstrip("/"))
    path = (root / path).resolve()
    relative = path.relative_to(root).as_posix()
    return path, relative


def occurrence_fingerprint(finding, root="."):
    """Bind identity to tool, rule, repository path, resource, range and file bytes.

    A missing source file or location cannot authorize an exact exception.
    Entire-file content identity deliberately invalidates approval after edits.
    CRLF and LF checkouts share the same identity.
    """
    try:
        path, relative = source_path(finding, root)
        line = int(finding.get("line", 0))
        if line < 1 or not finding.get("rule_id") or not finding.get("tool"):
            return None
        content = path.read_bytes().replace(b"\r\n", b"\n")
        identity = dict(tool=finding["tool"], rule_id=finding["rule_id"],
                        file=relative, resource=str(finding.get("resource") or ""),
                        line=line, end_line=int(finding.get("end_line") or line),
                        content_sha256=hashlib.sha256(content).hexdigest())
        encoded = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        return "v1:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    except (OSError, ValueError, TypeError):
        return None


def suppression_file(policy_root):
    """Resolve the same configured registry for CI, hooks and scan.py."""
    import yaml
    root = Path(policy_root).resolve()
    config = root / "scan-config.yaml"
    name = ".scan-suppressions.yaml"
    if config.exists():
        data = yaml.safe_load(config.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("scan-config.yaml must be a mapping")
        section = data.get("suppressions", {})
        if section is None:
            section = {}
        if not isinstance(section, dict):
            raise ValueError("suppressions must be a mapping")
        name = section.get("file", name)
        if not isinstance(name, str) or not name.strip():
            raise ValueError("suppressions.file must be a non-empty path string")
    candidate = (root / name).resolve()
    candidate.relative_to(root)  # policy cannot name files outside its checkout
    return candidate


def load_suppression_entries(path, allow_legacy=False):
    import yaml
    path = Path(path)
    if not path.exists():
        return []
    spec = importlib.util.spec_from_file_location("_suppression_validator", Path(__file__).with_name("validate-suppressions.py"))
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    result = validator.validate_file(path, ci_mode=True, allow_legacy=allow_legacy)
    if result.has_errors:
        raise ValueError("Invalid suppression registry: " + "; ".join(e["message"] for e in result.errors))
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return [entry for section in validator.TOOL_SECTIONS.values() for entry in (data.get(section) or [])]


def baseline_keys(path, allow_legacy=False):
    path = Path(path)
    if not path.exists():
        return Counter()
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        raise ValueError("Invalid baseline report")
    legacy = str(data.get("schema_version")) == "1.0"
    if str(data.get("schema_version")) != "2.0" and not (allow_legacy and legacy):
        raise ValueError("Baseline schema 2.0 required; regenerate the baseline")
    keys = Counter()
    for entry in data["entries"]:
        key = entry.get("hash") if legacy else entry.get("fingerprint")
        if not isinstance(key, str) or (not legacy and not FINGERPRINT.fullmatch(key)):
            raise ValueError("Invalid baseline occurrence fingerprint")
        keys[key] += 1
    return keys


def apply_exceptions(findings, source_root, policy_root, suppressions=True, baseline=True, allow_legacy=False):
    """Consume each approved occurrence once, retaining all finding records."""
    entries = load_suppression_entries(suppression_file(policy_root), allow_legacy) if suppressions else []
    remaining = list(entries)
    keys = baseline_keys(Path(policy_root) / ".scan-baseline/baseline.json", allow_legacy) if baseline else Counter()
    for finding in findings:
        fingerprint = occurrence_fingerprint(finding, source_root)
        finding["fingerprint"] = fingerprint
        finding["suppressed"] = finding["baseline"] = False
        for entry in remaining:
            if entry["rule_id"] != finding["rule_id"] or entry["tool"] != finding["tool"]:
                continue
            # Approval must cover the actual severity as well as the declared severity.
            if finding.get("severity") in ("HIGH", "CRITICAL") and not str(entry.get("approved_by") or "").strip():
                continue
            if entry.get("file_pattern"):
                try:
                    _, relative = source_path(finding, source_root)
                except (ValueError, OSError):
                    continue
                if not fnmatch.fnmatchcase(relative, entry["file_pattern"]):
                    continue
            if (fingerprint and entry.get("fingerprint") == fingerprint) or (allow_legacy and not entry.get("fingerprint")):
                finding["suppressed"] = True
                finding["suppression_reason"] = entry["reason"]
                remaining.remove(entry)
                break
        key = fingerprint
        if allow_legacy and not keys[key]:
            for reported_path in (finding.get("reported_file"), finding["file"]):
                if reported_path is None:
                    continue
                candidate = hashlib.sha256(f"{finding['rule_id']}|{reported_path}".encode()).hexdigest()
                if keys[candidate] > 0:
                    key = candidate
                    break
        if keys[key] > 0:
            finding["baseline"] = True
            keys[key] -= 1


if __name__ == "__main__":
    # Used by both shell wrappers to resolve suppressions.file without fallback
    # on parser/dependency errors.
    print(suppression_file(Path.cwd()))
