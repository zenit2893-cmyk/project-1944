"""Machine-checkable guards for the original all-module coroutine map.

These tests consume the local reconstructed images and the locked XEX
manifest. They do not start a game, emulator, GUI, or native bridge.
"""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MAP = load_module("cod3_coroutine_map", ROOT / "analysis/cod3-allmodule-coroutine-sites.py")
XEX = load_module("cod3_xex_headers_for_coroutine_map", ROOT / "scripts/analyze-title-xex.py")
IMAGE = load_module("cod3_image_for_coroutine_map", ROOT / "scripts/analyze-title-image.py")


class CoroutineMapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(
            (ROOT / "analysis/cod3-allmodule-coroutine-manifest.json").read_text(encoding="utf-8"))
        cls.report = json.loads(
            (ROOT / "analysis/cod3-allmodule-coroutine-sites.json").read_text(encoding="utf-8"))
        cls.by_path = {entry["path"]: entry for entry in cls.manifest["modules"]}
        cls.by_module = {entry["module"]: entry for entry in cls.manifest["modules"]}

    def test_live_xex_identity_hashes_and_revision_for_all_fifteen(self):
        """Every local mission XEX must remain the locked USA/Europe revision."""
        self.assertEqual(len(self.by_path), 15)
        for path, expected in self.by_path.items():
            with self.subTest(module=expected["module"]):
                xex = ROOT / path
                image_path = ROOT / "analysis/cod3-coroutine-module-images" / f"{expected['module']}.bin"
                metadata = XEX.analyze(xex)
                image = image_path.read_bytes()
                pe = IMAGE.inspect_pe(image)
                mismatches = MAP.identity_mismatches(
                    ROOT, xex, metadata, pe, expected,
                    image_sha256=hashlib.sha256(image).hexdigest().upper(),
                    loader_source_sha256=self.manifest["loader_source_sha256"])
                self.assertEqual(mismatches, [])

    def test_report_has_exact_three_bodies_and_verified_callers_for_all_fifteen(self):
        self.assertEqual(self.report["schema_version"], 2)
        self.assertEqual(self.report["module_count"], 15)
        self.assertEqual(self.report["verified_module_count"], 15)
        self.assertEqual(self.report["capture_count"], 45)
        expected_kinds = set(MAP.CAPTURE_TAILS)
        for module in self.report["modules"]:
            with self.subTest(module=module["module"]):
                expected = self.by_module[module["module"]]
                self.assertEqual(module["status"], "verified")
                self.assertEqual(module["input_sha256"], expected["source_sha256"])
                self.assertEqual(module["image_sha256"], expected["image_sha256"])
                self.assertTrue(module["input_sha256_verified"])
                self.assertTrue(module["image_sha256_verified"])
                self.assertEqual(module["image_base"], expected["image_base"])
                self.assertEqual(module["original_pe_name"], expected["original_pe_name"])
                captures = {capture["kind"]: capture for capture in module["captures"]}
                self.assertEqual(set(captures), expected_kinds)
                self.assertEqual(module["capture_count"], 3)
                for kind, capture in captures.items():
                    with self.subTest(kind=kind):
                        spec = MAP.CAPTURE_TAILS[kind]
                        self.assertTrue(capture["exact_variant_verified"])
                        self.assertTrue(capture["frame_layout_verified"])
                        self.assertEqual(capture["size"], capture["exact_variant_instruction_count"] * 4)
                        self.assertEqual(capture["wait_api_byte_offset"], spec["api_offset"])
                        self.assertEqual(capture["relocation_mask_instruction_indices"],
                                         MAP.full_body_relocation_pair_indices(kind))
                        self.assertTrue(capture["full_body_verification"]["exact_variant_grammar_matches"])
                        self.assertTrue(capture["full_body_verification"]["all_non_address_bits_match"])
                        self.assertTrue(capture["full_body_verification"]["relative_global_layout_matches"])
                        self.assertEqual(capture["full_body_verification"]["mismatches"], [])
                        self.assertGreater(capture["direct_caller_count"], 0)
                        self.assertTrue(capture["continuation_callers_verified"])
                        for caller in capture["caller_examples"]:
                            self.assertEqual(
                                int(caller["saved_continuation_lr"], 16),
                                int(caller["call_address"], 16) + 4)

    def test_frame_layout_contract_is_explicit(self):
        self.assertEqual(MAP.FRAME_LAYOUT["bytes"], 400)
        self.assertEqual(MAP.FRAME_LAYOUT["stack_allocation"], -400)
        self.assertEqual(MAP.FRAME_LAYOUT["gpr_offsets"]["3"], 8)
        self.assertEqual(MAP.FRAME_LAYOUT["gpr_offsets"]["31"], 232)
        self.assertEqual(MAP.FRAME_LAYOUT["fpr_offsets"]["14"], 240)
        self.assertEqual(MAP.FRAME_LAYOUT["fpr_offsets"]["31"], 376)
        self.assertEqual(MAP.FRAME_LAYOUT["cr_offset"], 384)
        self.assertEqual(MAP.FRAME_LAYOUT["lr_offset"], 388)
        self.assertEqual(MAP.FRAME_LAYOUT["ctr_offset"], 392)
        for module in self.report["modules"]:
            for capture in module["captures"]:
                self.assertEqual(capture["frame_layout"], {
                    "verified": True,
                    "errors": [],
                    "bytes": 400,
                    "gpr_offsets": MAP.FRAME_LAYOUT["gpr_offsets"],
                    "fpr_offsets": MAP.FRAME_LAYOUT["fpr_offsets"],
                    "cr_offset": 384,
                    "lr_offset": 388,
                    "ctr_offset": 392,
                })

    def test_wrong_title_is_rejected(self):
        expected = self.by_module["saint_lo"]
        xex = ROOT / expected["path"]
        image = (ROOT / "analysis/cod3-coroutine-module-images/saint_lo.bin").read_bytes()
        metadata = XEX.analyze(xex)
        metadata = copy.deepcopy(metadata)
        metadata["execution_info"]["title_id"] = "DEADBEEF"
        pe = IMAGE.inspect_pe(image)
        mismatches = MAP.identity_mismatches(ROOT, xex, metadata, pe, expected)
        self.assertIn("title_id", {item["field"] for item in mismatches})

    def test_wrong_revision_is_rejected(self):
        expected = self.by_module["saint_lo"]
        xex = ROOT / expected["path"]
        image = (ROOT / "analysis/cod3-coroutine-module-images/saint_lo.bin").read_bytes()
        metadata = XEX.analyze(xex)
        metadata = copy.deepcopy(metadata)
        metadata["execution_info"]["version"]["raw"] = "0x00000002"
        metadata["execution_info"]["base_version"]["raw"] = "0x00000002"
        pe = IMAGE.inspect_pe(image)
        mismatches = MAP.identity_mismatches(ROOT, xex, metadata, pe, expected)
        fields = {item["field"] for item in mismatches}
        self.assertIn("version_raw", fields)
        self.assertIn("base_version_raw", fields)

    def test_wrong_module_hash_is_rejected(self):
        expected = copy.deepcopy(self.by_module["saint_lo"])
        xex = ROOT / expected["path"]
        image = (ROOT / "analysis/cod3-coroutine-module-images/saint_lo.bin").read_bytes()
        metadata = XEX.analyze(xex)
        expected["source_sha256"] = "0" * 64
        pe = IMAGE.inspect_pe(image)
        mismatches = MAP.identity_mismatches(ROOT, xex, metadata, pe, expected)
        self.assertIn("source_sha256", {item["field"] for item in mismatches})

    def test_ambiguous_complete_signature_is_rejected(self):
        """A second complete timed body must make the scan manual-review only."""
        source = bytearray(
            (ROOT / "analysis/cod3-coroutine-module-images/saint_lo.bin").read_bytes())
        pe = IMAGE.inspect_pe(source)
        source_offset = int("0x89190500", 16) - int(pe["base"], 16)
        body_size = 304
        ranges = MAP.executable_ranges(pe, len(source))
        destination = None
        for begin, end in ranges:
            for offset in range(begin, end - body_size, 4):
                if source[offset:offset + body_size] == b"\0" * body_size:
                    destination = offset
                    break
            if destination is not None:
                break
        self.assertIsNotNone(destination)
        self.assertNotEqual(destination, source_offset)
        source[destination:destination + body_size] = source[source_offset:source_offset + body_size]
        scan = MAP.scan_capture_candidates(source, pe)
        self.assertEqual(scan["candidate_kind_counts"]["timed_wait_capture"], 2)
        self.assertEqual(scan["status"], "needs_manual_review")
        self.assertIn("timed_wait_capture", scan["ambiguous_kinds"])
        self.assertTrue(any(item.get("reason") == "Ambiguous complete capture signature"
                            for item in scan["rejected_or_ambiguous_candidates"]))

    def test_nonexact_variant_tail_is_rejected(self):
        """A changed non-address opcode cannot pass through relocation masking."""
        image = bytearray(
            (ROOT / "analysis/cod3-coroutine-module-images/saint_lo.bin").read_bytes())
        pe = IMAGE.inspect_pe(image)
        source_offset = int("0x89190500", 16) - int(pe["base"], 16)
        image[source_offset + 68 * 4:source_offset + 69 * 4] = (0xDEADBEEF).to_bytes(4, "big")
        scan = MAP.scan_capture_candidates(image, pe)
        self.assertEqual(scan["candidate_kind_counts"]["timed_wait_capture"], 0)
        self.assertEqual(scan["status"], "needs_manual_review")


if __name__ == "__main__":
    unittest.main(verbosity=2)
