#!/usr/bin/env python3
"""Move each subcommand of json/<cmd>.json to json/<cmd>/<sub>.json, leaving a stub."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

STUB_KEYS = {"name", "description", "priority", "hidden"}


def split(path: Path) -> int:
    """split one spec file in place, return the number of files written"""
    spec = json.loads(path.read_text(encoding="utf-8"))
    out = path.with_suffix("")
    count = 0
    for sub in spec.get("subcommands") or []:
        name = sub.get("name")
        if isinstance(name, list):
            name = name[0] if name else None
        # the file name must be a safe single path component
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", name):
            continue
        if set(sub) <= STUB_KEYS:
            continue
        out.mkdir(exist_ok=True)
        (out / f"{name}.json").write_text(json.dumps(sub, indent=1) + "\n", encoding="utf-8")
        for key in set(sub) - STUB_KEYS:
            del sub[key]
        count += 1
    path.write_text(json.dumps(spec, indent=1) + "\n", encoding="utf-8")
    return count


def main() -> int:
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} SPEC.json...", file=sys.stderr)
        return 2
    for arg in sys.argv[1:]:
        path = Path(arg)
        print(f"{path}: {split(path)} subcommands moved to {path.with_suffix('')}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
