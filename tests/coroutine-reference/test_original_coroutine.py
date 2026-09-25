"""Independent invariants for the actual COD3 coroutine PPC instruction stream.

No native bridge implementation is imported. All register inputs are synthetic.
"""
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "cod3_coroutine_opcode_reference", ROOT / "integration/coroutine-reference/coroutine_reference.py")
REF = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = REF
SPEC.loader.exec_module(REF)


class OriginalCoroutineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.streams = REF.load_original_streams(ROOT)

    def setup_capture(self, case=0):
        entry = REF.synthetic_state(0xC0D30000+case, 0x70008000+case*0x1000)
        frame = entry.gpr[1]-400
        initial_bytes = bytes((i*29+case*71) & 255 for i in range(432))
        memory = REF.Memory()
        memory.map(frame-16, initial_bytes)
        memory.map(REF.SAVED_SP_GLOBAL, bytes.fromhex("ABCD1234"))
        memory.map(REF.API_SAVE_SLOT, REF.API_SAVE_TARGET.to_bytes(4, "big"))
        return entry, frame, memory, initial_bytes

    def test_original_identity_and_identical_capture_prefixes(self):
        self.assertEqual(len(self.streams["restore"]), 216)
        self.assertEqual(len(self.streams["capture_wait"]), 268)
        self.assertEqual(self.streams["capture_wait"], self.streams["capture_event"])
        for name, stream in self.streams.items():
            modified = bytearray(stream)
            modified[len(modified)//2] ^= 1
            with self.assertRaisesRegex(ValueError, "identity check failed"):
                REF.verify_stream(name, modified)

    def test_capture_layout_scratch_registers_big_endian_and_canaries(self):
        for case in range(64):
            with self.subTest(case=case):
                entry, frame, memory, initial = self.setup_capture(case)
                before = entry.to_json()
                result = REF.execute_block("capture_wait", self.streams, entry, memory)
                self.assertEqual(entry.to_json(), before, "Interpreter must not mutate input registers")
                self.assertEqual(memory.read_bytes(frame-16, 24), initial[:24])
                self.assertEqual(memory.read_bytes(frame+400, 16), initial[-16:])
                for reg in range(3, 32):
                    expected = entry.gpr[reg]
                    if reg == 10:
                        expected = entry.gpr[1]
                    elif reg == 11:
                        expected = 0xFFFFFFFF892552C4
                    offset = 8 + (reg-3)*8
                    self.assertEqual(memory.read_bytes(frame+offset, 8), expected.to_bytes(8, "big"))
                for reg in range(14, 32):
                    self.assertEqual(memory.read(frame+240+(reg-14)*8, 8), entry.fpr_bits[reg])
                self.assertEqual(memory.read(frame+384, 4), entry.cr)
                self.assertEqual(memory.read(frame+388, 4), entry.lr & 0xFFFFFFFF)
                self.assertEqual(memory.read(frame+392, 8), entry.ctr)
                self.assertEqual(memory.read(REF.SAVED_SP_GLOBAL, 4), entry.gpr[1])
                self.assertEqual(result["state"].gpr[1], frame)
                self.assertEqual(result["state"].gpr[3], frame)
                self.assertEqual(result["event"], {"kind": "external_call", "target": "0x824A24A0", "link_return": "0x8919073C"})
                self.assertEqual(result["state"].lr, 0x8919073C)
                self.assertEqual(result["state"].ctr, 0x824A24A0)

    def test_capture_variant_changes_only_call_return_address(self):
        entry, frame, memory, _ = self.setup_capture(5)
        first = REF.execute_block("capture_wait", self.streams, entry, memory.clone())
        second = REF.execute_block("capture_event", self.streams, entry, memory.clone())
        self.assertEqual(first["memory"].bytes, second["memory"].bytes)
        a, b = first["state"].to_json(), second["state"].to_json()
        self.assertEqual(a.pop("lr"), "0x000000008919073C")
        self.assertEqual(b.pop("lr"), "0x000000008919086C")
        self.assertEqual(a, b)

    def test_restore_preserves_unsaved_state_and_does_not_restore_cr(self):
        for case in range(64):
            with self.subTest(case=case):
                entry, frame, memory, _ = self.setup_capture(case)
                REF.execute_block("capture_wait", self.streams, entry, memory)
                incoming = REF.synthetic_state(0xAAA00000+case, 0x71000000)
                incoming.gpr[10] = incoming.gpr[11] = frame
                incoming.cr = (~entry.cr) & 0xFFFFFFFF
                memory_before = memory.bytes.copy()
                result = REF.execute_block("restore", self.streams, incoming, memory)
                out = result["state"]
                self.assertEqual(memory.bytes, memory_before, "Restore block has no stores")
                self.assertEqual(out.gpr[1], entry.gpr[1])
                self.assertEqual(out.gpr[0], incoming.gpr[0])
                self.assertEqual(out.gpr[2], incoming.gpr[2])
                for reg in range(3, 32):
                    expected = entry.gpr[reg]
                    if reg == 10:
                        expected = entry.gpr[1]
                    elif reg == 11:
                        expected = 0xFFFFFFFF892552C4
                    self.assertEqual(out.gpr[reg], expected)
                self.assertEqual(out.fpr_bits[:14], incoming.fpr_bits[:14])
                self.assertEqual(out.fpr_bits[14:], entry.fpr_bits[14:])
                self.assertEqual(out.vr_bits, incoming.vr_bits)
                self.assertEqual(out.xer, incoming.xer)
                self.assertEqual(out.fpscr, incoming.fpscr)
                self.assertEqual(out.cr, incoming.cr)
                self.assertEqual(out.lr, entry.lr & 0xFFFFFFFF)
                self.assertEqual(out.ctr, entry.ctr)
                self.assertEqual(out.pc, entry.lr & 0xFFFFFFFC)

    def test_saved_cr_word_is_not_read_by_restore(self):
        entry, frame, memory, _ = self.setup_capture(3)
        REF.execute_block("capture_wait", self.streams, entry, memory)
        incoming = REF.synthetic_state(42, 0x71000000)
        incoming.gpr[10] = incoming.gpr[11] = frame
        results = []
        for saved_cr in (0, 0xFFFFFFFF, 0x12345678, 0x87654321):
            changed = memory.clone()
            changed.write(frame+384, saved_cr, 4)
            result = REF.execute_block("restore", self.streams, incoming, changed)
            results.append(result["state"].to_json())
            offsets = [int(t["address"], 16)-frame for t in result["trace"] if "address" in t]
            self.assertNotIn(384, offsets)
        self.assertTrue(all(item == results[0] for item in results))

    def test_floating_point_payloads_include_nan_and_signed_zero(self):
        fixture = REF.make_fixture(self.streams, 0)
        expected = fixture["restore_expected"]["fpr_bits"]
        original = fixture["capture_input"]["fpr_bits"]
        self.assertEqual(expected[14:], original[14:])
        self.assertIn("0x7FF0000000000001", expected[14:])
        self.assertIn("0x7FF800000000D3D3", expected[14:])
        self.assertIn("0x8000000000000000", expected[14:])
        self.assertEqual(fixture["restore_expected"]["lr"], "0x0000000089192513")
        self.assertEqual(fixture["restore_expected"]["pc"], "0x89192510")
        self.assertEqual(fixture["restore_expected"]["ctr"], "0xFEDCBA9876543211")

    def test_stack_selection_uses_bitwise_or_as_original_opcode(self):
        entry, frame, memory, _ = self.setup_capture(8)
        REF.execute_block("capture_wait", self.streams, entry, memory)
        incoming = REF.synthetic_state(63, 0x71000000)
        incoming.gpr[10] = frame & 0xAAAAAAAF
        incoming.gpr[11] = frame & 0x5555555F
        self.assertEqual(incoming.gpr[10] | incoming.gpr[11], frame)
        result = REF.execute_block("restore", self.streams, incoming, memory)
        self.assertEqual(result["state"].gpr[1], frame+400)

    def test_unmapped_reads_and_unknown_instructions_fail_explicitly(self):
        entry, frame, memory, _ = self.setup_capture()
        REF.execute_block("capture_wait", self.streams, entry, memory)
        incoming = REF.synthetic_state(93, 0x71000000)
        incoming.gpr[10] = incoming.gpr[11] = frame
        del memory.bytes[frame+399]
        with self.assertRaisesRegex(ValueError, "Unmapped guest read"):
            REF.execute_block("restore", self.streams, incoming, memory)
        with self.assertRaisesRegex(ValueError, "Unsupported instruction"):
            REF.interpret(bytes.fromhex("60000000"), 0x82000000, incoming, REF.Memory())


if __name__ == "__main__":
    unittest.main(verbosity=2)
