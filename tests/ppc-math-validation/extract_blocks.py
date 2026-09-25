"""Extract real emitted CoD3 instruction blocks; do not change guest files."""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
GENERATED = ROOT / "cod3-pc/generated"
OUT = Path(__file__).resolve().parent

SPECS = [
    ("vmadd", "cod3_pc_recomp.0.cpp", "vmaddfp v12,v2,v10,v9", "PPCVRegister a, PPCVRegister b, PPCVRegister c", "ctx.v2 = a; ctx.v10 = b; ctx.v9 = c;", "ctx.v12", True),
    ("dot3", "cod3_pc_recomp.10.cpp", "vmsum3fp128 v13,v13,v0", "PPCVRegister a, PPCVRegister b", "ctx.v13 = a; ctx.v0 = b;", "ctx.v13", True),
    ("half4_alias", "cod3_pc_recomp.1.cpp", "vpkd3d128 v0,v0,5,2,2", "PPCVRegister a", "ctx.v0 = a;", "ctx.v0", True),
    ("half2_alias", "cod3_pc_recomp.35.cpp", "vpkd3d128 v0,v0,3,2,2", "PPCVRegister a", "ctx.v0 = a;", "ctx.v0", True),
    ("half2_distinct", "cod3_pc_recomp.53.cpp", "vpkd3d128 v0,v1,3,1,3", "PPCVRegister a, PPCVRegister initial", "ctx.v1 = a; ctx.v0 = initial;", "ctx.v0", True),
    ("pack_unsigned_alias", "cod3_pc_recomp.20.cpp", "vpkuhus v0,v0,v13", "PPCVRegister a, PPCVRegister b", "ctx.v0 = a; ctx.v13 = b;", "ctx.v0", True),
    ("fctidz", "cod3_pc_recomp.0.cpp", "fctidz f0,f0", "double a", "ctx.f0.f64 = a;", "ctx.f0.s64", False),
    ("frsp", "cod3_pc_recomp.13.cpp", "frsp f13,f0", "double a", "ctx.f0.f64 = a;", "ctx.f13.f64", False),
]

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", action="store_true")
    args = parser.parse_args()
    metadata = []
    code = ["// Automatically extracted from real generated CoD3 C++.",
            "// BSD-3-Clause ReXGlue generated patterns; see integration/ppc-math-validation/LICENSE.rexglue.",
            "// Synthetic inputs only. No game assets, game execution, or dispatcher required.",
            "#pragma once", "#include <rex/ppc/context.h>", "#include <cmath>", "#include <climits>",
            "namespace actual {"]
    specs = list(SPECS)
    for path in sorted((GENERATED / "default").glob("*.cpp")):
        text = path.read_text(encoding="utf-8")
        found = re.search(r"\t// (vmsum4fp128 v(\d+),v(\d+),v(\d+))\n", text)
        if found and found[3] != found[4]:
            specs.append(("dot4", path.name, found[1], "PPCVRegister a, PPCVRegister b",
                          f"ctx.v{found[3]} = a; ctx.v{found[4]} = b;", f"ctx.v{found[2]}", True))
            break
    if len(specs) != len(SPECS) + 1:
        raise RuntimeError("Distinct-source dot4 sample not found")
    for name, filename, instruction, parameters, inputs, result, vector in specs:
        path = GENERATED / "default" / filename
        text = path.read_text(encoding="utf-8")
        marker = "\t// " + instruction + "\n"
        start = text.index(marker)
        stop = text.find("\t// ", start + len(marker))
        if stop < 0:
            raise RuntimeError(f"Cannot determine block end: {instruction}")
        block = text[start:stop].rstrip()
        if "\n}" in block or "\nloc_" in block or "REX_" in block:
            raise RuntimeError(f"Unexpected control flow or memory in block: {instruction}")
        containing = re.findall(r"DEFINE_REX_FUNC\(([^)]+)\)", text[:start])[-1]
        line = text[:start].count("\n") + 1
        metadata.append({"name": name, "file": str(path.relative_to(ROOT)).replace("\\", "/"),
                         "line": line, "instruction": instruction, "function": containing,
                         "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                         "block_sha256_lf": hashlib.sha256(block.encode()).hexdigest()})
        typ = "PPCVRegister" if vector else ("double" if name == "frsp" else "int64_t")
        mode = "enable" if vector else "disable"
        code += [f"// {path.relative_to(ROOT)}:{line} {containing}",
                 f"__declspec(noinline) inline {typ} {name}({parameters}) {{",
                 "  PPCContext ctx{}; PPCRegister temp{}; PPCVRegister vTemp{};",
                 "  ctx.fpscr.InitHost();",
                 f"  ctx.fpscr.{mode}FlushModeUnconditional();", f"  {inputs}", block,
                 f"  return {result};", "}"]
    code.append("}  // namespace actual")
    (OUT / "actual_generated_blocks.h").write_text("\n".join(code) + "\n", encoding="utf-8")
    (OUT / "actual_blocks.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    if args.inventory:
        inventory = []
        wanted = re.compile(r"\t// ((?:f(?:madd|madds|m?sub|ctid|ctidz|ctiw|ctiwz|rsp|res|rsqrte)|mtfsf|mtfsfi|mffs|v(?:maddfp|maddcfp128|nmsubfp|msum3fp128|msum4fp128|pkd3d128|pkuhus|pkuwus|rfin|addfp))\w*)\s+(.*)")
        for module in sorted(p for p in GENERATED.iterdir() if p.is_dir()):
            counts = collections.Counter()
            pack_forms = collections.Counter()
            alias_packs = collections.Counter()
            for path in module.glob("*.cpp"):
                for match in wanted.finditer(path.read_text(encoding="utf-8")):
                    op, operands = match.groups()
                    counts[op] += 1
                    parts = operands.strip().split(",")
                    if op == "vpkd3d128":
                        pack_forms[",".join(parts[2:])] += 1
                        if parts[0] == parts[1]:
                            alias_packs[op + " " + ",".join(parts[2:])] += 1
                    elif op in ("vpkuhus", "vpkuwus") and parts[0] in parts[1:]:
                        alias_packs[op] += 1
            inventory.append({"module": module.name, "static_instruction_counts": dict(counts),
                              "vpkd3d128_type_mask_shift": dict(pack_forms),
                              "packing_destination_aliases_source": dict(alias_packs)})
        (OUT / "instruction_inventory.json").write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"extracted_instruction_blocks": len(metadata), "inventory_written": args.inventory}))

if __name__ == "__main__":
    main()
