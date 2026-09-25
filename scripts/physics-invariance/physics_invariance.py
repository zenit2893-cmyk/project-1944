"""Compare authoritative Call of Duty 3 captures at 60 and 120 Hz.

The input is a strict, NDJSON extension of ``cod3-timing-v1``.  It keeps the
timing-trace contract for ``sim``, ``frame`` and ``event`` records and adds
optional ``input`` and ``state`` records.  A capture is only evidence of the
fields that were actually recorded.  This tool never changes guest timing,
patches a build, or turns a Present counter into a simulation tick.

Python 3.10+; standard library only.  Synthetic fixtures are useful for
testing the comparator and are never reported as gameplay validation.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import sys
from typing import Any


SCHEMA = "cod3-physics-invariance-v1"
TIMING_SCHEMA = "cod3-timing-v1"
EVENT_CATEGORIES = ("movement", "fire", "ai", "animation", "script", "cutscene")
EVENT_CATEGORY_SET = set(EVENT_CATEGORIES)
STATE_DOMAINS = EVENT_CATEGORY_SET | {"world"}
REQUIRED_CVARS = ("com_maxfps", "pmove_msec", "timescale", "fixedtime")

# These addresses come from analysis/timing-native-evidence.json.  They are
# string anchors, not writable locations and not proof of live cvar values.
STATIC_ANCHORS = {
    "pmove_msec": "0x82065B68",
    "timescale": "0x82066288",
    "com_maxfps": "0x82068764",
    "fixedtime": "0x82068798",
}

IDENTITY_FIELDS = (
    "scenario",
    "input_sha256",
    "checkpoint_sha256",
    "rng_seed",
    "guest_tick_frequency_hz",
    "guest_time_scalar",
    "timing_schema",
    "state_schema",
    "title_id",
    "media_id",
    "source_xex_sha256",
)


class CaptureError(ValueError):
    """Raised when a capture is incomplete or violates the capture contract."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise CaptureError(message)


def _reject_constant(value: str) -> None:
    raise CaptureError(f"non-finite JSON constant: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        _require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _number(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def _integer(record: dict[str, Any], key: str, minimum: int = 0) -> int:
    value = record.get(key)
    _require(type(value) is int and value >= minimum,
             f"{key}: expected integer >= {minimum}")
    return value


def _nonempty_string(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    _require(isinstance(value, str) and bool(value.strip()),
             f"{key}: expected a nonempty string")
    return value


def _digest(record: dict[str, Any], key: str) -> str:
    value = _nonempty_string(record, key)
    _require(re.fullmatch(r"[0-9a-fA-F]{64}", value) is not None,
             f"{key}: expected a SHA-256 hex digest")
    return value.lower()


def _observable_values(record: dict[str, Any], key: str = "values") -> dict[str, Any]:
    values = record.get(key)
    _require(isinstance(values, dict) and bool(values),
             f"{key}: nonempty observable map required")
    for name, value in values.items():
        _require(isinstance(name, str) and bool(name) and "." not in name,
                 f"{key} names must be nonempty strings without dots")
        _require(_number(value) or type(value) in (str, bool),
                 f"{key}.{name}: only finite numbers, strings, or booleans allowed")
    return values


def _load_json_lines(path: Path) -> tuple[list[dict[str, Any]], str]:
    try:
        raw = path.read_bytes()
        text = raw.decode("utf-8-sig")
    except (OSError, UnicodeError) as error:
        raise CaptureError(f"{path}: cannot read UTF-8 NDJSON: {error}") from error
    rows: list[dict[str, Any]] = []
    for line_no, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line, parse_constant=_reject_constant,
                             object_pairs_hook=_reject_duplicate_keys)
        except (ValueError, TypeError, CaptureError) as error:
            raise CaptureError(f"{path}:{line_no}: {error}") from error
        _require(isinstance(row, dict), f"{path}:{line_no}: record must be an object")
        rows.append(row)
    _require(rows, f"{path}: empty capture")
    return rows, hashlib.sha256(raw).hexdigest()


def _validate_static_anchors(metadata: dict[str, Any]) -> dict[str, str]:
    anchors = metadata.get("static_anchors")
    _require(isinstance(anchors, list) and bool(anchors),
             "metadata.static_anchors must be a nonempty list")
    found: dict[str, str] = {}
    for index, anchor in enumerate(anchors):
        _require(isinstance(anchor, dict),
                 f"metadata.static_anchors[{index}] must be an object")
        name = _nonempty_string(anchor, "name")
        address = _nonempty_string(anchor, "address")
        _require(name not in found, f"duplicate static anchor: {name}")
        found[name] = address
        if name in STATIC_ANCHORS:
            _require(address.upper() == STATIC_ANCHORS[name].upper(),
                     f"static anchor {name} address differs from evidence")
            _require(anchor.get("nul_terminated_bytes_match") is True,
                     f"static anchor {name} is not verified in evidence")
    for name, address in STATIC_ANCHORS.items():
        _require(found.get(name, "").upper() == address.upper(),
                 f"required static anchor missing: {name}")
    return found


def load_anchor_manifest(path: Path) -> dict[str, Any]:
    """Load and verify the checked-in static timing evidence manifest."""

    try:
        raw = path.read_bytes()
        manifest = json.loads(raw.decode("utf-8-sig"),
                              parse_constant=_reject_constant,
                              object_pairs_hook=_reject_duplicate_keys)
    except (OSError, UnicodeError, ValueError, TypeError, CaptureError) as error:
        raise CaptureError(f"{path}: invalid static anchor manifest: {error}") from error
    _require(isinstance(manifest, dict), "static anchor manifest must be an object")
    _require(manifest.get("schema") == "cod3-static-timing-evidence-v1",
             "static anchor manifest has an unexpected schema")
    anchors = manifest.get("anchors")
    _require(isinstance(anchors, list), "static anchor manifest anchors must be a list")
    found = {}
    for anchor in anchors:
        _require(isinstance(anchor, dict), "static anchor entry must be an object")
        name = _nonempty_string(anchor, "name")
        found[name] = _nonempty_string(anchor, "address")
        if name in STATIC_ANCHORS:
            _require(found[name].upper() == STATIC_ANCHORS[name].upper(),
                     f"manifest address differs for {name}")
            _require(anchor.get("nul_terminated_bytes_match") is True,
                     f"manifest anchor is not verified for {name}")
    for name, address in STATIC_ANCHORS.items():
        _require(found.get(name, "").upper() == address.upper(),
                 f"manifest missing required anchor {name}")
    return {
        "path": str(path.resolve()),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "schema": manifest["schema"],
        "anchors": found,
    }


def _validate_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
    _require(metadata.get("kind") == "metadata", "first record must be metadata")
    _require(metadata.get("schema") == SCHEMA,
             f"first record must use {SCHEMA}")
    _require(metadata.get("capture_source") in ("game", "synthetic"),
             "metadata.capture_source must be game or synthetic")
    _require(metadata.get("timing_schema") == TIMING_SCHEMA,
             "metadata.timing_schema must be cod3-timing-v1")
    for key in ("scenario", "run_id", "instrumentation_id", "state_schema",
                "title_id", "media_id"):
        _nonempty_string(metadata, key)
    for key in ("executable_sha256", "input_sha256", "checkpoint_sha256",
                "source_xex_sha256"):
        metadata[key] = _digest(metadata, key)
    sdk_commit = _nonempty_string(metadata, "sdk_commit")
    _require(re.fullmatch(r"[0-9a-fA-F]{40}", sdk_commit) is not None,
             "metadata.sdk_commit must be a full 40-character commit")
    metadata["sdk_commit"] = sdk_commit.lower()
    _integer(metadata, "rng_seed")
    _integer(metadata, "guest_tick_frequency_hz", 1)
    _require(_number(metadata.get("guest_time_scalar"))
             and metadata["guest_time_scalar"] > 0,
             "metadata.guest_time_scalar must be finite and positive")
    render_target = _integer(metadata, "render_target_hz", 1)
    _require(render_target in (60, 120),
             "metadata.render_target_hz must be 60 or 120")
    for key in ("start_host_ns", "start_sim_ns", "start_tick"):
        _integer(metadata, key)
    expected = metadata.get("expected_categories")
    _require(isinstance(expected, list) and bool(expected),
             "metadata.expected_categories must be a nonempty list")
    _require(len(expected) == len(set(expected)),
             "metadata.expected_categories contains duplicates")
    _require(all(category in EVENT_CATEGORY_SET for category in expected),
             "metadata.expected_categories contains an unknown category")
    _require(set(expected) == EVENT_CATEGORY_SET,
             "full invariance captures must declare all six event categories")
    metadata["expected_categories"] = list(expected)

    cvars = metadata.get("cvars")
    _require(isinstance(cvars, dict), "metadata.cvars must be an object")
    for key in REQUIRED_CVARS:
        _require(key in cvars, f"metadata.cvars.{key} is required")
    for key in ("com_maxfps", "pmove_msec", "fixedtime"):
        _require(type(cvars[key]) is int and cvars[key] >= 0,
                 f"metadata.cvars.{key} must be a nonnegative integer")
    _require(_number(cvars["timescale"]) and cvars["timescale"] > 0,
             "metadata.cvars.timescale must be finite and positive")
    _require(cvars["com_maxfps"] > 0, "metadata.cvars.com_maxfps must be positive")
    _require(cvars["pmove_msec"] > 0, "metadata.cvars.pmove_msec must be positive")

    for key in ("input_log_mode", "state_log_mode"):
        _require(metadata.get(key) in ("embedded_exact", "digest_only", "sim_values_only"),
                 f"metadata.{key} is invalid")
    _require(metadata["input_log_mode"] in ("embedded_exact", "digest_only"),
             "metadata.input_log_mode must be embedded_exact or digest_only")
    _require(metadata["state_log_mode"] in ("embedded_exact", "sim_values_only"),
             "metadata.state_log_mode must be embedded_exact or sim_values_only")
    _validate_static_anchors(metadata)
    return metadata


def _check_tick_time(row: dict[str, Any], ticks: dict[int, int],
                     start_tick: int, start_sim_ns: int, label: str) -> tuple[int, int]:
    tick = _integer(row, "tick")
    sim_ns = _integer(row, "sim_ns")
    _require(tick >= start_tick, f"{label}: tick precedes capture start")
    if tick == start_tick:
        _require(sim_ns == start_sim_ns, f"{label}: start tick has wrong sim_ns")
    else:
        _require(tick in ticks, f"{label}: references an uncommitted simulation tick")
        _require(sim_ns == ticks[tick], f"{label}: sim_ns does not match simulation tick")
    return tick, sim_ns


def load_capture(path: Path, anchor_manifest: dict[str, Any] | None = None) -> dict[str, Any]:
    """Parse one complete authoritative capture.

    ``anchor_manifest`` is optional for library callers.  Metadata anchors are
    always checked; passing the checked-in manifest additionally verifies that
    the capture points at the current static evidence file.
    """

    path = Path(path)
    rows, trace_sha256 = _load_json_lines(path)
    _require(len(rows) >= 4,
             "capture needs metadata, simulation, frame and end records")
    metadata = _validate_metadata(rows[0])
    end = rows[-1]
    _require(end.get("kind") == "end" and end.get("capture_complete") is True,
             "complete end record missing; partial captures cannot be compared")
    for key in ("dropped_records", "qpc_failures"):
        if key in end:
            _require(type(end[key]) is int and end[key] == 0,
                     f"end.{key} must be zero for a complete capture")
    host_previous = metadata["start_host_ns"]
    sim_previous = metadata["start_sim_ns"]
    tick_previous = metadata["start_tick"]
    present_previous = -1
    render_previous = -1
    input_sequence_previous = -1
    ticks: dict[int, int] = {}
    sims: list[dict[str, Any]] = []
    states: list[dict[str, Any]] = []
    inputs: list[dict[str, Any]] = []
    frames: list[dict[str, Any]] = []
    events: list[dict[str, Any]] = []
    state_keys: set[tuple[int, str, str]] = set()
    input_sequences: set[int] = set()

    for record_number, row in enumerate(rows[1:], 2):
        host_ns = _integer(row, "host_ns")
        _require(host_ns >= host_previous,
                 f"record {record_number}: host_ns is not monotonic")
        host_previous = host_ns
        kind = row.get("kind")
        if kind == "sim":
            tick = _integer(row, "tick")
            sim_ns = _integer(row, "sim_ns")
            dt_ns = _integer(row, "dt_ns", 1)
            _require(tick == tick_previous + 1,
                     f"record {record_number}: simulation tick is missing or repeated")
            _require(sim_ns == sim_previous + dt_ns,
                     f"record {record_number}: sim_ns/dt_ns are inconsistent")
            _observable_values(row)
            ticks[tick] = sim_ns
            sims.append(row)
            tick_previous, sim_previous = tick, sim_ns
        elif kind == "input":
            tick, sim_ns = _check_tick_time(
                row, ticks, metadata["start_tick"], metadata["start_sim_ns"],
                f"record {record_number}")
            sequence = _integer(row, "sequence")
            _require(sequence > input_sequence_previous,
                     f"record {record_number}: input sequence is not increasing")
            _require(sequence not in input_sequences,
                     f"record {record_number}: duplicate input sequence")
            input_sequences.add(sequence)
            input_sequence_previous = sequence
            device = _nonempty_string(row, "device")
            action = _nonempty_string(row, "action")
            _require("." not in device and "." not in action,
                     f"record {record_number}: input names cannot contain dots")
            _observable_values(row)
            inputs.append({**row, "tick": tick, "sim_ns": sim_ns})
        elif kind == "state":
            tick, sim_ns = _check_tick_time(
                row, ticks, metadata["start_tick"], metadata["start_sim_ns"],
                f"record {record_number}")
            entity = _nonempty_string(row, "entity_id")
            domain = _nonempty_string(row, "domain")
            _require("." not in entity, f"record {record_number}: entity_id cannot contain dots")
            _require(domain in STATE_DOMAINS,
                     f"record {record_number}: unknown state domain {domain!r}")
            key = (tick, entity, domain)
            _require(key not in state_keys,
                     f"record {record_number}: duplicate state snapshot {key!r}")
            state_keys.add(key)
            _observable_values(row)
            states.append({**row, "tick": tick, "sim_ns": sim_ns})
        elif kind == "frame":
            present_id = _integer(row, "present_id")
            render_id = _integer(row, "render_id")
            sim_tick = _integer(row, "sim_tick")
            _require(present_id > present_previous,
                     f"record {record_number}: present_id must increase")
            _require(render_id >= render_previous,
                     f"record {record_number}: render_id must not go backwards")
            _require(metadata["start_tick"] <= sim_tick <= tick_previous,
                     f"record {record_number}: frame references an uncommitted tick")
            _require(row.get("render_mode") in ("native_scene", "interpolated_scene"),
                     f"record {record_number}: invalid render_mode")
            present_previous, render_previous = present_id, render_id
            frames.append(row)
        elif kind == "event":
            tick, sim_ns = _check_tick_time(
                row, ticks, metadata["start_tick"], metadata["start_sim_ns"],
                f"record {record_number}")
            category = row.get("category")
            _require(category in EVENT_CATEGORY_SET,
                     f"record {record_number}: unknown event category {category!r}")
            name = _nonempty_string(row, "name")
            _require("." not in name, f"record {record_number}: event name cannot contain dots")
            if "entity_id" in row:
                entity = _nonempty_string(row, "entity_id")
                _require("." not in entity,
                         f"record {record_number}: event entity_id cannot contain dots")
            _observable_values(row)
            events.append({**row, "tick": tick, "sim_ns": sim_ns})
        elif kind == "end":
            _require(record_number == len(rows), "end record must be last")
            _require(_integer(row, "tick") == tick_previous,
                     "end.tick does not match the last simulation tick")
            _require(_integer(row, "sim_ns") == sim_previous,
                     "end.sim_ns does not match the last simulation tick")
        else:
            raise CaptureError(f"record {record_number}: unsupported kind {kind!r}")
    _require(sims and frames, "simulation and frame samples are required")
    _require(_integer(end, "host_ns") > metadata["start_host_ns"],
             "capture host duration must be positive")
    if metadata["input_log_mode"] == "embedded_exact":
        _require(inputs, "embedded_exact input log has no input records")
    else:
        _require(not inputs, "digest_only capture must not contain input records")
    if metadata["state_log_mode"] == "embedded_exact":
        _require(states, "embedded_exact state log has no state records")
    else:
        _require(not states, "sim_values_only capture must not contain state records")
    manifest_summary = None
    if anchor_manifest is not None:
        manifest_summary = anchor_manifest
        declared = metadata.get("static_anchor_manifest_sha256")
        if declared is not None:
            _require(isinstance(declared, str)
                     and declared.lower() == anchor_manifest["sha256"].lower(),
                     "metadata.static_anchor_manifest_sha256 differs from supplied manifest")
    return {
        "path": str(path.resolve()),
        "sha256": trace_sha256,
        "metadata": metadata,
        "end": end,
        "sim": sims,
        "state": states,
        "input": inputs,
        "frame": frames,
        "event": events,
        "ticks": ticks,
        "anchor_manifest": manifest_summary,
    }


def _percentile(samples: list[int], fraction: float) -> int | None:
    if not samples:
        return None
    ordered = sorted(samples)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


def render_metrics(capture: dict[str, Any]) -> dict[str, Any]:
    metadata, end = capture["metadata"], capture["end"]
    duration_ns = end["host_ns"] - metadata["start_host_ns"]
    unique_frames: list[dict[str, Any]] = []
    last_render_id: int | None = None
    for frame in capture["frame"]:
        if frame["render_id"] != last_render_id:
            unique_frames.append(frame)
            last_render_id = frame["render_id"]
    intervals = [b["host_ns"] - a["host_ns"]
                 for a, b in zip(unique_frames, unique_frames[1:])]
    target = metadata["render_target_hz"]
    budget_ns = math.ceil(1_000_000_000 / target)
    unique_rate = len(unique_frames) * 1_000_000_000 / duration_ns
    present_rate = len(capture["frame"]) * 1_000_000_000 / duration_ns
    return {
        "target_hz": target,
        "duration_seconds": duration_ns / 1_000_000_000,
        "present_count": len(capture["frame"]),
        "unique_scene_render_count": len(unique_frames),
        "repeated_present_count": len(capture["frame"]) - len(unique_frames),
        "present_rate_hz": present_rate,
        "unique_scene_render_rate_hz": unique_rate,
        "mean_scene_render_rate_reaches_target": unique_rate >= target,
        "scene_interval_ms": {
            "p50": None if _percentile(intervals, .50) is None else _percentile(intervals, .50) / 1e6,
            "p95": None if _percentile(intervals, .95) is None else _percentile(intervals, .95) / 1e6,
            "p99": None if _percentile(intervals, .99) is None else _percentile(intervals, .99) / 1e6,
            "max": None if not intervals else max(intervals) / 1e6,
            "target_budget_ms": budget_ns / 1e6,
            "over_target_budget_count": sum(interval > budget_ns for interval in intervals),
        },
        "display_scanout_verified": False,
    }


def _value_tolerance(tolerances: dict[str, float], *paths: str) -> float:
    for path in paths:
        if path in tolerances:
            return tolerances[path]
    return 0.0


def _compare_values(left: dict[str, Any], right: dict[str, Any],
                   tolerances: dict[str, float], paths: tuple[str, ...],
                   add_issue) -> None:
    if set(left) != set(right):
        add_issue("observable keys differ", "value", paths[0], left, right)
    for key in sorted(set(left) & set(right)):
        a, b = left[key], right[key]
        tolerance = _value_tolerance(tolerances, *(f"{path}.{key}" for path in paths))
        if _number(a) and _number(b):
            if abs(a - b) > tolerance:
                add_issue(f"{key} differs ({a!r} vs {b!r})", "value",
                          f"{paths[0]}.{key}", a, b)
        elif type(a) is not type(b) or a != b:
            add_issue(f"{key} differs ({a!r} vs {b!r})", "value",
                      f"{paths[0]}.{key}", a, b)


def _logical_input(row: dict[str, Any]) -> tuple[Any, ...]:
    return (row["sequence"], row["tick"], row["sim_ns"], row["device"],
            row["action"], row["values"])


def _logical_event(row: dict[str, Any]) -> tuple[Any, ...]:
    return (row["category"], row["name"], row["tick"], row["sim_ns"],
            row.get("entity_id"), row["values"])


def _logical_state(row: dict[str, Any]) -> tuple[Any, ...]:
    return (row["tick"], row["sim_ns"], row["entity_id"], row["domain"], row["values"])


def compare_captures(baseline: dict[str, Any], candidate: dict[str, Any],
                     tolerances: dict[str, float] | None = None) -> dict[str, Any]:
    """Compare a 60-Hz baseline with a 120-Hz candidate.

    The two captures may have different executable hashes.  Shared identity is
    the original XEX, scenario, checkpoint, exact input digest and seed.  The
    executable hash is retained in the report for audit but is intentionally
    not an invariant when comparing a recompiled build with an original run.
    """

    tolerances = tolerances or {}
    issues: list[str] = []
    differences: list[dict[str, Any]] = []
    incomplete: list[str] = []

    def add_issue(message: str, kind: str = "contract", path: str | None = None,
                  left: Any = None, right: Any = None) -> None:
        if len(issues) < 200:
            issues.append(message)
        difference: dict[str, Any] = {"kind": kind, "message": message}
        if path is not None:
            difference["path"] = path
        if left is not None or right is not None:
            difference["baseline"] = left
            difference["candidate"] = right
        if len(differences) < 200:
            differences.append(difference)

    base_meta, cand_meta = baseline["metadata"], candidate["metadata"]
    for field in IDENTITY_FIELDS:
        if base_meta[field] != cand_meta[field]:
            add_issue(f"metadata differs: {field}", "identity", f"metadata.{field}",
                      base_meta[field], cand_meta[field])
    if base_meta["render_target_hz"] != 60:
        add_issue("baseline must declare render_target_hz=60", "contract")
    if cand_meta["render_target_hz"] != 120:
        add_issue("candidate must declare render_target_hz=120", "contract")
    for label, metadata in (("baseline", base_meta), ("candidate", cand_meta)):
        if metadata["cvars"]["com_maxfps"] != metadata["render_target_hz"]:
            add_issue(f"{label}: cvars.com_maxfps does not match render target",
                      "cvar", f"{label}.cvars.com_maxfps",
                      metadata["cvars"]["com_maxfps"], metadata["render_target_hz"])
    for key in ("pmove_msec", "timescale", "fixedtime"):
        if base_meta["cvars"][key] != cand_meta["cvars"][key]:
            add_issue(f"cvar differs: {key}", "cvar", f"cvars.{key}",
                      base_meta["cvars"][key], cand_meta["cvars"][key])
    # Also expose extra controls that could make the two runs incomparable.
    # The four required controls were handled above, and com_maxfps is the
    # one intentional render-target difference.
    for key in (set(base_meta["cvars"]) | set(cand_meta["cvars"])) - set(REQUIRED_CVARS):
        if key not in base_meta["cvars"] or key not in cand_meta["cvars"]:
            add_issue(f"cvar is missing from one capture: {key}", "cvar", f"cvars.{key}")
        elif base_meta["cvars"][key] != cand_meta["cvars"][key]:
            add_issue(f"cvar differs: {key}", "cvar", f"cvars.{key}",
                      base_meta["cvars"][key], cand_meta["cvars"][key])

    # Exact input logs are compared by logical fields; host timestamps are
    # diagnostic and may differ between two runs.
    if base_meta["input_log_mode"] != "embedded_exact" or cand_meta["input_log_mode"] != "embedded_exact":
        incomplete.append("exact input records are unavailable in one or both captures")
    else:
        if len(baseline["input"]) != len(candidate["input"]):
            add_issue("input record count differs", "input",
                      "input.count", len(baseline["input"]), len(candidate["input"]))
        for index, (left, right) in enumerate(zip(baseline["input"], candidate["input"])):
            if _logical_input(left) != _logical_input(right):
                add_issue(f"input record {index} differs", "input", f"input[{index}]",
                          _logical_input(left), _logical_input(right))

    # The authoritative simulation timeline must be identical.  This is the
    # key guard against a 120-Hz renderer silently running gameplay twice as
    # fast or using a different quantisation step.
    if len(baseline["sim"]) != len(candidate["sim"]):
        add_issue("simulation tick count differs", "simulation", "sim.count",
                  len(baseline["sim"]), len(candidate["sim"]))
    for index, (left, right) in enumerate(zip(baseline["sim"], candidate["sim"])):
        path = f"sim[{index}]"
        for key in ("tick", "sim_ns", "dt_ns"):
            if left[key] != right[key]:
                add_issue(f"{path}: authoritative simulation timeline differs",
                          "simulation", f"{path}.{key}", left[key], right[key])
        _compare_values(left["values"], right["values"], tolerances,
                        ("sim", path), add_issue)

    if base_meta["state_log_mode"] != "embedded_exact" or cand_meta["state_log_mode"] != "embedded_exact":
        incomplete.append("per-entity state records are unavailable in one or both captures; sim values are the only state evidence")
    else:
        left_states = sorted(baseline["state"], key=lambda row: (row["tick"], row["entity_id"], row["domain"]))
        right_states = sorted(candidate["state"], key=lambda row: (row["tick"], row["entity_id"], row["domain"]))
        if len(left_states) != len(right_states):
            add_issue("state snapshot count differs", "state", "state.count",
                      len(left_states), len(right_states))
        for index, (left, right) in enumerate(zip(left_states, right_states)):
            identity = ("tick", "sim_ns", "entity_id", "domain")
            if any(left[key] != right[key] for key in identity):
                add_issue(f"state snapshot {index} identity differs", "state",
                          f"state[{index}]", _logical_state(left)[:4], _logical_state(right)[:4])
            _compare_values(left["values"], right["values"], tolerances,
                            ("state", f"state.{left['domain']}", f"state.{left['domain']}.{left['entity_id']}"),
                            add_issue)

    # Event ordering and simulation time are authoritative.  Renderer cadence
    # must not duplicate fire, AI, animation, script or cutscene events.
    base_counts = Counter(row["category"] for row in baseline["event"])
    cand_counts = Counter(row["category"] for row in candidate["event"])
    missing_base = sorted(EVENT_CATEGORY_SET - base_counts.keys())
    missing_cand = sorted(EVENT_CATEGORY_SET - cand_counts.keys())
    if missing_base:
        incomplete.append(f"baseline lacks event categories: {', '.join(missing_base)}")
    if missing_cand:
        incomplete.append(f"candidate lacks event categories: {', '.join(missing_cand)}")
    if not missing_base and not missing_cand:
        if len(baseline["event"]) != len(candidate["event"]):
            add_issue("gameplay event count differs", "event", "event.count",
                      len(baseline["event"]), len(candidate["event"]))
        for index, (left, right) in enumerate(zip(baseline["event"], candidate["event"])):
            if _logical_event(left)[:5] != _logical_event(right)[:5]:
                add_issue(f"event {index} order or simulation time differs", "event",
                          f"event[{index}]", _logical_event(left)[:5], _logical_event(right)[:5])
            _compare_values(left["values"], right["values"], tolerances,
                            (f"event.{left['category']}.{left['name']}",), add_issue)
    else:
        # A category gap makes global event order unanswerable.  Compare the
        # categories that are present so a second regression is still visible,
        # while keeping the result INCOMPLETE_COVERAGE for the missing probe.
        for category in sorted(EVENT_CATEGORY_SET - set(missing_base) - set(missing_cand)):
            left_events = [row for row in baseline["event"] if row["category"] == category]
            right_events = [row for row in candidate["event"] if row["category"] == category]
            if len(left_events) != len(right_events):
                add_issue(f"{category} event count differs", "event",
                          f"event.{category}.count", len(left_events), len(right_events))
            for index, (left, right) in enumerate(zip(left_events, right_events)):
                if _logical_event(left)[:5] != _logical_event(right)[:5]:
                    add_issue(f"{category} event {index} simulation identity differs", "event",
                              f"event.{category}[{index}]", _logical_event(left)[:5],
                              _logical_event(right)[:5])
                _compare_values(left["values"], right["values"], tolerances,
                                (f"event.{category}.{left['name']}",), add_issue)

    base_render = render_metrics(baseline)
    cand_render = render_metrics(candidate)
    if not base_render["mean_scene_render_rate_reaches_target"]:
        add_issue("baseline does not reach its declared 60-Hz scene-render target",
                  "render", "baseline.render_rate", base_render["unique_scene_render_rate_hz"], 60)
    if not cand_render["mean_scene_render_rate_reaches_target"]:
        add_issue("candidate does not reach its declared 120-Hz scene-render target",
                  "render", "candidate.render_rate", cand_render["unique_scene_render_rate_hz"], 120)
    if baseline["anchor_manifest"] is None or candidate["anchor_manifest"] is None:
        incomplete.append("static anchor manifest was not supplied for both captures")

    if issues:
        result = "INVARIANCE_FAILED"
    elif incomplete:
        result = "INCOMPLETE_COVERAGE"
    elif base_meta["capture_source"] == "synthetic" or cand_meta["capture_source"] == "synthetic":
        result = "SYNTHETIC_CHECK_ONLY"
    else:
        result = "OBSERVED_FIELDS_MATCH_120FPS_UNCERTIFIED"
    return {
        "schema": "cod3-physics-invariance-report-v1",
        "tool_integration": "OFFLINE_ONLY",
        "result": result,
        "gameplay_120fps_verified": False,
        "physics_invariance_verified": result == "OBSERVED_FIELDS_MATCH_120FPS_UNCERTIFIED",
        "provenance_independently_verified": False,
        "scope": "Only recorded authoritative fields and declared render metrics are compared; full gameplay, probe completeness, visual correctness and display scanout remain outside this report.",
        "issue_count": len(issues),
        "issues": issues,
        "differences": differences,
        "incomplete_coverage": incomplete,
        "policy": {
            "simulation_time_comparison": "exact",
            "event_order_and_sim_time_comparison": "exact",
            "input_comparison": "exact logical records, host_ns ignored",
            "state_numeric_tolerances": tolerances,
            "render_metric": "unique render_id scene builds; repeated Present excluded",
            "static_anchor_addresses": STATIC_ANCHORS,
        },
        "baseline": {
            "path": baseline["path"],
            "sha256": baseline["sha256"],
            "capture_source": base_meta["capture_source"],
            "executable_sha256": base_meta["executable_sha256"],
            "render": base_render,
            "simulation_ticks": len(baseline["sim"]),
            "input_records": len(baseline["input"]),
            "state_records": len(baseline["state"]),
            "event_categories": dict(sorted(base_counts.items())),
        },
        "candidate": {
            "path": candidate["path"],
            "sha256": candidate["sha256"],
            "capture_source": cand_meta["capture_source"],
            "executable_sha256": cand_meta["executable_sha256"],
            "render": cand_render,
            "simulation_ticks": len(candidate["sim"]),
            "input_records": len(candidate["input"]),
            "state_records": len(candidate["state"]),
            "event_categories": dict(sorted(cand_counts.items())),
        },
    }


def discover_captures(root: Path) -> list[dict[str, Any]]:
    """Discover parseable physics captures without treating hook logs as game traces."""

    found: list[dict[str, Any]] = []
    root = Path(root)
    if not root.exists():
        return found
    for path in sorted(root.rglob("*.ndjson")):
        try:
            rows, sha256 = _load_json_lines(path)
            if rows and rows[0].get("schema") == SCHEMA:
                found.append({
                    "path": str(path.resolve()),
                    "sha256": sha256,
                    "capture_source": rows[0].get("capture_source"),
                    "render_target_hz": rows[0].get("render_target_hz"),
                    "scenario": rows[0].get("scenario"),
                })
        except CaptureError:
            # Discovery is deliberately best effort; compare/load reports the
            # exact error for a selected path.
            continue
    return found


def _load_tolerances(path: Path | None) -> dict[str, float]:
    if path is None:
        return {}
    try:
        raw = path.read_bytes()
        values = json.loads(raw.decode("utf-8-sig"), parse_constant=_reject_constant,
                            object_pairs_hook=_reject_duplicate_keys)
    except (OSError, UnicodeError, ValueError, TypeError, CaptureError) as error:
        raise CaptureError(f"{path}: invalid tolerance map: {error}") from error
    _require(isinstance(values, dict), "tolerances must be a JSON object")
    for key, value in values.items():
        _require(isinstance(key, str) and bool(key.strip()),
                 "tolerance keys must be nonempty strings")
        _require(_number(value) and value >= 0,
                 f"tolerance {key!r} must be a finite nonnegative number")
    return values


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="60-Hz cod3-physics-invariance-v1 capture")
    parser.add_argument("candidate", type=Path, help="120-Hz cod3-physics-invariance-v1 capture")
    parser.add_argument("--anchor-manifest", type=Path,
                        help="checked-in analysis/timing-native-evidence.json")
    parser.add_argument("--tolerances", type=Path,
                        help="JSON map of absolute numeric field tolerances")
    parser.add_argument("--output", type=Path, help="write the JSON report here")
    args = parser.parse_args(argv)
    try:
        anchor_manifest = load_anchor_manifest(args.anchor_manifest) if args.anchor_manifest else None
        tolerances = _load_tolerances(args.tolerances)
        baseline = load_capture(args.baseline, anchor_manifest)
        candidate = load_capture(args.candidate, anchor_manifest)
        report = compare_captures(baseline, candidate, tolerances)
        status = 1 if report["result"] == "INVARIANCE_FAILED" else 0
    except (OSError, UnicodeError, ValueError, TypeError, OverflowError, CaptureError) as error:
        report = {
            "schema": "cod3-physics-invariance-report-v1",
            "tool_integration": "OFFLINE_ONLY",
            "result": "INVALID_CAPTURE_OR_POLICY",
            "gameplay_120fps_verified": False,
            "physics_invariance_verified": False,
            "error": str(error),
        }
        status = 2
    encoded = json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
