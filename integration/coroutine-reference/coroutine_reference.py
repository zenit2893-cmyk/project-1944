#!/usr/bin/env python3
"""Independent interpreter for COD3's original coroutine frame instructions.

This module decodes the user's original PPC bytes; it does not import or call
the native coroutine bridge. It handles only the instructions in the verified
capture prefixes and restore tail and fails on anything else. Guest addresses
are 32-bit; GPR, LR, CTR and FPR payloads retain 64-bit values. Floating-point
loads/stores preserve raw bits without Python float conversions.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import importlib.util
import json
from pathlib import Path
import random
import struct

MASK64 = (1 << 64) - 1
FRAME_SIZE = 400
SAVED_SP_GLOBAL = 0x892552C4
API_SAVE_SLOT = 0x89255354
API_SAVE_TARGET = 0x824A24A0
SOURCE_XEX_HASHES = {
    "main": "2944EEC7D1231AD6798B5F9F8ADF8855F5E489296B22EAB45B27A577CEE23692",
    "saint_lo": "49E38A116B8F3C5E81C5206FD461496A6DA518CF9427843B38F2CAD33910EF2B",
}
SOURCE_IMAGE_HASHES = {
    "main": "9771B34A1A981350A24A9C1B0E72A5FBBBE0F2815D448A297B3D2989F32C263C",
    "saint_lo": "B9EC290DBF314955570EFCE7216E1F2209BCC5606A5F7277BF47ADD6E12048C3",
}
BLOCKS = {
    "restore": ("main", 0x82000000, 0x824A63AC, 0x824A6484,
                "A2CAA5B951D86CE5CDFDB4A42B6A398E81A185AB1EDD6A97F149F58A4B50797E"),
    "capture_wait": ("saint_lo", 0x89000000, 0x89190630, 0x8919073C,
                     "7D2D89493D62C6A88CEEE0A8787509A5AE6C741CB259FF85698E277E43DF19F5"),
    "capture_event": ("saint_lo", 0x89000000, 0x89190760, 0x8919086C,
                      "7D2D89493D62C6A88CEEE0A8787509A5AE6C741CB259FF85698E277E43DF19F5"),
}


def hex64(value: int) -> str:
    return f"0x{value & MASK64:016X}"


def sign_extend(value: int, bits: int) -> int:
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


@dataclass
class State:
    gpr: list[int] = field(default_factory=lambda: [0] * 32)
    fpr_bits: list[int] = field(default_factory=lambda: [0] * 32)
    vr_bits: list[int] = field(default_factory=lambda: [0] * 128)
    lr: int = 0
    ctr: int = 0
    cr: int = 0
    xer: int = 0
    fpscr: int = 0
    pc: int = 0

    def clone(self) -> State:
        return State(self.gpr.copy(), self.fpr_bits.copy(), self.vr_bits.copy(),
                     self.lr, self.ctr, self.cr, self.xer, self.fpscr, self.pc)

    def to_json(self) -> dict:
        return {"gpr": [hex64(v) for v in self.gpr],
                "fpr_bits": [hex64(v) for v in self.fpr_bits],
                "vr_bits": [f"0x{v:032X}" for v in self.vr_bits],
                "lr": hex64(self.lr), "ctr": hex64(self.ctr),
                "cr": f"0x{self.cr:08X}", "xer": hex64(self.xer),
                "fpscr": f"0x{self.fpscr:08X}", "pc": f"0x{self.pc:08X}"}


class Memory:
    """Small, strict sparse guest memory: every access must be pre-mapped."""
    def __init__(self):
        self.bytes: dict[int, int] = {}

    def map(self, address: int, data: bytes) -> None:
        for i, value in enumerate(data):
            self.bytes[(address + i) & 0xFFFFFFFF] = value

    def read_bytes(self, address: int, count: int) -> bytes:
        try:
            return bytes(self.bytes[(address + i) & 0xFFFFFFFF] for i in range(count))
        except KeyError as error:
            raise ValueError(f"Unmapped guest read at {error.args[0]:08X}") from error

    def read(self, address: int, width: int) -> int:
        return int.from_bytes(self.read_bytes(address, width), "big")

    def write(self, address: int, value: int, width: int) -> None:
        self.read_bytes(address, width)  # Validate the whole range before mutation.
        raw = (value & ((1 << (width * 8)) - 1)).to_bytes(width, "big")
        self.map(address, raw)

    def clone(self) -> Memory:
        result = Memory()
        result.bytes = self.bytes.copy()
        return result


def verify_stream(name: str, stream: bytes) -> None:
    _, _, start, end, expected_hash = BLOCKS[name]
    if len(stream) != end - start or hashlib.sha256(stream).hexdigest().upper() != expected_hash:
        raise ValueError(f"Original opcode identity check failed for {name}")


def load_original_streams(root: Path) -> dict[str, bytes]:
    """Read only local user-owned modules and verify complete source hashes."""
    script = root / "scripts/analyze-title-image.py"
    spec = importlib.util.spec_from_file_location("cod3_original_image_reader", script)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    paths = {"main": root / "game/cod3/default.xex",
             "saint_lo": root / "game/cod3/sp/saint_lo/saint_lo.dll"}
    images = {}
    for name, path in paths.items():
        if hashlib.sha256(path.read_bytes()).hexdigest().upper() != SOURCE_XEX_HASHES[name]:
            raise ValueError(f"Unexpected original module: {path}")
        image, _ = module.reconstruct(path, root / "tools/rexglue-source")
        if hashlib.sha256(image).hexdigest().upper() != SOURCE_IMAGE_HASHES[name]:
            raise ValueError(f"Unexpected reconstructed image: {path}")
        images[name] = image
    result = {}
    for name, (image_name, base, start, end, _) in BLOCKS.items():
        result[name] = images[image_name][start-base:end-base]
        verify_stream(name, result[name])
    return result


def interpret(stream: bytes, start: int, initial: State, memory: Memory) -> dict:
    """Execute the actual stream until its first unconditional branch event.

    Save ends at API68's bctrl (callee execution is outside this reference).
    Restore ends at blr. Instruction operands determine frame offsets; there
    is no hard-coded register-to-frame mapping in this interpreter.
    """
    state = initial.clone()
    trace = []
    event = None
    for offset in range(0, len(stream), 4):
        pc = start + offset
        word = struct.unpack_from(">I", stream, offset)[0]
        opcode = word >> 26
        rt = (word >> 21) & 31
        ra = (word >> 16) & 31
        rb = (word >> 11) & 31
        immediate = sign_extend(word & 0xFFFF, 16)
        state.pc = pc + 4
        row = {"pc": f"0x{pc:08X}", "word": f"0x{word:08X}"}
        if opcode in (14, 15):  # addi/addis, RA=0 denotes zero base.
            left = state.gpr[ra] if ra else 0
            delta = immediate << 16 if opcode == 15 else immediate
            state.gpr[rt] = (left + delta) & MASK64
            row.update(op="addis" if opcode == 15 else "addi", destination=f"r{rt}")
        elif opcode in (32, 36, 50, 54, 58, 62):
            if opcode in (58, 62):
                if word & 3:
                    raise ValueError(f"Unsupported DS sub-opcode at {pc:08X}")
                immediate = sign_extend(word & 0xFFFC, 16)
            address = ((state.gpr[ra] if ra else 0) + immediate) & 0xFFFFFFFF
            width = 4 if opcode in (32, 36) else 8
            floating = opcode in (50, 54)
            store = opcode in (36, 54, 62)
            registers = state.fpr_bits if floating else state.gpr
            if store:
                memory.write(address, registers[rt], width)
            else:
                registers[rt] = memory.read(address, width)
            names = {32: "lwz", 36: "stw", 50: "lfd", 54: "stfd", 58: "ld", 62: "std"}
            row.update(op=names[opcode], access="write" if store else "read",
                       address=f"0x{address:08X}", width=width,
                       register=("f" if floating else "r") + str(rt),
                       value=hex64(memory.read(address, width)))
        elif opcode == 31:
            extended = (word >> 1) & 1023
            if word & 1:
                raise ValueError(f"Unexpected CR-record instruction at {pc:08X}")
            if extended == 444:  # or RS,RA,RB: destination is RA.
                state.gpr[ra] = state.gpr[rt] | state.gpr[rb]
                row.update(op="or", destination=f"r{ra}")
            elif extended == 19:  # mfcr
                state.gpr[rt] = state.cr & 0xFFFFFFFF
                row.update(op="mfcr", destination=f"r{rt}")
            elif extended in (339, 467):  # mfspr/mtspr, split SPR selector.
                spr = ((word >> 16) & 31) | ((word >> 6) & 0x3E0)
                if spr not in (8, 9):
                    raise ValueError(f"Unsupported SPR {spr} at {pc:08X}")
                attr = "lr" if spr == 8 else "ctr"
                if extended == 339:
                    state.gpr[rt] = getattr(state, attr)
                    row.update(op="mf" + attr, destination=f"r{rt}")
                else:
                    setattr(state, attr, state.gpr[rt])
                    row.update(op="mt" + attr, destination=attr)
            else:
                raise ValueError(f"Unsupported extended opcode {extended} at {pc:08X}")
        elif word == 0x4E800020:  # blr; link register low two bits ignored by branch.
            state.pc = state.lr & 0xFFFFFFFC
            event = {"kind": "return", "target": f"0x{state.pc:08X}"}
            row.update(op="blr")
        elif word == 0x4E800421:  # bctrl; external API call is our stop boundary.
            target = state.ctr & 0xFFFFFFFC
            state.lr = pc + 4
            state.pc = target
            event = {"kind": "external_call", "target": f"0x{target:08X}",
                     "link_return": f"0x{pc+4:08X}"}
            row.update(op="bctrl")
        else:
            raise ValueError(f"Unsupported instruction {word:08X} at {pc:08X}")
        trace.append(row)
        if event:
            if offset + 4 != len(stream):
                raise ValueError("Reference block includes instructions after its branch boundary")
            break
    return {"state": state, "memory": memory, "trace": trace, "event": event}


def execute_block(name: str, streams: dict[str, bytes], state: State, memory: Memory) -> dict:
    stream = streams[name]
    verify_stream(name, stream)
    result = interpret(stream, BLOCKS[name][2], state, memory)
    expected = "return" if name == "restore" else "external_call"
    if result["event"] is None or result["event"]["kind"] != expected:
        raise ValueError("Unexpected original-block control-flow event")
    return result


def synthetic_state(seed: int, stack: int) -> State:
    rng = random.Random(seed)
    state = State([rng.getrandbits(64) for _ in range(32)],
                  [rng.getrandbits(64) for _ in range(32)],
                  [rng.getrandbits(128) for _ in range(128)],
                  rng.getrandbits(64), rng.getrandbits(64), rng.getrandbits(32),
                  rng.getrandbits(64), rng.getrandbits(32))
    state.gpr[1] = stack
    return state


def make_fixture(streams: dict[str, bytes], case_id: int) -> dict:
    """Synthetic register values only: these are not gameplay captures."""
    stack = 0x70008000 + case_id * 0x1000
    frame = stack - FRAME_SIZE
    initial = synthetic_state(0xC0D30000 + case_id, stack)
    if case_id == 0:
        special = [0, MASK64, 1 << 63, (1 << 63)-1, 0x7FF0000000000001,
                   0x7FF800000000D3D3, 0xFFF0000000000000, 0x8000000000000000]
        for i in range(32):
            initial.fpr_bits[i] = special[i % len(special)]
            if i != 1:
                initial.gpr[i] = special[(i+3) % len(special)]
        initial.lr = 0xDEADBEEF89192513
        initial.ctr = 0xFEDCBA9876543211
        initial.cr = 0x12345678
    canary = bytes(((i * 73 + case_id * 11) & 255) for i in range(FRAME_SIZE + 32))
    memory = Memory()
    memory.map(frame-16, canary)
    memory.map(SAVED_SP_GLOBAL, bytes.fromhex("C0DEC0DE"))
    memory.map(API_SAVE_SLOT, API_SAVE_TARGET.to_bytes(4, "big"))
    capture = execute_block("capture_wait", streams, initial, memory.clone())
    restore_input = synthetic_state(0xBEEF0000+case_id, 0x71111110)
    restore_input.gpr[10] = frame
    restore_input.gpr[11] = frame
    restore_input.cr = 0xA5A5A5A5 ^ case_id
    restored = execute_block("restore", streams, restore_input, capture["memory"].clone())
    return {"id": case_id, "synthetic": True, "frame_address": f"0x{frame:08X}",
            "initial_memory_base": f"0x{frame-16:08X}", "initial_memory_hex": canary.hex().upper(),
            "capture_input": initial.to_json(), "capture_expected": capture["state"].to_json(),
            "capture_event": capture["event"],
            "frame_hex": capture["memory"].read_bytes(frame, FRAME_SIZE).hex().upper(),
            "saved_sp_global_hex": capture["memory"].read_bytes(SAVED_SP_GLOBAL, 4).hex().upper(),
            "restore_input": restore_input.to_json(), "restore_expected": restored["state"].to_json(),
            "restore_event": restored["event"]}


def cpp_fixture_header(vectors: list[dict]) -> str:
    """Portable aggregate fixtures; values come only from opcode execution."""
    def numbers(values, suffix="ULL"):
        return "{" + ", ".join(v + suffix for v in values) + "}"

    def bytes_array(hex_string):
        return "{" + ", ".join(f"0x{b:02X}" for b in bytes.fromhex(hex_string)) + "}"

    def state(value):
        halves = []
        for item in value["vr_bits"]:
            bits = int(item, 16)
            halves.append("{" + hex64(bits) + "ULL, " + hex64(bits >> 64) + "ULL}")
        return "{\n" + numbers(value["gpr"]) + ",\n" + numbers(value["fpr_bits"]) + ",\n" + \
            "{" + ", ".join(halves) + "},\n" + \
            ", ".join(value[k] + ("U" if k in ("cr", "fpscr", "pc") else "ULL")
                      for k in ("lr", "ctr", "cr", "xer", "fpscr", "pc")) + "\n}"

    output = [
        "#pragma once", "#include <cstddef>", "#include <cstdint>",
        "// GENERATED SYNTHETIC FIXTURES, not captured gameplay state.",
        "// Expectations derive from hash-verified ORIGINAL PPC instruction execution.",
        "// Restore preserves incoming CR/FPSCR/XER/vector bits; these are not saved-frame restores.",
        "namespace cod3::coroutine_reference_vectors {",
        "struct RegisterState {",
        "  std::uint64_t gpr[32];",
        "  std::uint64_t fpr_bits[32];",
        "  std::uint64_t vr_bits[128][2]; // [0]=low64, [1]=high64 of the synthetic 128-bit marker",
        "  std::uint64_t lr, ctr;", "  std::uint32_t cr;", "  std::uint64_t xer;",
        "  std::uint32_t fpscr, pc;", "};",
        "struct Vector {",
        "  std::uint32_t id, frame_address, initial_memory_address;",
        "  std::uint8_t initial_memory[432]; // 16-byte guards + 400-byte frame + 16-byte guard",
        "  std::uint8_t frame[400];", "  std::uint32_t saved_sp_global;",
        "  RegisterState capture_input, capture_expected, restore_input, restore_expected;", "};",
        'inline constexpr const char* kRestoreOpcodeSha256 = "' + BLOCKS["restore"][4] + '";',
        'inline constexpr const char* kCaptureOpcodeSha256 = "' + BLOCKS["capture_wait"][4] + '";',
        "inline constexpr Vector kVectors[] = {",
    ]
    for item in vectors:
        output.append("{\n" + str(item["id"]) + "U, " + item["frame_address"] + "U, " + item["initial_memory_base"] + "U,\n" +
                      bytes_array(item["initial_memory_hex"]) + ",\n" + bytes_array(item["frame_hex"]) + ",\n" +
                      "0x" + item["saved_sp_global_hex"] + "U,\n" +
                      ",\n".join(state(item[k]) for k in ("capture_input", "capture_expected", "restore_input", "restore_expected")) + "\n},")
    output += ["};", "inline constexpr std::size_t kVectorCount = sizeof(kVectors) / sizeof(kVectors[0]);",
               "} // namespace cod3::coroutine_reference_vectors", ""]
    return "\n".join(output)


def write_artifacts(root: Path, streams: dict[str, bytes], output: Path, cases: int) -> None:
    output.mkdir(parents=True, exist_ok=True)
    vectors = [make_fixture(streams, i) for i in range(cases)]
    fixture_doc = {"schema_version": 1, "synthetic": True,
                   "warning": "Synthetic register/memory vectors, never observed gameplay state.",
                   "source_xex_sha256": SOURCE_XEX_HASHES, "source_image_sha256": SOURCE_IMAGE_HASHES,
                   "frame_size": FRAME_SIZE, "vectors": vectors}
    (output / "vectors.json").write_text(json.dumps(fixture_doc, indent=2)+"\n", encoding="utf-8")
    (output / "vectors.hpp").write_text(cpp_fixture_header(vectors), encoding="utf-8")
    sample = synthetic_state(0xC0D3, 0x70008000)
    frame = sample.gpr[1] - FRAME_SIZE
    memory = Memory()
    memory.map(frame-16, bytes([0xCC])*(FRAME_SIZE+32))
    memory.map(SAVED_SP_GLOBAL, bytes(4))
    memory.map(API_SAVE_SLOT, API_SAVE_TARGET.to_bytes(4, "big"))
    capture = execute_block("capture_wait", streams, sample, memory)
    restore_state = synthetic_state(0xDDDD, 0x70004000)
    restore_state.gpr[10] = restore_state.gpr[11] = frame
    restore = execute_block("restore", streams, restore_state, memory.clone())
    for result in (capture, restore):
        for item in result["trace"]:
            if "address" in item:
                address = int(item["address"], 16)
                if frame <= address < frame + FRAME_SIZE:
                    item["frame_offset"] = address - frame
    contract = {"schema_version": 1, "source_xex_sha256": SOURCE_XEX_HASHES,
                "source_image_sha256": SOURCE_IMAGE_HASHES,
                "blocks": {name: {"start": f"0x{start:08X}", "end_exclusive": f"0x{end:08X}",
                                  "size": end-start, "sha256": sha}
                           for name, (_, _, start, end, sha) in BLOCKS.items()},
                "capture_trace": capture["trace"], "restore_trace": restore["trace"],
                "boundaries": {"capture": "Stops at first bctrl to stack-save API68; external callee and wait/event APIs are not interpreted.",
                               "restore": "Begins at OR r1,r11,r10; stops at BLR to saved low32 LR with two low target bits cleared."},
                "synthetic_fixture_count": cases}
    (output / "contract.json").write_text(json.dumps(contract, indent=2)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path)
    parser.add_argument("--cases", type=int, default=32)
    args = parser.parse_args()
    if not 1 <= args.cases <= 1024:
        parser.error("--cases must be between 1 and 1024")
    root = args.root.resolve()
    output = args.out or root / "tests/coroutine-reference/generated"
    streams = load_original_streams(root)
    write_artifacts(root, streams, output, args.cases)
    print(json.dumps({"source_identity_verified": True, "synthetic_vectors": args.cases,
                      "output": str(output), "blocks": list(streams)}, ensure_ascii=True))


if __name__ == "__main__":
    main()
