#!/usr/bin/env python3
"""Export ABI arrays from the pinned Foundry build, or compare them without modifying files."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for contract in ("LaunchToken", "GridMining"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{contract}.sol:{contract}", "abi", "--json"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        content = json.dumps(json.loads(result.stdout), indent=2) + "\n"
        target = root / "docs" / "abi" / f"{contract}.json"
        if args.check:
            if not target.exists() or target.read_text() != content:
                raise SystemExit(f"Stale or missing ABI: {target.relative_to(root)}")
            print(f"Verified {target.relative_to(root)}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)
            print(f"Exported {target.relative_to(root)}")


if __name__ == "__main__":
    main()
