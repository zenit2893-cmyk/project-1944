"""Small, fail-closed model of the COD3 legacy Xenos shader contract.

This module intentionally does not translate or execute a shader.  It captures
the metadata and resource-addressing rules needed by a future native renderer
and by the isolated audit in this directory.  The constants are taken from the
observed COD3 containers, the generated XenosRecomp output, and the local
Xenia source snapshot.  Unknown combinations raise ``ValueError`` instead of
silently selecting a default binding.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import json
import math
from pathlib import Path
import re
import struct
from typing import Iterable, Iterator, Mapping, Sequence


HEADER_BYTES = 9 * 4
LEGACY_REVISION = 0x102A1000
LEGACY_PIXEL_FLAGS = 0x102A1000
LEGACY_VERTEX_FLAGS = 0x102A1001
LEGACY_DUAL_VERTEX_FLAGS = 0x102A1021
FLOAT_REGISTER_COUNT = 256
BOOL_WORD_BYTES = 4
SHARED_BOOLEANS_OFFSET = 256
SHARED_SAMPLER_BASE = 3 * 64
SHARED_DIMENSION_STRIDE = 64


class ShaderStage(str, Enum):
    PIXEL = "pixel"
    VERTEX = "vertex"


class ProgramEntry(str, Enum):
    PRIMARY = "primary"
    SECONDARY = "secondary"


class LegacyVariant(str, Enum):
    PIXEL = "legacy_pixel"
    VERTEX = "legacy_vertex"
    DUAL_VERTEX = "legacy_dual_vertex"


@dataclass(frozen=True)
class ContainerHeader:
    flags: int
    virtual_size: int
    physical_size: int
    field_c: int
    constant_table_offset: int
    definition_table_offset: int
    shader_offset: int
    secondary_definition_offset: int
    secondary_shader_offset: int

    @property
    def total_size(self) -> int:
        return self.virtual_size + self.physical_size

    @property
    def stage(self) -> ShaderStage:
        return stage_for_flags(self.flags)

    @property
    def variant(self) -> LegacyVariant:
        return legacy_variant(self.flags)

    @property
    def is_dual(self) -> bool:
        return self.flags == LEGACY_DUAL_VERTEX_FLAGS


@dataclass(frozen=True)
class ProgramOffsets:
    entry: ProgramEntry
    definition_offset: int
    shader_offset: int


@dataclass(frozen=True)
class DefinitionLayout:
    table_offset: int
    list_offset: int
    list_size: int
    register_index: int
    scalar_count: int
    physical_offset: int
    logical_register_index: int
    logical_register_count: int


@dataclass(frozen=True)
class BoolBinding:
    reflection_index: int
    guest_address: int
    host_byte_offset: int
    host_bit: int


@dataclass(frozen=True)
class SamplerBinding:
    reflection_index: int
    instruction_index: int
    texture_2d_byte_offset: int
    texture_3d_byte_offset: int
    texture_cube_byte_offset: int
    sampler_byte_offset: int

    def texture_byte_offset(self, dimension: str) -> int:
        try:
            return {
                "2D": self.texture_2d_byte_offset,
                "3D": self.texture_3d_byte_offset,
                "Cube": self.texture_cube_byte_offset,
            }[dimension]
        except KeyError as error:
            raise ValueError(f"unsupported texture dimension: {dimension}") from error


@dataclass(frozen=True)
class VertexInputBinding:
    address: int
    usage: int
    usage_index: int
    location: int
    host_name: str


@dataclass(frozen=True)
class FetchWord4:
    lod_bias_raw: int
    lod_bias: float
    horizontal_exponent: int
    vertical_exponent: int


@dataclass(frozen=True)
class CubeProjection:
    # Xenos/Xenia's ALU result order is TC, SC, 2 * major-axis, face ID.
    tc: float
    sc: float
    major_axis_twice: float
    face: int


def _sign_extend(value: int, bits: int) -> int:
    if not 0 <= value < (1 << bits):
        raise ValueError(f"value {value} does not fit in {bits} bits")
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def legacy_variant(flags: int) -> LegacyVariant:
    """Classify only the exact COD3 flags observed in the prepared corpus."""

    try:
        return {
            LEGACY_PIXEL_FLAGS: LegacyVariant.PIXEL,
            LEGACY_VERTEX_FLAGS: LegacyVariant.VERTEX,
            LEGACY_DUAL_VERTEX_FLAGS: LegacyVariant.DUAL_VERTEX,
        }[flags]
    except KeyError as error:
        raise ValueError(f"unsupported legacy shader flags: 0x{flags:08X}") from error


def stage_for_flags(flags: int) -> ShaderStage:
    """Use the same stage bit as XenosRecomp (bit 0: vertex, clear: pixel)."""

    legacy_variant(flags)
    return ShaderStage.VERTEX if flags & 1 else ShaderStage.PIXEL


def parse_container_header(blob: bytes) -> ContainerHeader:
    """Read and bounds-check a complete, big-endian legacy container."""

    if len(blob) < HEADER_BYTES:
        raise ValueError("shader container is shorter than its 36-byte header")
    values = struct.unpack_from(">9I", blob, 0)
    header = ContainerHeader(*values)
    legacy_variant(header.flags)
    if header.virtual_size < HEADER_BYTES:
        raise ValueError("virtual section is shorter than the container header")
    if header.total_size < HEADER_BYTES or header.total_size > len(blob):
        raise ValueError("container virtual + physical size exceeds supplied bytes")

    shader_header_bytes = 36 if header.stage is ShaderStage.VERTEX else 32
    if header.shader_offset < HEADER_BYTES or header.shader_offset + shader_header_bytes > header.virtual_size:
        raise ValueError("primary shader metadata is outside the virtual section")

    if header.is_dual:
        if not header.secondary_definition_offset or not header.secondary_shader_offset:
            raise ValueError("dual container has no secondary metadata offsets")
        if header.secondary_shader_offset < HEADER_BYTES or header.secondary_shader_offset + shader_header_bytes > header.virtual_size:
            raise ValueError("secondary shader metadata is outside the virtual section")
        if header.secondary_definition_offset >= header.virtual_size:
            raise ValueError("secondary definition offset is outside the virtual section")
    elif header.secondary_definition_offset or header.secondary_shader_offset:
        raise ValueError("single-program legacy container has unexpected secondary offsets")
    return header


def select_program(header: ContainerHeader, entry: ProgramEntry | str) -> ProgramOffsets:
    """Select primary or secondary metadata without falling back implicitly."""

    entry = ProgramEntry(entry)
    if entry is ProgramEntry.SECONDARY and not header.is_dual:
        raise ValueError("secondary program requested from a non-dual container")
    if entry is ProgramEntry.SECONDARY:
        return ProgramOffsets(entry, header.secondary_definition_offset, header.secondary_shader_offset)
    return ProgramOffsets(entry, header.definition_table_offset, header.shader_offset)


def parse_legacy_definition(
    blob: bytes,
    header: ContainerHeader,
    entry: ProgramEntry | str = ProgramEntry.PRIMARY,
) -> DefinitionLayout | None:
    """Parse the observed 0x102A10xx definition list at ``table + 0x20``.

    A zero definition offset is valid in the corpus and means that no static
    float definitions are present.  The legacy list has one float definition
    (8 bytes) followed by three zero terminators, and its size word at +0x10 is
    0x14.  Bounds are checked against the selected container sections.
    """

    offsets = select_program(header, entry)
    table_offset = offsets.definition_offset
    if table_offset == 0:
        return None
    if table_offset < HEADER_BYTES or table_offset + 0x20 + 20 > header.virtual_size:
        raise ValueError("legacy definition table/list is outside the virtual section")
    list_size = _u32be(blob, table_offset + 0x10)
    if list_size != 0x14:
        raise ValueError(f"legacy definition list size is 0x{list_size:X}, expected 0x14")
    list_offset = table_offset + 0x20
    register_index, scalar_count, physical_offset = struct.unpack_from(">HHI", blob, list_offset)
    terminators = struct.unpack_from(">3I", blob, list_offset + 8)
    if any(terminators):
        raise ValueError("legacy definition list does not have three zero terminators")
    if scalar_count == 0:
        raise ValueError("legacy float definition has an empty scalar count")
    if physical_offset + scalar_count * 4 > header.physical_size:
        raise ValueError("legacy static constant data is outside the physical section")

    stage = header.stage
    guest_base = 256 if stage is ShaderStage.PIXEL else 0
    if register_index < guest_base:
        raise ValueError("legacy definition register is below the stage bank")
    logical_index = register_index - guest_base
    logical_count = (scalar_count + 3) // 4
    if logical_index + logical_count > FLOAT_REGISTER_COUNT:
        raise ValueError("legacy definition crosses the 256 float4 register bank")
    return DefinitionLayout(
        table_offset,
        list_offset,
        list_size,
        register_index,
        scalar_count,
        physical_offset,
        logical_index,
        logical_count,
    )


def map_float_register(stage: ShaderStage | str, guest_register: int, register_count: int = 1) -> range:
    """Map reflected float registers into the host's 0..255 stage bank."""

    stage = ShaderStage(stage)
    if guest_register < 0 or register_count < 1:
        raise ValueError("float register and count must be positive")
    guest_base = 256 if stage is ShaderStage.PIXEL else 0
    if guest_register < guest_base:
        raise ValueError("float register is below the stage bank")
    logical = guest_register - guest_base
    if logical + register_count > FLOAT_REGISTER_COUNT:
        raise ValueError("float register range crosses the 256-register host bank")
    return range(logical, logical + register_count)


def map_bool_binding(
    reflection_index: int,
    stage: ShaderStage | str,
    *,
    legacy: bool = True,
) -> BoolBinding:
    """Map a reflected bool constant to the generated shared-word ABI.

    XenosRecomp's generated HLSL exposes one ``uint`` at SharedConstants +
    256.  Pixel definitions use the high 16 bits of that word, while vertex
    definitions use the low 16 bits.  In an observed legacy pixel container,
    the guest bool address is the second 128-register bank (index + 128).
    The function rejects indices that cannot be represented instead of
    silently emitting an unbound ``b#`` reference.
    """

    stage = ShaderStage(stage)
    if not 0 <= reflection_index < 256:
        raise ValueError("bool reflection index is outside the 256-register guest bank")
    guest_base = 128 if legacy and stage is ShaderStage.PIXEL else 0
    host_base = 16 if stage is ShaderStage.PIXEL else 0
    host_bit = host_base + reflection_index
    if host_bit >= 32:
        raise ValueError("bool reflection index does not fit generated shared bool word")
    return BoolBinding(reflection_index, guest_base + reflection_index, SHARED_BOOLEANS_OFFSET, host_bit)


def bool_binding_for_guest_address(
    guest_address: int,
    stage: ShaderStage | str,
    *,
    legacy: bool = True,
) -> BoolBinding:
    stage = ShaderStage(stage)
    guest_base = 128 if legacy and stage is ShaderStage.PIXEL else 0
    reflection_index = guest_address - guest_base
    if not 0 <= reflection_index < 256:
        raise ValueError("guest bool address is outside the selected stage bank")
    return map_bool_binding(reflection_index, stage, legacy=legacy)


def map_sampler_binding(
    reflection_index: int,
    stage: ShaderStage | str,
    instruction_index: int | None = None,
    *,
    legacy: bool = True,
) -> SamplerBinding:
    """Map a reflected sampler and verify the legacy vertex slot shift."""

    stage = ShaderStage(stage)
    if not 0 <= reflection_index < 32:
        raise ValueError("sampler reflection index is outside the five-bit fetch slot")
    slot_base = 16 if legacy and stage is ShaderStage.VERTEX else 0
    expected_instruction_index = reflection_index + slot_base
    if instruction_index is None:
        instruction_index = expected_instruction_index
    if instruction_index != expected_instruction_index:
        raise ValueError(
            f"sampler slot mismatch: reflection {reflection_index} expects "
            f"instruction slot {expected_instruction_index}, got {instruction_index}"
        )
    index_bytes = reflection_index * 4
    return SamplerBinding(
        reflection_index,
        instruction_index,
        index_bytes,
        SHARED_DIMENSION_STRIDE + index_bytes,
        2 * SHARED_DIMENSION_STRIDE + index_bytes,
        SHARED_SAMPLER_BASE + index_bytes,
    )


def make_vertex_input_bindings(
    elements: Iterable[tuple[int, int, int]],
) -> tuple[VertexInputBinding, ...]:
    """Preserve declaration ordinal and fetch address as separate identities.

    ``elements`` contains ``(fetch_instruction_address, usage, usage_index)``.
    COD3 has repeated semantic pairs at different fetch addresses.  A duplicate
    address is rejected because collapsing it would make two microcode fetches
    alias an input silently.
    """

    result: list[VertexInputBinding] = []
    seen: set[int] = set()
    for location, (address, usage, usage_index) in enumerate(elements):
        if not 0 <= address < 4096:
            raise ValueError("vertex fetch address is outside the 12-bit address field")
        if address in seen:
            raise ValueError(f"duplicate vertex fetch address {address}")
        seen.add(address)
        result.append(VertexInputBinding(address, usage, usage_index, location, f"iFetch{address}"))
    return tuple(result)


def decode_fetch_word4(word: int) -> FetchWord4:
    """Decode Xenia's word-4 LOD bias and per-axis exponent adjustments."""

    word &= 0xFFFFFFFF
    lod_bias_raw = _sign_extend((word >> 12) & 0x3FF, 10)
    horizontal_exponent = _sign_extend((word >> 22) & 0x1F, 5)
    vertical_exponent = _sign_extend((word >> 27) & 0x1F, 5)
    return FetchWord4(
        lod_bias_raw,
        lod_bias_raw / 32.0,
        horizontal_exponent,
        vertical_exponent,
    )


def instruction_lod_bias(raw: int) -> float:
    """Decode the signed seven-bit instruction LOD bias (1/16 increments)."""

    return _sign_extend(raw & 0x7F, 7) / 16.0


def effective_lod(
    fetch_word4: int,
    *,
    register_lod: float = 0.0,
    instruction_bias_raw: int = 0,
    include_fetch_bias: bool = True,
) -> float:
    """Return the additive explicit LOD used by Xenia's texture path."""

    decoded = decode_fetch_word4(fetch_word4)
    return (
        register_lod
        + instruction_lod_bias(instruction_bias_raw)
        + (decoded.lod_bias if include_fetch_bias else 0.0)
    )


def explicit_gradient_scales(
    fetch_word4: int,
    *,
    register_lod: float = 0.0,
    instruction_bias_raw: int = 0,
) -> tuple[float, float]:
    """Return Xenia-compatible horizontal/vertical SampleGrad scales."""

    word4 = decode_fetch_word4(fetch_word4)
    lod = effective_lod(
        fetch_word4,
        register_lod=register_lod,
        instruction_bias_raw=instruction_bias_raw,
    )
    return (
        math.pow(2.0, lod + word4.horizontal_exponent),
        math.pow(2.0, lod + word4.vertical_exponent),
    )


def cube_project(direction: Sequence[float]) -> CubeProjection:
    """Project a cube direction using Xenia's ALU cube tie-breaking order."""

    if len(direction) != 3:
        raise ValueError("cube direction must have three components")
    x, y, z = (float(component) for component in direction)
    if not all(math.isfinite(component) for component in (x, y, z)):
        raise ValueError("cube direction must be finite")
    ax, ay, az = abs(x), abs(y), abs(z)
    if az >= ax and az >= ay:
        return CubeProjection(-y, -x if z < 0.0 else x, 2.0 * z, 5 if z < 0.0 else 4)
    if ay >= ax:
        return CubeProjection(-z if y < 0.0 else z, x, 2.0 * y, 3 if y < 0.0 else 2)
    return CubeProjection(-y, z if x < 0.0 else -z, 2.0 * x, 1 if x < 0.0 else 0)


def cube_coord_from_projection(projection: CubeProjection) -> tuple[float, float, float]:
    """Encode TC/SC into the documented 1..2 cube fetch coordinate range."""

    return (1.5 + 0.5 * projection.tc, 1.5 + 0.5 * projection.sc, float(projection.face))


def cube_direction(coord: Sequence[float]) -> tuple[float, float, float]:
    """Inverse of the legacy TC/SC/face projection.

    The component order is deliberately TC, SC, face, matching Xenia's
    ``cube`` ALU result and its fetch remapping.  This is the isolated candidate
    for the active helper, whose current implementation uses the opposite
    order in all three axis cases.
    """

    if len(coord) != 3:
        raise ValueError("cube coordinate must have three components")
    tc, sc, face_value = (float(component) for component in coord)
    if not all(math.isfinite(component) for component in (tc, sc, face_value)):
        raise ValueError("cube coordinate must be finite")
    if not 1.0 <= tc <= 2.0 or not 1.0 <= sc <= 2.0:
        raise ValueError("cube TC/SC are outside the documented 1..2 range")
    face = math.floor(face_value)
    if not 0 <= face <= 5:
        raise ValueError("cube face is outside 0..5")
    st_tc, st_sc = 2.0 * tc - 3.0, 2.0 * sc - 3.0
    negative = face & 1
    axis = face >> 1
    if axis == 0:
        return (-1.0 if negative else 1.0, -st_tc, st_sc if negative else -st_sc)
    if axis == 1:
        return (st_sc, -1.0 if negative else 1.0, -st_tc if negative else st_tc)
    return (-st_sc if negative else st_sc, -st_tc, -1.0 if negative else 1.0)


def _u32be(blob: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(blob):
        raise ValueError("big-endian word is outside supplied bytes")
    return struct.unpack_from(">I", blob, offset)[0]


def _load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def _parse_hex_flags(value: str) -> int:
    return int(value, 16)


def _artifact_entry_key(path: str) -> tuple[str, str]:
    name = Path(path).name
    match = re.match(r"(?:pixel|vertex)_([0-9a-f]{64})_(single|primary|secondary)\.hlsl$", name)
    if not match:
        raise ValueError(f"unexpected XenosRecomp HLSL artifact name: {name}")
    return match.group(1), match.group(2)


def audit_workspace(root: Path) -> dict:
    """Audit recorded corpus and generated artifacts without executing a game."""

    root = root.resolve()
    manifest = _load_json(root / "analysis/graphics-prepared/manifest.json")
    texture_inventory = _load_json(root / "analysis/graphics-texture-feature-inventory.json")
    codegen = _load_json(root / "docs/reports/xenos-cod3-shaders.json")
    legacy_layout = _load_json(root / "analysis/graphics-legacy-definition-layout.json")
    auxiliary_layout = _load_json(root / "analysis/graphics-legacy-auxiliary-layout.json")
    grass = _load_json(root / "analysis/graphics-grass-texture-fetch.json")

    shaders = manifest["shaders"]
    flags = {_shader["sha256"]: _parse_hex_flags(_shader["flags"]) for _shader in shaders}
    legacy_counts: dict[str, int] = {}
    for value in flags.values():
        variant = legacy_variant(value).value
        legacy_counts[variant] = legacy_counts.get(variant, 0) + 1

    operations: dict[str, int] = {}
    dimension_counts: dict[str, int] = {}
    sampler_slot_problems: list[dict] = []
    explicit_gradient_entries = 0
    explicit_lod_entries = 0
    cube_fetches = 0
    weight_fetches = 0
    for entry in texture_inventory["entries"]:
        entry_flags = flags.get(entry["sha256"])
        if entry_flags is None:
            raise ValueError(f"texture inventory entry is missing from prepared manifest: {entry['sha256']}")
        stage = stage_for_flags(entry_flags)
        for instruction in entry["texture_instructions"]:
            operation = instruction["operation"]
            operations[operation] = operations.get(operation, 0) + 1
            dimension = instruction.get("dimension")
            if dimension is not None:
                key = str(dimension)
                dimension_counts[key] = dimension_counts.get(key, 0) + 1
            if operation == "TextureFetch":
                if instruction.get("use_register_gradients"):
                    explicit_gradient_entries += 1
                if instruction.get("use_register_lod"):
                    explicit_lod_entries += 1
                if instruction.get("dimension") == 3:
                    cube_fetches += 1
                sampler_index = instruction["sampler_index"]
                # The six observed vertex texture fetches use slots 17 and 18;
                # SetTextureLod uses slot zero and is excluded here.
                if stage is ShaderStage.VERTEX:
                    if sampler_index < 16:
                        sampler_slot_problems.append(
                            {"sha256": entry["sha256"], "entry": entry["entry"], "slot": sampler_index}
                        )
                elif sampler_index >= 16:
                    sampler_slot_problems.append(
                        {"sha256": entry["sha256"], "entry": entry["entry"], "slot": sampler_index}
                    )
            elif operation == "GetTextureWeights":
                weight_fetches += 1

    artifact_entries = []
    for shader in codegen["shaders"]:
        hlsl = shader.get("hlsl", {})
        artifact = hlsl.get("artifact")
        artifact_entries.append(
            {
                "sha256": shader["sha256"],
                "entry": shader["entry"],
                "stage": shader["stage"],
                "passed": shader.get("passed") is True,
                "hlsl_exists": bool(artifact and Path(artifact).exists()),
                "input_unchanged": shader.get("input_unchanged") is True,
            }
        )

    dual_entries = [item for item in artifact_entries if item["entry"] in ("primary", "secondary")]
    dual_hashes = {item["sha256"] for item in dual_entries}
    return {
        "prepared_manifest_sha256": texture_inventory["source_manifest_sha256"],
        "prepared_unique_containers": manifest["unique_shader_count"],
        "prepared_pixel_containers": manifest["pixel_shader_count"],
        "prepared_vertex_containers": manifest["vertex_shader_count"],
        "legacy_flag_counts": legacy_counts,
        "legacy_definition_records": legacy_layout["definition_table_count"],
        "legacy_definition_shape_counts": legacy_layout["shape_counts"],
        "legacy_auxiliary_records": auxiliary_layout["auxiliary_shader_count"],
        "legacy_auxiliary_flag_counts": auxiliary_layout["flag_counts"],
        "texture_inventory_entries": len(texture_inventory["entries"]),
        "texture_operation_counts": operations,
        "texture_dimension_counts": dimension_counts,
        "texture_feature_counts": texture_inventory["summary"]["texture_feature_instruction_counts"],
        "explicit_gradient_fetches": explicit_gradient_entries,
        "explicit_lod_fetches": explicit_lod_entries,
        "cube_fetches": cube_fetches,
        "weight_fetches": weight_fetches,
        "sampler_slot_problems": sampler_slot_problems,
        "grass_lod_entries": len(grass["entries"]),
        "grass_lod_fetches": sum(
            1
            for item in grass["entries"]
            for instruction in item["texture_instructions"]
            if instruction["opcode"] == 1 and instruction["use_register_lod"]
        ),
        "codegen_summary": codegen["summary"],
        "codegen_artifacts": artifact_entries,
        "codegen_dual_hashes": len(dual_hashes),
        "codegen_semantics_verified": codegen["semantics_verified"],
    }


def iter_hlsl_helper_calls(path: Path) -> Iterator[str]:
    """Yield helper calls from a generated HLSL file for a tiny audit utility."""

    text = path.read_text(encoding="utf-8")
    yield from re.findall(r"\b(tf(?:etch|etch)|getWeights\w*|cube\w*CoD3)\s*\(", text)
