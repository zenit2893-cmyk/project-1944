#!/usr/bin/env python3
"""Stable command-line entry point for the COD3 original coroutine map.

The implementation and evidence schema live beside the report in
``analysis/cod3-allmodule-coroutine-sites.py``. This small launcher keeps the
analysis command discoverable under ``scripts/`` without duplicating any
reconstruction or signature logic.
"""
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
IMPLEMENTATION = ROOT / "analysis/cod3-allmodule-coroutine-sites.py"


def main():
    spec = importlib.util.spec_from_file_location("cod3_allmodule_coroutine_sites", IMPLEMENTATION)
    implementation = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(implementation)
    implementation.main()


if __name__ == "__main__":
    main()
