#!/usr/bin/env python3
"""Unit and recorded-corpus checks for the isolated Xenos semantic model."""

from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path


THIS_FILE = Path(__file__).resolve()
WORKSPACE_ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else THIS_FILE.parents[2]
sys.path.insert(0, str(WORKSPACE_ROOT / "integration/xenos-semantics"))

from xenos_semantics import (  # noqa: E402
    HEADER_BYTES,
    LEGACY_DUAL_VERTEX_FLAGS,
    LEGACY_PIXEL_FLAGS,
    LEGACY_VERTEX_FLAGS,
    ProgramEntry,
    ShaderStage,
    audit_workspace,
    bool_binding_for_guest_address,
    cube_coord_from_projection,
    cube_direction,
    cube_project,
    decode_fetch_word4,
    effective_lod,
    explicit_gradient_scales,
    instruction_lod_bias,
    legacy_variant,
    make_vertex_input_bindings,
    map_bool_binding,
    map_float_register,
    map_sampler_binding,
    parse_container_header,
    parse_legacy_definition,
    select_program,
)


def _header(flags: int, *, dual: bool = False) -> bytes:
    values = [
        flags,
        0x200,
        0x100,
        0,
        0x24,
        0x100,
        0x40,
        0x160 if dual else 0,
        0x180 if dual else 0,
    ]
    return struct.pack(">9I", *values) + bytes(0x300 - HEADER_BYTES)


def _definition_blob(flags: int = LEGACY_PIXEL_FLAGS) -> bytes:
    blob = bytearray(_header(flags))
    # A legacy definition table has an eight-word header and a 20-byte list.
    table = 0x100
    struct.pack_into(">I", blob, table + 0x10, 0x14)
    struct.pack_into(">HHI", blob, table + 0x20, 508 if flags == LEGACY_PIXEL_FLAGS else 252, 16, 0)
    struct.pack_into(">3I", blob, table + 0x28, 0, 0, 0)
    return bytes(blob)


class ModelTests(unittest.TestCase):
    def test_exact_legacy_flags_and_stage(self) -> None:
        self.assertEqual(legacy_variant(LEGACY_PIXEL_FLAGS).value, "legacy_pixel")
        self.assertEqual(legacy_variant(LEGACY_VERTEX_FLAGS).value, "legacy_vertex")
        self.assertEqual(legacy_variant(LEGACY_DUAL_VERTEX_FLAGS).value, "legacy_dual_vertex")
        self.assertEqual(parse_container_header(_header(LEGACY_PIXEL_FLAGS)).stage, ShaderStage.PIXEL)
        self.assertEqual(parse_container_header(_header(LEGACY_VERTEX_FLAGS)).stage, ShaderStage.VERTEX)
        with self.assertRaises(ValueError):
            legacy_variant(0x102A1002)

    def test_primary_and_secondary_offsets_are_explicit(self) -> None:
        header = parse_container_header(_header(LEGACY_DUAL_VERTEX_FLAGS, dual=True))
        primary = select_program(header, ProgramEntry.PRIMARY)
        secondary = select_program(header, ProgramEntry.SECONDARY)
        self.assertEqual((primary.definition_offset, primary.shader_offset), (0x100, 0x40))
        self.assertEqual((secondary.definition_offset, secondary.shader_offset), (0x160, 0x180))
        with self.assertRaises(ValueError):
            select_program(parse_container_header(_header(LEGACY_VERTEX_FLAGS)), ProgramEntry.SECONDARY)

    def test_legacy_definition_uses_plus_20_list(self) -> None:
        pixel = parse_container_header(_definition_blob())
        definition = parse_legacy_definition(_definition_blob(), pixel)
        self.assertIsNotNone(definition)
        assert definition is not None
        self.assertEqual(definition.list_offset, 0x120)
        self.assertEqual(definition.logical_register_index, 252)
        self.assertEqual(definition.logical_register_count, 4)
        vertex = parse_container_header(_definition_blob(LEGACY_VERTEX_FLAGS))
        vertex_definition = parse_legacy_definition(_definition_blob(LEGACY_VERTEX_FLAGS), vertex)
        self.assertIsNotNone(vertex_definition)
        assert vertex_definition is not None
        self.assertEqual(vertex_definition.logical_register_index, 252)
        malformed = bytearray(_definition_blob())
        struct.pack_into(">I", malformed, 0x128, 1)
        with self.assertRaises(ValueError):
            parse_legacy_definition(bytes(malformed), pixel)

    def test_constant_bank_mappings_fail_closed(self) -> None:
        self.assertEqual(tuple(map_float_register(ShaderStage.PIXEL, 256, 2)), (0, 1))
        self.assertEqual(tuple(map_float_register(ShaderStage.VERTEX, 252, 4)), (252, 253, 254, 255))
        pixel_bool = map_bool_binding(0, ShaderStage.PIXEL, legacy=True)
        self.assertEqual((pixel_bool.guest_address, pixel_bool.host_byte_offset, pixel_bool.host_bit), (128, 256, 16))
        self.assertEqual(map_bool_binding(15, ShaderStage.PIXEL, legacy=True).host_bit, 31)
        self.assertEqual(bool_binding_for_guest_address(128, ShaderStage.PIXEL).reflection_index, 0)
        self.assertEqual(map_bool_binding(0, ShaderStage.VERTEX).host_bit, 0)
        self.assertEqual(map_bool_binding(0, ShaderStage.PIXEL, legacy=False).guest_address, 0)
        with self.assertRaises(ValueError):
            map_bool_binding(16, ShaderStage.PIXEL)
        with self.assertRaises(ValueError):
            map_float_register(ShaderStage.VERTEX, 253, 4)

    def test_legacy_vertex_sampler_slots_and_banks(self) -> None:
        vertex = map_sampler_binding(1, ShaderStage.VERTEX, 17)
        self.assertEqual(vertex.instruction_index, 17)
        self.assertEqual(vertex.texture_byte_offset("2D"), 4)
        self.assertEqual(vertex.texture_byte_offset("3D"), 68)
        self.assertEqual(vertex.texture_byte_offset("Cube"), 132)
        self.assertEqual(vertex.sampler_byte_offset, 196)
        pixel = map_sampler_binding(10, ShaderStage.PIXEL, 10)
        self.assertEqual(pixel.sampler_byte_offset, 232)
        with self.assertRaises(ValueError):
            map_sampler_binding(1, ShaderStage.VERTEX, 1)

    def test_vertex_inputs_preserve_fetch_address_and_declaration_ordinal(self) -> None:
        bindings = make_vertex_input_bindings(((14, 0, 0), (15, 3, 0), (16, 0, 0)))
        self.assertEqual([(b.address, b.location, b.host_name) for b in bindings], [
            (14, 0, "iFetch14"), (15, 1, "iFetch15"), (16, 2, "iFetch16")
        ])
        with self.assertRaises(ValueError):
            make_vertex_input_bindings(((14, 0, 0), (14, 3, 0)))

    def test_fetch_word4_and_lod_units(self) -> None:
        zero = decode_fetch_word4(0)
        self.assertEqual((zero.lod_bias_raw, zero.horizontal_exponent, zero.vertical_exponent), (0, 0, 0))
        word = ((0x3FF) << 12) | (0x1F << 22) | (0x10 << 27)
        decoded = decode_fetch_word4(word)
        self.assertEqual(decoded.lod_bias_raw, -1)
        self.assertEqual(decoded.horizontal_exponent, -1)
        self.assertEqual(decoded.vertical_exponent, -16)
        self.assertAlmostEqual(instruction_lod_bias(0x7F), -1.0 / 16.0)
        # +1.0 fetch bias, +2.5 register LOD, +1.0 instruction bias.
        self.assertAlmostEqual(effective_lod(32 << 12, register_lod=2.5, instruction_bias_raw=16), 4.5)
        horizontal, vertical = explicit_gradient_scales(32 << 12, register_lod=0.0, instruction_bias_raw=0)
        self.assertAlmostEqual(horizontal, 2.0)
        self.assertAlmostEqual(vertical, 2.0)

    def test_cube_projection_round_trips_with_tc_sc_order(self) -> None:
        directions = (
            (1.0, 0.0, 0.0), (-1.0, 0.0, 0.0),
            (0.0, 1.0, 0.0), (0.0, -1.0, 0.0),
            (0.0, 0.0, 1.0), (0.0, 0.0, -1.0),
            (0.6, 0.8, 1.0), (-0.6, 0.8, -1.0),
        )
        for direction in directions:
            projection = cube_project(direction)
            recovered = cube_direction(cube_coord_from_projection(projection))
            scale = max(abs(component) for component in direction) or 1.0
            expected = tuple(component / scale for component in direction)
            for actual, wanted in zip(recovered, expected):
                self.assertAlmostEqual(actual, wanted, places=6, msg=(direction, projection))
        self.assertEqual(cube_project((1.0, 1.0, 1.0)).face, 4)  # Z wins ties.
        self.assertEqual(cube_project((1.0, 1.0, 0.0)).face, 2)  # Y wins X/Y ties.
        with self.assertRaises(ValueError):
            cube_direction((0.0, 1.5, 0.0))


class RecordedCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = audit_workspace(WORKSPACE_ROOT)

    def test_prepared_legacy_corpus_counts(self) -> None:
        self.assertEqual(self.report["prepared_unique_containers"], 437)
        self.assertEqual(self.report["prepared_pixel_containers"], 246)
        self.assertEqual(self.report["prepared_vertex_containers"], 191)
        self.assertEqual(self.report["legacy_flag_counts"], {
            "legacy_pixel": 246,
            "legacy_dual_vertex": 173,
            "legacy_vertex": 18,
        })
        self.assertEqual(self.report["legacy_definition_records"], 430)
        self.assertEqual(self.report["legacy_auxiliary_records"], 173)

    def test_real_texture_inventory_is_slot_safe(self) -> None:
        self.assertEqual(self.report["texture_inventory_entries"], 610)
        self.assertEqual(self.report["texture_operation_counts"], {
            "TextureFetch": 1209,
            "GetTextureWeights": 93,
            "GetTextureGradients": 332,
            "SetTextureGradientsHorz": 30,
            "SetTextureGradientsVert": 30,
            "SetTextureLod": 3,
        })
        self.assertEqual(self.report["explicit_gradient_fetches"], 36)
        self.assertEqual(self.report["explicit_lod_fetches"], 6)
        self.assertEqual(self.report["cube_fetches"], 46)
        self.assertEqual(self.report["weight_fetches"], 93)
        self.assertEqual(self.report["sampler_slot_problems"], [])

    def test_codegen_pair_is_complete_but_semantics_are_unverified(self) -> None:
        summary = self.report["codegen_summary"]
        self.assertEqual(summary["containers"], 437)
        self.assertEqual(summary["total"], 610)
        self.assertEqual(summary["passed_all_stages"], 610)
        self.assertEqual(self.report["codegen_dual_hashes"], 173)
        self.assertTrue(all(item["passed"] and item["input_unchanged"] for item in self.report["codegen_artifacts"]))
        self.assertTrue(all(item["hlsl_exists"] for item in self.report["codegen_artifacts"]))
        self.assertFalse(self.report["codegen_semantics_verified"])


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
