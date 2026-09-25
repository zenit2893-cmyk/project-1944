"""Compare future COD3 timing traces. This is an offline, unintegrated tool.

It does not run the game, patch clocks, infer simulation ticks from presents, or
certify gameplay. See docs/reports/timing-trace-format.md for the capture contract.
Python 3.10+; standard library only.
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

SCHEMA = "cod3-timing-v1"
CATEGORIES = {"movement", "fire", "ai", "animation", "script", "cutscene"}
IDENTITY_FIELDS = (
    "executable_sha256", "sdk_commit", "scenario", "input_sha256",
    "checkpoint_sha256", "rng_seed", "instrumentation_id", "capture_source",
    "guest_tick_frequency_hz", "guest_time_scalar", "start_tick", "start_sim_ns",
)


class TraceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise TraceError(message)


def integer(record, key, minimum=0):
    value = record.get(key)
    require(type(value) is int and value >= minimum, f"{key}: expected integer >= {minimum}")
    return value


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def values(record):
    result = record.get("values")
    require(isinstance(result, dict) and result, "values: nonempty observable map required")
    for key, value in result.items():
        require(isinstance(key, str) and key and "." not in key,
                "observable names must be nonempty strings without dots")
        require(number(value) or type(value) in (str, bool),
                f"values.{key}: only finite numbers, strings, or booleans allowed")
    return result


def reject_constant(value):
    raise TraceError(f"non-finite JSON constant: {value}")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_trace(path):
    path = Path(path)
    raw = path.read_bytes()
    rows = []
    for line_no, line in enumerate(raw.decode("utf-8-sig").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line, parse_constant=reject_constant,
                             object_pairs_hook=reject_duplicate_keys)
            require(isinstance(row, dict), "record must be a JSON object")
            rows.append(row)
        except (ValueError, TypeError) as error:
            raise TraceError(f"{path}:{line_no}: {error}") from error
    require(len(rows) >= 4, "trace needs metadata, simulation, frame, and end records")
    meta, end = rows[0], rows[-1]
    require(meta.get("kind") == "metadata" and meta.get("schema") == SCHEMA,
            f"first record must be {SCHEMA} metadata")
    require(end.get("kind") == "end" and end.get("capture_complete") is True,
            "complete end record missing; partial traces cannot be compared")
    for key in IDENTITY_FIELDS + ("run_id",):
        require(key in meta, f"metadata.{key} is required")
    for key in ("executable_sha256", "input_sha256", "checkpoint_sha256"):
        require(isinstance(meta[key], str) and re.fullmatch(r"[0-9a-fA-F]{64}", meta[key]),
                f"metadata.{key} must be a SHA-256 hex digest")
        meta[key] = meta[key].lower()
    require(isinstance(meta["sdk_commit"], str)
            and re.fullmatch(r"[0-9a-fA-F]{40}", meta["sdk_commit"]),
            "sdk_commit must be a full 40-character commit")
    meta["sdk_commit"] = meta["sdk_commit"].lower()
    for key in ("scenario", "instrumentation_id", "run_id"):
        require(isinstance(meta[key], str) and meta[key].strip(), f"metadata.{key} required")
    require(meta["capture_source"] in ("synthetic", "game"), "invalid capture_source")
    require(number(meta["guest_time_scalar"]) and meta["guest_time_scalar"] > 0,
            "guest_time_scalar must be finite and positive")
    integer(meta, "guest_tick_frequency_hz", 1)
    integer(meta, "rng_seed")
    host_previous = integer(meta, "start_host_ns")
    sim_previous = integer(meta, "start_sim_ns")
    tick_previous = integer(meta, "start_tick")
    present_previous = render_previous = -1
    sims, frames, events = [], [], []
    for index, row in enumerate(rows[1:], 2):
        host = integer(row, "host_ns")
        require(host >= host_previous, f"record {index}: host_ns not monotonic; merge trace first")
        host_previous = host
        kind = row.get("kind")
        if kind == "sim":
            tick, sim_ns, dt_ns = integer(row, "tick"), integer(row, "sim_ns"), integer(row, "dt_ns", 1)
            require(tick == tick_previous + 1, f"record {index}: missing or repeated simulation tick")
            require(sim_ns == sim_previous + dt_ns, f"record {index}: sim_ns/dt_ns inconsistent")
            values(row)
            tick_previous, sim_previous = tick, sim_ns
            sims.append(row)
        elif kind == "frame":
            present, render = integer(row, "present_id"), integer(row, "render_id")
            require(present > present_previous, f"record {index}: present_id must increase")
            require(render >= render_previous, f"record {index}: render_id must not go backwards")
            require(integer(row, "sim_tick") <= tick_previous,
                    f"record {index}: frame references an uncommitted simulation tick")
            require(row.get("render_mode") in ("native_scene", "interpolated_scene"),
                    "render_mode must describe a real scene render; image frame generation excluded")
            present_previous, render_previous = present, render
            frames.append(row)
        elif kind == "event":
            require(row.get("category") in CATEGORIES, f"record {index}: unknown event category")
            require(isinstance(row.get("name"), str) and row["name"] and "." not in row["name"],
                    "event name required, without dots")
            require(meta["start_tick"] <= integer(row, "tick") <= tick_previous,
                    f"record {index}: event references an uncommitted tick")
            require(meta["start_sim_ns"] <= integer(row, "sim_ns") <= sim_previous,
                    f"record {index}: event sim_ns outside captured simulation interval")
            values(row)
            events.append(row)
        elif kind == "end":
            require(index == len(rows), "end record must be last")
            require(integer(row, "tick") == tick_previous and integer(row, "sim_ns") == sim_previous,
                    "end tick/sim_ns must match last complete simulation tick")
        else:
            raise TraceError(f"record {index}: unsupported kind {kind!r}")
    require(sims and frames, "simulation and frame samples are both required")
    require(end["host_ns"] > meta["start_host_ns"], "capture host duration must be positive")
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(raw).hexdigest(),
            "metadata": meta, "end": end, "sim": sims, "frame": frames, "event": events}


def percentile(samples, fraction):
    if not samples:
        return None
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def summarize(trace, target_fps=120.0):
    meta, end = trace["metadata"], trace["end"]
    duration = end["host_ns"] - meta["start_host_ns"]
    sim_duration = end["sim_ns"] - meta["start_sim_ns"]
    new_renders = []
    last_id = None
    for frame in trace["frame"]:
        if frame["render_id"] != last_id:
            new_renders.append(frame)
            last_id = frame["render_id"]
    intervals = [b["host_ns"] - a["host_ns"] for a, b in zip(new_renders, new_renders[1:])]
    counts = Counter(event["category"] for event in trace["event"])
    rate = len(new_renders) * 1e9 / duration
    return {
        "trace_path": trace["path"], "trace_sha256": trace["sha256"],
        "capture_source_declared": meta["capture_source"], "run_id": meta["run_id"],
        "provenance_independently_verified": False, "gameplay_120fps_verified": False,
        "host_seconds": duration / 1e9, "simulated_seconds": sim_duration / 1e9,
        "simulation_seconds_per_host_second": sim_duration / duration,
        "simulation_ticks": len(trace["sim"]),
        "simulation_steps_per_host_second": len(trace["sim"]) * 1e9 / duration,
        "simulation_dt_ns_counts": dict(sorted(Counter(s["dt_ns"] for s in trace["sim"]).items())),
        "present_count": len(trace["frame"]), "unique_scene_render_count": len(new_renders),
        "repeated_present_count": len(trace["frame"]) - len(new_renders),
        "present_rate_hz": len(trace["frame"]) * 1e9 / duration,
        "unique_scene_render_rate_hz": rate, "target_fps": target_fps,
        "mean_scene_render_rate_reaches_target": rate >= target_fps,
        "render_interval_ms": {
            "p50": None if not intervals else percentile(intervals, .50) / 1e6,
            "p95": None if not intervals else percentile(intervals, .95) / 1e6,
            "p99": None if not intervals else percentile(intervals, .99) / 1e6,
            "max": None if not intervals else max(intervals) / 1e6,
            "over_target_budget_count": sum(i > math.ceil(1e9 / target_fps) for i in intervals),
        },
        "event_categories_observed": dict(sorted(counts.items())),
        "event_categories_missing": sorted(CATEGORIES - counts.keys()),
    }


def compare(baseline, candidate, target_fps=120.0, wall_tolerance_ns=0, tolerances=None):
    tolerances = tolerances or {}
    issues = []
    issue_count = 0

    def issue(text):
        nonlocal issue_count
        issue_count += 1
        if len(issues) < 100:
            issues.append(text)

    for field in IDENTITY_FIELDS:
        if baseline["metadata"][field] != candidate["metadata"][field]:
            issue(f"metadata differs: {field}")
    for label, trace in (("baseline", baseline), ("candidate", candidate)):
        if trace["metadata"]["guest_time_scalar"] != 1.0:
            issue(f"{label}: guest_time_scalar is not 1.0")
    baseline_wall = baseline["end"]["host_ns"] - baseline["metadata"]["start_host_ns"]
    candidate_wall = candidate["end"]["host_ns"] - candidate["metadata"]["start_host_ns"]
    if abs(baseline_wall - candidate_wall) > wall_tolerance_ns:
        issue("host duration differs beyond explicit tolerance for the same simulation window")

    def compare_values(left, right, path, label):
        if left.keys() != right.keys():
            issue(f"{label}: observable keys differ")
        for key in left.keys() & right.keys():
            a, b = left[key], right[key]
            if number(a) and number(b):
                if abs(a - b) > tolerances.get(f"{path}.{key}", 0.0):
                    issue(f"{label}: {key} differs ({a!r} vs {b!r})")
            elif type(a) is not type(b) or a != b:
                issue(f"{label}: {key} differs ({a!r} vs {b!r})")

    if len(baseline["sim"]) != len(candidate["sim"]):
        issue("simulation tick count differs")
    for a, b in zip(baseline["sim"], candidate["sim"]):
        label = f"simulation tick {a['tick']}"
        if any(a[k] != b[k] for k in ("tick", "sim_ns", "dt_ns")):
            issue(f"{label}: authoritative simulation timeline differs")
        a_host = a["host_ns"] - baseline["metadata"]["start_host_ns"]
        b_host = b["host_ns"] - candidate["metadata"]["start_host_ns"]
        if abs(a_host - b_host) > wall_tolerance_ns:
            issue(f"{label}: host-time milestone differs beyond explicit tolerance")
        compare_values(a["values"], b["values"], "sim", label)
    if len(baseline["event"]) != len(candidate["event"]):
        issue("gameplay event count differs")
    for a, b in zip(baseline["event"], candidate["event"]):
        label = f"event {a['category']}/{a['name']} tick {a['tick']}"
        if any(a[k] != b[k] for k in ("category", "name", "tick", "sim_ns")):
            issue(f"{label}: event order or simulation time differs")
        a_host = a["host_ns"] - baseline["metadata"]["start_host_ns"]
        b_host = b["host_ns"] - candidate["metadata"]["start_host_ns"]
        if abs(a_host - b_host) > wall_tolerance_ns:
            issue(f"{label}: host-time milestone differs beyond explicit tolerance")
        compare_values(a["values"], b["values"], f"event.{a['category']}.{a['name']}", label)
    synthetic = any(t["metadata"]["capture_source"] == "synthetic" for t in (baseline, candidate))
    return {
        "schema": "cod3-timing-comparison-v1", "tool_integration": "OFFLINE_ONLY",
        "result": "OBSERVED_MISMATCH" if issue_count else
                  ("SYNTHETIC_CHECK_ONLY" if synthetic else "OBSERVED_FIELDS_MATCH"),
        "gameplay_120fps_verified": False,
        "scope": "Only recorded fields are compared; telemetry provenance, probe coverage, visual "
                 "correctness, full gameplay, and display scanout are not certified.",
        "issue_count": issue_count, "issues": issues,
        "policy": {"wall_tolerance_ns": wall_tolerance_ns,
                   "absolute_observable_tolerances": tolerances,
                   "simulation_and_event_time_tolerance_ns": 0},
        "baseline": summarize(baseline, target_fps), "candidate": summarize(candidate, target_fps),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, help="candidate NDJSON trace")
    parser.add_argument("--baseline", type=Path, help="original-behavior trace for the same scenario")
    parser.add_argument("--target-fps", type=float, default=120.0)
    parser.add_argument("--wall-tolerance-ms", type=float, default=0.0,
                        help="explicit capture-boundary tolerance; default exact")
    parser.add_argument("--tolerances", type=Path, help="JSON map of observable path to absolute tolerance")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        require(math.isfinite(args.target_fps) and args.target_fps > 0, "target-fps must be positive")
        require(math.isfinite(args.wall_tolerance_ms) and args.wall_tolerance_ms >= 0,
                "wall-tolerance-ms must be finite and nonnegative")
        tolerances = {}
        if args.tolerances:
            tolerances = json.loads(args.tolerances.read_text(encoding="utf-8-sig"),
                                    parse_constant=reject_constant, object_pairs_hook=reject_duplicate_keys)
            require(isinstance(tolerances, dict), "tolerances must be a JSON object")
            require(all(isinstance(k, str) and number(v) and v >= 0 for k, v in tolerances.items()),
                    "tolerances must be finite nonnegative numbers")
        candidate = load_trace(args.trace)
        result = compare(load_trace(args.baseline), candidate, args.target_fps,
                         round(args.wall_tolerance_ms * 1e6), tolerances) if args.baseline else {
            "schema": "cod3-timing-summary-v1", "tool_integration": "OFFLINE_ONLY",
            "result": "NO_BASELINE", "gameplay_120fps_verified": False,
            "candidate": summarize(candidate, args.target_fps),
        }
        status = 1 if result.get("issue_count", 0) else 0
    except (OSError, UnicodeError, ValueError, TypeError, OverflowError) as error:
        result = {"result": "INVALID_TRACE_OR_POLICY", "gameplay_120fps_verified": False,
                  "error": str(error)}
        status = 2
    encoded = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
