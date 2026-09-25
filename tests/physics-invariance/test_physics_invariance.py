"""Synthetic contract tests for the physics invariance comparator.

These tests exercise parsing and comparison only.  They do not launch
Call of Duty 3 and cannot certify its gameplay or a real 120-Hz display.
"""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "physics-invariance" / "physics_invariance.py"
SPEC = importlib.util.spec_from_file_location("physics_invariance", SCRIPT)
physics = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(physics)


def anchor_rows():
    return [
        {"name": name, "address": address,
         "nul_terminated_bytes_match": True,
         "evidence": "analysis/timing-native-evidence.json"}
        for name, address in physics.STATIC_ANCHORS.items()
    ]


def manifest_document():
    return {
        "schema": "cod3-static-timing-evidence-v1",
        "anchors": anchor_rows(),
    }


def capture_rows(target_hz: int, source: str = "synthetic"):
    metadata = {
        "kind": "metadata",
        "schema": physics.SCHEMA,
        "timing_schema": physics.TIMING_SCHEMA,
        "capture_source": source,
        "executable_sha256": "a" * 64,
        "source_xex_sha256": "b" * 64,
        "input_sha256": "c" * 64,
        "checkpoint_sha256": "d" * 64,
        "sdk_commit": "e" * 40,
        "title_id": "415607E1",
        "media_id": "2E07093A",
        "scenario": "synthetic_invariance_matrix",
        "rng_seed": 7331,
        "run_id": f"synthetic-{target_hz}",
        "instrumentation_id": "physics-invariance-test-v1",
        "state_schema": "cod3-authoritative-state-test-v1",
        "guest_tick_frequency_hz": 50_000_000,
        "guest_time_scalar": 1.0,
        "render_target_hz": target_hz,
        "start_host_ns": 0,
        "start_sim_ns": 0,
        "start_tick": 0,
        "expected_categories": list(physics.EVENT_CATEGORIES),
        "cvars": {
            "com_maxfps": target_hz,
            "pmove_msec": 8,
            "timescale": 1.0,
            "fixedtime": 0,
        },
        "input_log_mode": "embedded_exact",
        "state_log_mode": "embedded_exact",
        "static_anchors": anchor_rows(),
    }
    rows = [metadata]
    # An invented 100-step authoritative simulation.  The values describe
    # data shape and determinism checks; they are not COD3 measurements.
    for tick in range(1, 101):
        sim_ns = tick * 10_000_000
        host = sim_ns
        rows.append({
            "kind": "sim", "host_ns": host, "tick": tick,
            "sim_ns": sim_ns, "dt_ns": 10_000_000,
            "values": {
                "position_x": tick * 0.1,
                "position_y": 2.0,
                "position_z": 1.0,
                "velocity_x": 10.0,
                "health": 100,
            },
        })
        rows.append({
            "kind": "input", "host_ns": host + 1, "tick": tick,
            "sim_ns": sim_ns, "sequence": tick, "device": "gamepad",
            "action": "move_forward",
            "values": {"pressed": True, "axis": 1.0},
        })
        rows.append({
            "kind": "state", "host_ns": host + 2, "tick": tick,
            "sim_ns": sim_ns, "entity_id": "player", "domain": "movement",
            "values": {
                "position_x": tick * 0.1,
                "velocity_x": 10.0,
                "grounded": True,
            },
        })
    categories = list(physics.EVENT_CATEGORIES)
    for index, category in enumerate(categories, 1):
        tick = index * 10
        sim_ns = tick * 10_000_000
        rows.append({
            "kind": "event", "host_ns": sim_ns + 3, "tick": tick,
            "sim_ns": sim_ns, "category": category,
            "name": {
                "movement": "jump_land",
                "fire": "shot",
                "ai": "decision",
                "animation": "reload_marker",
                "script": "objective_trigger",
                "cutscene": "scene_marker",
            }[category],
            "entity_id": "player" if category in ("movement", "fire", "animation") else "mission",
            "values": {"event_id": index, "phase": index * 0.1},
        })
    # Present cadence is intentionally independent from the 100 simulation
    # steps.  Every render_id is a new scene build in the default fixture.
    for present in range(target_hz + 1):
        host = present * 1_000_000_000 // target_hz
        rows.append({
            "kind": "frame", "host_ns": host,
            "present_id": present, "render_id": present,
            "sim_tick": min(100, host // 10_000_000),
            "render_mode": "interpolated_scene" if target_hz == 120 else "native_scene",
        })
    metadata = rows[0]
    body = rows[1:]
    body.sort(key=lambda row: (row["host_ns"],
                               {"sim": 0, "input": 1, "state": 2,
                                "event": 3, "frame": 4}[row["kind"]]))
    rows = [metadata, *body]
    last_host = max(row["host_ns"] for row in rows[1:])
    rows.append({"kind": "end", "capture_complete": True,
                 "host_ns": last_host + 1, "sim_ns": 1_000_000_000, "tick": 100,
                 "dropped_records": 0, "qpc_failures": 0})
    return rows


class PhysicsInvarianceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cod3_physics_invariance_")
        self.addCleanup(self.directory.cleanup)

    @property
    def root(self):
        return Path(self.directory.name)

    def write_manifest(self):
        path = self.root / "timing-native-evidence.json"
        path.write_text(json.dumps(manifest_document()), encoding="utf-8")
        return path

    def write_capture(self, target, rows=None, name=None, manifest=None):
        rows = copy.deepcopy(rows if rows is not None else capture_rows(target))
        if manifest is not None:
            rows[0]["static_anchor_manifest_sha256"] = hashlib.sha256(
                manifest.read_bytes()).hexdigest()
        path = self.root / (name or f"capture-{target}.ndjson")
        path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows),
                        encoding="utf-8")
        return path

    def load_pair(self, base_rows=None, candidate_rows=None, manifest=True):
        manifest_path = self.write_manifest() if manifest else None
        manifest_summary = physics.load_anchor_manifest(manifest_path) if manifest_path else None
        base_path = self.write_capture(60, base_rows, "baseline.ndjson", manifest_path)
        candidate_path = self.write_capture(120, candidate_rows, "candidate.ndjson", manifest_path)
        return (physics.load_capture(base_path, manifest_summary),
                physics.load_capture(candidate_path, manifest_summary))

    def test_matching_60_and_120_runs_are_only_a_synthetic_check(self):
        baseline, candidate = self.load_pair()
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "SYNTHETIC_CHECK_ONLY")
        self.assertEqual(report["issue_count"], 0)
        self.assertFalse(report["gameplay_120fps_verified"])
        self.assertFalse(report["physics_invariance_verified"])
        self.assertGreaterEqual(report["baseline"]["render"]["unique_scene_render_rate_hz"], 60)
        self.assertGreaterEqual(report["candidate"]["render"]["unique_scene_render_rate_hz"], 120)
        self.assertEqual(report["baseline"]["simulation_ticks"],
                         report["candidate"]["simulation_ticks"])

    def test_state_difference_is_reported_even_when_frame_count_is_higher(self):
        candidate_rows = capture_rows(120)
        state = next(row for row in candidate_rows if row["kind"] == "state")
        state["values"]["position_x"] += 0.25
        baseline, candidate = self.load_pair(candidate_rows=candidate_rows)
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "INVARIANCE_FAILED")
        self.assertTrue(any("position_x" in issue for issue in report["issues"]))

    def test_numeric_tolerance_is_explicit_and_scoped(self):
        candidate_rows = capture_rows(120)
        state = next(row for row in candidate_rows if row["kind"] == "state")
        state["values"]["position_x"] += 0.0005
        baseline, candidate = self.load_pair(candidate_rows=candidate_rows)
        report = physics.compare_captures(
            baseline, candidate, {"state.movement.position_x": 0.001})
        self.assertEqual(report["result"], "SYNTHETIC_CHECK_ONLY")
        self.assertEqual(report["issue_count"], 0)

    def test_input_replay_is_compared_by_exact_logical_records(self):
        candidate_rows = capture_rows(120)
        input_row = next(row for row in candidate_rows if row["kind"] == "input")
        input_row["values"]["axis"] = 0.5
        baseline, candidate = self.load_pair(candidate_rows=candidate_rows)
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "INVARIANCE_FAILED")
        self.assertTrue(any("input record" in issue for issue in report["issues"]))

    def test_missing_embedded_input_is_incomplete_not_a_pass(self):
        candidate_rows = capture_rows(120)
        candidate_rows[0]["input_log_mode"] = "digest_only"
        candidate_rows = [row for row in candidate_rows if row["kind"] != "input"]
        baseline, candidate = self.load_pair(candidate_rows=candidate_rows)
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "INCOMPLETE_COVERAGE")
        self.assertEqual(report["issue_count"], 0)
        self.assertTrue(any("input records" in item for item in report["incomplete_coverage"]))

    def test_repeated_present_does_not_count_as_new_scene_render(self):
        candidate_rows = capture_rows(120)
        for row in candidate_rows:
            if row["kind"] == "frame":
                row["render_id"] //= 2
        baseline, candidate = self.load_pair(candidate_rows=candidate_rows)
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "INVARIANCE_FAILED")
        self.assertTrue(any("120-Hz scene-render target" in issue
                            for issue in report["issues"]))
        self.assertEqual(report["candidate"]["render"]["repeated_present_count"], 60)

    def test_cvar_controls_are_split_between_render_and_simulation(self):
        candidate_rows = capture_rows(120)
        candidate_rows[0]["cvars"]["pmove_msec"] = 16
        baseline, candidate = self.load_pair(candidate_rows=candidate_rows)
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "INVARIANCE_FAILED")
        self.assertTrue(any("pmove_msec" in issue for issue in report["issues"]))

    def test_all_six_gameplay_categories_are_required(self):
        candidate_rows = capture_rows(120)
        candidate_rows = [row for row in candidate_rows
                          if not (row["kind"] == "event" and row["category"] == "ai")]
        baseline_path = self.write_manifest()
        summary = physics.load_anchor_manifest(baseline_path)
        base_path = self.write_capture(60, manifest=baseline_path)
        candidate_path = self.write_capture(120, candidate_rows, "candidate.ndjson", baseline_path)
        baseline, candidate = physics.load_capture(base_path, summary), physics.load_capture(candidate_path, summary)
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "INCOMPLETE_COVERAGE")
        self.assertTrue(any("ai" in item for item in report["incomplete_coverage"]))

    def test_metadata_anchor_mismatch_is_rejected_before_comparison(self):
        rows = capture_rows(60)
        rows[0]["static_anchors"][0]["address"] = "0x82000000"
        path = self.write_capture(60, rows, "invalid.ndjson")
        with self.assertRaises(physics.CaptureError):
            physics.load_capture(path)

    def test_wrong_render_pair_is_rejected_as_a_contract_failure(self):
        baseline_rows = capture_rows(120)
        candidate_rows = capture_rows(120)
        baseline, candidate = self.load_pair(baseline_rows, candidate_rows)
        report = physics.compare_captures(baseline, candidate)
        self.assertEqual(report["result"], "INVARIANCE_FAILED")
        self.assertTrue(any("baseline must declare render_target_hz=60" in issue
                            for issue in report["issues"]))


if __name__ == "__main__":
    unittest.main()
