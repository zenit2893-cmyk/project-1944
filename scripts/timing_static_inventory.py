"""Inventory exact, unmodified COD3/ReXGlue timing code for later manual review.

This does not infer a gameplay timestep, select hooks, or write guest memory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--generated", type=Path,
                        help="generated ReXGlue default-module directory; defaults to initial cod3 evidence")
    args = parser.parse_args()
    root = args.root.resolve()
    generated = (args.generated or root / "cod3/generated/default").resolve()
    image_path = root / "analysis/title-default-image.bin"
    image = image_path.read_bytes()
    base = 0x82000000
    addresses = {
        "pmove_msec": 0x82065B68, "timescale": 0x82066288,
        "com_maxfps": 0x82068764, "fixedtime": 0x82068798,
        "sv_framerate_smoothing": 0x82069AC8, "pmove_fixed": 0x820788E8,
    }
    anchors = []
    for name, address in addresses.items():
        offset = address - base
        found = image[offset:offset + len(name) + 1]
        anchors.append({"name": name, "address": f"0x{address:08X}",
                        "nul_terminated_bytes_match": found == name.encode("ascii") + b"\0",
                        "scope": "Verified string bytes only; live variable value is unknown."})
    sites = []
    function = None
    function_line = None
    tokens = ("REX_QUERY_TIMEBASE()", "__imp__KeQueryPerformanceFrequency(ctx",
              "__imp__KeQuerySystemTime(ctx", "__imp__KeDelayExecutionThread(ctx",
              "sub_82345740(ctx", "sub_82345708(ctx")
    for path in sorted(generated.glob("*_recomp.*.cpp")):
        text = path.read_text(encoding="utf-8")
        sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
        for number, line in enumerate(text.splitlines(), 1):
            match = re.match(r"DEFINE_REX_FUNC\(([^)]+)\)", line)
            if match:
                function, function_line = match.group(1), number
            if any(token in line for token in tokens):
                sites.append({"generated_file": str(path.relative_to(root)),
                              "source_text_sha256": sha, "line": number,
                              "function": function, "function_line": function_line,
                              "expression": line.strip(),
                              "scope": "Static generated call/instruction; dynamic frequency unknown."})
    report = {
        "schema": "cod3-static-timing-evidence-v1", "target_project": "cod3-pc",
        "state": "STATIC_EVIDENCE_ONLY", "gameplay_120fps_verified": False,
        "baseline_render_hz": None, "baseline_simulation_hz": None,
        "xex_sha256": hashlib.sha256((root / "game/cod3/default.xex").read_bytes()).hexdigest(),
        "pristine_loaded_image_sha256": hashlib.sha256(image).hexdigest(),
        "generated_evidence_directory": str(generated),
        "sdk_commit": "0c7b01a0ac0479801757507d80533f662fa0815d",
        "anchors": anchors, "clock_sites": sites,
        "static_float_constants": [
            {"address": f"0x{address:08X}", "big_endian_f32": struct.unpack_from(
                ">f", image, address - base)[0]}
            for address in (0x8207C78C, 0x8207C614)
        ],
        "manually_reviewed_control_flow": [
            {"function": "0x82345740", "behavior": "Writes mftb-derived timebase to r3 pointer; returns1.",
             "source": "cod3/generated/default/cod3_recomp.37.cpp:17548"},
            {"function": "0x82345708", "behavior": "Writes KeQueryPerformanceFrequency to r3 pointer; returns1.",
             "source": "cod3/generated/default/cod3_recomp.72.cpp:17370"},
            {"function": "0x825372E8", "behavior": "Passes com_maxfps and default string0 to8252BBE0; saves pointer at829C2514. Registers timescale with string1 and fixedtime with string0.",
             "source": "cod3/generated/default/cod3_recomp.54.cpp:32500"},
            {"function": "0x82536DD0", "behavior": "Reads com_maxfps integer at cvar+32; if positive, integer-divides1000 by it, else threshold1. Repeatedly calls event-pump82535E80 until time delta reaches threshold. Calls825298D8, converts result with f32~0.001, passes result to multiple subsequent subsystems.",
             "source": "cod3/generated/default/cod3_recomp.89.cpp:32712"},
            {"function": "0x825298D8", "behavior": "Uses fixedtime when nonzero, otherwise scales input integer by timescale f32 when nonzero; caps result at100, with additional zero/pause paths.",
             "source": "cod3/generated/default/cod3_recomp.51.cpp:30212"},
            {"function": "0x8256C260", "behavior": "Reads value at82A0D9CC, branches below8 or above33 to set pmove_msec using literal8/33. Conditional ceil(time/value)*value follows. Role in actual player simulation still needs a live trace.",
             "source": "cod3/generated/default/cod3_recomp.28.cpp:31322"},
            {"function": "0x82468510", "behavior": "Reads timebase wrapper82127800, subtracts saved origin, converts and multiplies by f32 at8207C78C (~1/50000), truncates to integer. Strong static evidence of guest milliseconds at50MHz.",
             "source": "cod3/generated/default/cod3_recomp.36.cpp:26168"},
        ],
        "notes": ["Initial ReXGlue codegen remains evidence for the same XEX while cod3-pc is integrated.",
                  "Do not reuse public patch addresses unless its expected binary/hash gate is reconciled.",
                  "Clock wrappers are shared by multiple subsystems and are not safe FPS-only hooks."]}
    output = root / "analysis/timing-native-evidence.json"
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(output), "matching_string_anchors": sum(
        anchor["nul_terminated_bytes_match"] for anchor in anchors), "clock_sites": len(sites),
        "state": report["state"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
