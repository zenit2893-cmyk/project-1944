"""Extract exact, isolated PPC/VMX blocks from generated CoD3 C++.

The output is test input only.  This script never edits cod3-pc/generated and
rejects a block if it contains control flow, memory access, or a call boundary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GENERATED = ROOT / "cod3-pc" / "generated" / "default"
OUT = Path(__file__).resolve().parent

# name, file, instruction marker, wrapper parameters, wrapper inputs, result,
# vector result.  The first eight entries are the same real CoD3 instruction
# sites used by the earlier validation harness; the final two cover unpack.
SPECS = [
    ("vmadd", "cod3_pc_recomp.0.cpp", "vmaddfp v12,v2,v10,v9",
     "PPCVRegister a, PPCVRegister b, PPCVRegister c",
     "ctx.v2 = a; ctx.v10 = b; ctx.v9 = c;", "ctx.v12", True),
    ("dot3", "cod3_pc_recomp.10.cpp", "vmsum3fp128 v13,v13,v0",
     "PPCVRegister a, PPCVRegister b", "ctx.v13 = a; ctx.v0 = b;",
     "ctx.v13", True),
    ("half4_alias", "cod3_pc_recomp.1.cpp", "vpkd3d128 v0,v0,5,2,2",
     "PPCVRegister a", "ctx.v0 = a;", "ctx.v0", True),
    ("half2_alias", "cod3_pc_recomp.35.cpp", "vpkd3d128 v0,v0,3,2,2",
     "PPCVRegister a", "ctx.v0 = a;", "ctx.v0", True),
    ("half2_distinct", "cod3_pc_recomp.53.cpp",
     "vpkd3d128 v0,v1,3,1,3",
     "PPCVRegister a, PPCVRegister initial",
     "ctx.v1 = a; ctx.v0 = initial;", "ctx.v0", True),
    ("pack_unsigned_alias", "cod3_pc_recomp.20.cpp", "vpkuhus v0,v0,v13",
     "PPCVRegister a, PPCVRegister b", "ctx.v0 = a; ctx.v13 = b;",
     "ctx.v0", True),
    ("fctidz", "cod3_pc_recomp.0.cpp", "fctidz f0,f0", "double a",
     "ctx.f0.f64 = a;", "ctx.f0.s64", False),
    ("frsp", "cod3_pc_recomp.13.cpp", "frsp f13,f0", "double a",
     "ctx.f0.f64 = a;", "ctx.f13.f64", False),
    ("dot4", "cod3_pc_recomp.1.cpp", "vmsum4fp128 v0,v0,v7",
     "PPCVRegister a, PPCVRegister b", "ctx.v0 = a; ctx.v7 = b;",
     "ctx.v0", True),
    ("unpack_half2_alias", "cod3_pc_recomp.23.cpp",
     "vupkd3d128 v0,v0,12", "PPCVRegister a", "ctx.v0 = a;", "ctx.v0",
     True),
    ("unpack_half4_alias", "cod3_pc_recomp.48.cpp",
     "vupkd3d128 v0,v0,20", "PPCVRegister a", "ctx.v0 = a;", "ctx.v0",
     True),
]


def extract_block(text: str, marker: str) -> tuple[str, int]:
    full_marker = "\t// " + marker + "\n"
    start = text.index(full_marker)
    stop = text.find("\t// ", start + len(full_marker))
    if stop < 0:
        raise RuntimeError(f"Cannot determine block end: {marker}")
    block = text[start:stop].rstrip()
    # A validation block must contain only the instruction and its generated
    # straight-line implementation.  This deliberately permits `if` guards
    # used by Xenos half unpacking while rejecting control flow and memory.
    if any(token in block for token in ("\n}", "\nloc_", "REX_", "ctx.r", "ctx.lr")):
        raise RuntimeError(f"Unexpected control flow, memory, or call in {marker}")
    return block, text[:start].count("\n") + 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", action="store_true")
    args = parser.parse_args()
    if not GENERATED.is_dir():
        raise RuntimeError(f"Generated CoD3 directory is missing: {GENERATED}")

    metadata: list[dict[str, object]] = []
    code = [
        "// Automatically extracted from exact generated CoD3 C++.",
        "// Synthetic inputs only; this header never executes game logic.",
        "#pragma once",
        "#include <rex/ppc/context.h>",
        "#include <cmath>",
        "#include <climits>",
        "namespace actual {",
    ]

    for name, filename, instruction, parameters, inputs, result, vector in SPECS:
        path = GENERATED / filename
        text = path.read_text(encoding="utf-8")
        block, line = extract_block(text, instruction)
        functions = re.findall(r"DEFINE_REX_FUNC\(([^)]+)\)", text[:text.index("\t// " + instruction)])
        if not functions:
            raise RuntimeError(f"Containing DEFINE_REX_FUNC not found for {instruction}")
        containing = functions[-1]
        metadata.append({
            "name": name,
            "file": path.relative_to(ROOT).as_posix(),
            "line": line,
            "instruction": instruction,
            "function": containing,
            "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "block_sha256_lf": hashlib.sha256(block.encode()).hexdigest(),
        })
        typ = "PPCVRegister" if vector else ("double" if name == "frsp" else "int64_t")
        mode = "enable" if vector else "disable"
        code += [
            f"// {path.relative_to(ROOT).as_posix()}:{line} {containing}",
            f"__declspec(noinline) inline {typ} {name}({parameters}) {{",
            "  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};",
            "  ctx.fpscr.InitHost();",
            f"  ctx.fpscr.{mode}FlushModeUnconditional();",
            f"  {inputs}",
            block,
            f"  return {result};",
            "}",
        ]

    code.append("}  // namespace actual")
    (OUT / "actual_generated_blocks.h").write_text("\n".join(code) + "\n", encoding="utf-8")
    (OUT / "actual_blocks.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    if args.inventory:
        inventory: list[dict[str, object]] = []
        wanted = re.compile(
            r"\t// ((?:f(?:madd|madds|m?sub|ctid|ctidz|ctiw|ctiwz|rsp|res|rsqrte)|"
            r"mtfsf|mtfsfi|mffs|v(?:maddfp|maddcfp128|nmsubfp|msum3fp128|"
            r"msum4fp128|pkd3d128|pkuhus|pkuwus|rfin|addfp))\w*)\s+(.*)"
        )
        for module in sorted(p for p in GENERATED.parent.iterdir() if p.is_dir()):
            counts: dict[str, int] = {}
            for path in module.glob("*.cpp"):
                for match in wanted.finditer(path.read_text(encoding="utf-8")):
                    op, _ = match.groups()
                    counts[op] = counts.get(op, 0) + 1
            inventory.append({"module": module.name, "static_instruction_counts": counts})
        (OUT / "instruction_inventory.json").write_text(
            json.dumps(inventory, indent=2) + "\n", encoding="utf-8"
        )
    print(json.dumps({"extracted_instruction_blocks": len(metadata), "inventory_written": args.inventory}))


if __name__ == "__main__":
    main()
