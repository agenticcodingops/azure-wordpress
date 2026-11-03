#!/usr/bin/env python3
"""Use the same suppression contract locally and in CI."""
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("_validator", Path(__file__).resolve().parents[1] / "scripts/validate-suppressions.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
parse_iso_date = validator.parse_iso_date

def validate_suppressions(file_path, strict=False, check_expiry=False, allow_legacy=False):
    result = validator.validate_file(file_path, strict, check_expiry, allow_legacy=allow_legacy)
    return ([f"{e['rule']}: {e['message']}" for e in result.errors],
            [f"{e['rule']}: {e['message']}" for e in result.warnings])

if __name__ == "__main__":
    validator.main()
