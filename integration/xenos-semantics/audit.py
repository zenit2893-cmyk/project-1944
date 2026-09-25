#!/usr/bin/env python3
"""Print the recorded COD3 Xenos semantic audit as JSON.

The command reads only the prepared corpus, inventory reports, XenosRecomp
artifacts, and the isolated semantic model. It does not open the ISO, launch a
game, or alter the active compiler/runtime trees.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from xenos_semantics import audit_workspace


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="workspace root containing analysis/ and docs/")
    args = parser.parse_args()
    result = audit_workspace(args.root)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

