"""Write a schema 2.0 baseline with the same identity used by the gate."""
import json
from pathlib import Path
import sys
from safe_io import write_text
from scan_policy import occurrence_fingerprint, scanner_path


def finalize(data, root):
    data["schema_version"] = "2.0"
    # Keep repeated records: each entry authorizes one occurrence only.
    for entry in data["entries"]:
        entry["file"] = scanner_path(entry["file"], entry["tool"], root,
                                     entry.pop("scan_directory", data.get("scan_directory", ".")))
        entry["fingerprint"] = occurrence_fingerprint(entry, root)
        if not entry["fingerprint"]:
            raise ValueError("Baseline entry needs a readable source file and exact location")
        entry.pop("hash", None)
    return data


if __name__ == "__main__":
    source, destination, root = sys.argv[1:]
    data = json.loads(Path(source).read_text(encoding="utf-8-sig"))
    write_text(destination, json.dumps(finalize(data, root), indent=2) + "\n")
