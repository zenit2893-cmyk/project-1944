"""Synthetic counterexamples, not COD3 gameplay or FPS tests."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "timing_analyze", Path(__file__).resolve().parents[1] / "scripts" / "timing_analyze.py")
timing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(timing)


def synthetic_trace(fps=60, repeat_factor=1, speed=1):
    """Invented 50-Hz simulation, explicitly unrelated to COD3's unknown rate."""
    duration_ns = 2_000_000_000 // speed
    meta = {"kind": "metadata", "schema": timing.SCHEMA, "capture_source": "synthetic",
            "executable_sha256": "0" * 64, "input_sha256": "1" * 64,
            "checkpoint_sha256": "2" * 64, "sdk_commit": "0" * 40,
            "scenario": "synthetic_counterexample", "rng_seed": 42,
            "run_id": f"synthetic_{fps}_{repeat_factor}_{speed}",
            "instrumentation_id": "synthetic_fixture_only", "guest_tick_frequency_hz": 50_000_000,
            "guest_time_scalar": 1.0, "start_host_ns": 0, "start_sim_ns": 0, "start_tick": 0}
    rows = []
    categories = sorted(timing.CATEGORIES)
    for tick in range(1, 101):
        sim_ns = tick * 20_000_000
        rows.append({"kind": "sim", "host_ns": sim_ns // speed, "tick": tick,
                     "sim_ns": sim_ns, "dt_ns": 20_000_000,
                     "values": {"position_x": tick * .02, "ammo": 100 - tick // 10}})
        if tick % 10 == 0:
            rows.append({"kind": "event", "host_ns": sim_ns // speed, "tick": tick,
                         "sim_ns": sim_ns, "category": categories[(tick // 10 - 1) % 6],
                         "name": "synthetic_event", "values": {"event_id": tick // 10}})
    for present in range(fps * 2 // speed):
        host = present * 1_000_000_000 // fps
        rows.append({"kind": "frame", "host_ns": host, "present_id": present,
                     "render_id": present // repeat_factor, "sim_tick": host * speed // 20_000_000,
                     "render_mode": "interpolated_scene"})
    order = {"sim": 0, "event": 1, "frame": 2}
    rows.sort(key=lambda row: (row["host_ns"], order[row["kind"]]))
    return [meta, *rows, {"kind": "end", "capture_complete": True,
                         "host_ns": duration_ns, "sim_ns": 2_000_000_000, "tick": 100}]


class TimingTraceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cod3_synthetic_timing_")
        self.addCleanup(self.directory.cleanup)
        self.serial = 0

    def load(self, rows):
        self.serial += 1
        path = Path(self.directory.name) / f"synthetic_{self.serial}.ndjson"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        return timing.load_trace(path)

    def test_120_render_does_not_require_120_simulation(self):
        result = timing.compare(self.load(synthetic_trace(60)), self.load(synthetic_trace(120)))
        self.assertEqual(result["result"], "SYNTHETIC_CHECK_ONLY")
        self.assertEqual(result["candidate"]["unique_scene_render_rate_hz"], 120)
        self.assertEqual(result["candidate"]["simulation_steps_per_host_second"], 50)
        self.assertFalse(result["gameplay_120fps_verified"])

    def test_repeated_presents_do_not_count_as_new_scene_frames(self):
        summary = timing.summarize(self.load(synthetic_trace(120, repeat_factor=2)))
        self.assertEqual(summary["present_rate_hz"], 120)
        self.assertEqual(summary["unique_scene_render_rate_hz"], 60)
        self.assertFalse(summary["mean_scene_render_rate_reaches_target"])

    def test_double_speed_is_rejected_even_with_same_tick_states(self):
        result = timing.compare(self.load(synthetic_trace()), self.load(synthetic_trace(120, speed=2)))
        self.assertEqual(result["result"], "OBSERVED_MISMATCH")
        self.assertTrue(any("host duration" in issue for issue in result["issues"]))
        self.assertEqual(result["candidate"]["simulation_seconds_per_host_second"], 2)

    def test_local_speed_change_is_rejected_even_if_total_duration_matches(self):
        rows = synthetic_trace(120)
        for row in rows:
            if row["kind"] in ("sim", "event", "frame"):
                timestamp = row["host_ns"]
                row["host_ns"] = timestamp // 2 if timestamp <= 1_000_000_000 else (
                    500_000_000 + (timestamp - 1_000_000_000) * 3 // 2)
        result = timing.compare(self.load(synthetic_trace()), self.load(rows))
        self.assertEqual(result["baseline"]["host_seconds"], result["candidate"]["host_seconds"])
        self.assertTrue(any("host-time milestone" in issue for issue in result["issues"]))

    def test_changed_clock_contract_is_rejected(self):
        rows = synthetic_trace(120)
        rows[0]["guest_tick_frequency_hz"] = 3_000_000_000
        rows[0]["guest_time_scalar"] = 2.0
        result = timing.compare(self.load(synthetic_trace()), self.load(rows))
        self.assertTrue(any("guest_tick_frequency_hz" in issue for issue in result["issues"]))
        self.assertTrue(any("guest_time_scalar" in issue for issue in result["issues"]))

    def test_each_required_gameplay_category_detects_regression(self):
        for category in sorted(timing.CATEGORIES):
            with self.subTest(category=category):
                rows = synthetic_trace(120)
                next(row for row in rows if row.get("category") == category)["values"]["event_id"] += 1
                result = timing.compare(self.load(synthetic_trace()), self.load(rows))
                self.assertEqual(result["result"], "OBSERVED_MISMATCH")
                self.assertTrue(any(category in issue for issue in result["issues"]))

    def test_state_mismatch_and_explicit_tolerance(self):
        rows = synthetic_trace(120)
        next(row for row in rows if row["kind"] == "sim")["values"]["position_x"] += .00001
        baseline, candidate = self.load(synthetic_trace()), self.load(rows)
        self.assertEqual(timing.compare(baseline, candidate)["result"], "OBSERVED_MISMATCH")
        self.assertEqual(timing.compare(baseline, candidate,
                         tolerances={"sim.position_x": .00002})["result"], "SYNTHETIC_CHECK_ONLY")

    def test_wrong_input_or_executable_is_not_comparable(self):
        for key in ("input_sha256", "executable_sha256", "checkpoint_sha256"):
            with self.subTest(key=key):
                rows = synthetic_trace(120)
                rows[0][key] = "f" * 64
                result = timing.compare(self.load(synthetic_trace()), self.load(rows))
                self.assertTrue(any(key in issue for issue in result["issues"]))

    def test_missing_ticks_are_rejected(self):
        rows = synthetic_trace(120)
        rows.remove(next(row for row in rows if row["kind"] == "sim"))
        with self.assertRaises(timing.TraceError):
            self.load(rows)

    def test_nan_is_rejected(self):
        rows = synthetic_trace()
        next(row for row in rows if row["kind"] == "sim")["values"]["position_x"] = float("nan")
        with self.assertRaises(timing.TraceError):
            self.load(rows)

    def test_partial_trace_is_rejected(self):
        with self.assertRaises(timing.TraceError):
            self.load(synthetic_trace()[:-1])

    def test_event_timing_and_order_are_checked(self):
        rows = synthetic_trace(120)
        event = next(row for row in rows if row["kind"] == "event")
        event["sim_ns"] -= 1
        result = timing.compare(self.load(synthetic_trace()), self.load(rows))
        self.assertTrue(any("event order or simulation time" in issue for issue in result["issues"]))

    def test_different_timestep_is_rejected(self):
        rows = copy.deepcopy(synthetic_trace(120))
        for row in rows:
            if "sim_ns" in row:
                row["sim_ns"] //= 2
            if "dt_ns" in row:
                row["dt_ns"] //= 2
        result = timing.compare(self.load(synthetic_trace()), self.load(rows))
        self.assertTrue(any("simulation timeline" in issue for issue in result["issues"]))

    def test_cli_rejects_invalid_policy_and_writes_reviewable_error(self):
        output = Path(self.directory.name) / "error.json"
        code = timing.main([str(output), "--target-fps", "nan", "--output", str(output)])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.read_text())["result"], "INVALID_TRACE_OR_POLICY")


if __name__ == "__main__":
    unittest.main()
