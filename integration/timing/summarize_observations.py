"""Inspect candidate hook cadence; no simulation ticks or FPS are inferred."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path


EVENTS = {"candidate_ms_normalization": "0x825298D8", "candidate_outer_frame": "0x82536DD0"}


def integer(record, field, minimum=0):
    value = record.get(field)
    if type(value) is not int or value < minimum:
        raise ValueError(f"{field}: expected integer >= {minimum}")
    return value


def percentile(values, part):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * part) - 1)]


def summarize(path):
    raw = Path(path).read_bytes()
    rows = [json.loads(line) for line in raw.decode("utf-8-sig").splitlines() if line.strip()]
    if not rows or rows[0].get("schema") != "cod3-candidate-observation-v1":
        raise ValueError("expected candidate observation metadata")
    metadata = rows[0]
    if metadata.get("gameplay_120fps_verified") is not False:
        raise ValueError("unexpected gameplay verification claim")
    frequency = integer(metadata, "host_qpc_frequency_hz", 1)
    start = integer(metadata, "start_host_qpc")
    end = rows[-1] if rows[-1].get("kind") == "end" else None
    calls = {}
    by_thread = defaultdict(list)
    seen_records = 0
    for record in rows[1:-1] if end else rows[1:]:
        if record.get("kind") not in ("call_begin", "call_end"):
            raise ValueError("unexpected record kind; this schema contains no sim/frame events")
        event = record.get("event")
        if event not in EVENTS or record.get("guest_address") != EVENTS[event]:
            raise ValueError("event/address mismatch")
        call_id = integer(record, "call_id", 1)
        integer(record, "outer_call_id")
        integer(record, "host_thread_id", 1)
        integer(record, "host_qpc")
        raw_r3 = integer(record, "r3_u64")
        if raw_r3 >= 1 << 64:
            raise ValueError("r3_u64 out of range")
        signed = (raw_r3 & 0xFFFFFFFF) - ((1 << 32) if raw_r3 & (1 << 31) else 0)
        if type(record.get("r3_s32")) is not int or record["r3_s32"] != signed:
            raise ValueError("r3 signed view disagrees with its raw register")
        kind = record["kind"]
        pair = calls.setdefault(call_id, {})
        if kind in pair:
            raise ValueError("duplicate call phase")
        pair[kind] = record
        if kind == "call_begin":
            if record.get("outcome") != "entered":
                raise ValueError("invalid call_begin outcome")
            by_thread[(event, record["host_thread_id"])].append(record["host_qpc"])
        elif record.get("outcome") not in ("returned", "exception_unwind"):
            raise ValueError("invalid call_end outcome")
        seen_records += 1
    durations, input_values, output_values = defaultdict(list), Counter(), Counter()
    matched = missing_begin = missing_end = exceptions = 0
    for pair in calls.values():
        begin, finish = pair.get("call_begin"), pair.get("call_end")
        if not begin:
            missing_begin += 1
            continue
        if not finish:
            missing_end += 1
            continue
        if any(begin[key] != finish[key] for key in ("event", "host_thread_id", "outer_call_id")):
            raise ValueError("paired call identity changed")
        if finish["host_qpc"] < begin["host_qpc"] or begin["host_qpc"] < start:
            raise ValueError("invalid paired QPC interval")
        matched += 1
        exceptions += finish["outcome"] == "exception_unwind"
        durations[begin["event"]].append((finish["host_qpc"] - begin["host_qpc"]) * 1000 / frequency)
        if begin["event"] == "candidate_ms_normalization":
            input_values[begin["r3_s32"]] += 1
            output_values[finish["r3_s32"]] += 1
    if end:
        if end.get("gameplay_120fps_verified") is not False:
            raise ValueError("unexpected footer gameplay claim")
        if integer(end, "written_records") != seen_records:
            raise ValueError("footer record count mismatch")
        if end.get("capture_complete") is True and (missing_begin or missing_end or
                integer(end, "dropped_records") or integer(end, "pending_calls") or
                end.get("limit_reached") or end.get("io_error")):
            raise ValueError("complete footer contradicts missing observations")
    cadence = []
    for (event, thread), stamps in sorted(by_thread.items()):
        stamps.sort()
        gaps = [(b - a) * 1000 / frequency for a, b in zip(stamps, stamps[1:])]
        duration = stamps[-1] - stamps[0]
        cadence.append({"event": event, "host_thread_id": thread, "observed_entries": len(stamps),
                        "entry_calls_per_second": (len(stamps) - 1) * frequency / duration if duration else None,
                        "entry_gap_ms_p50": percentile(gaps, .50), "entry_gap_ms_p99": percentile(gaps, .99),
                        "entry_gap_ms_max": max(gaps) if gaps else None})
    return {"schema": "cod3-candidate-observation-summary-v1", "trace": str(Path(path).resolve()),
            "trace_sha256": hashlib.sha256(raw).hexdigest(), "gameplay_120fps_verified": False,
            "scope": "Candidate function invocations only; call rate is not render FPS or simulation rate.",
            "execution_kind_attested": False, "footer_present": end is not None,
            "capture_complete_declared": end.get("capture_complete", False) if end else False,
            "matched_calls": matched, "missing_begin": missing_begin, "missing_end": missing_end,
            "exception_unwinds": exceptions, "candidate_cadence_by_thread": cadence,
            "inclusive_call_duration_ms": {event: {"p50": percentile(samples, .50),
                "p99": percentile(samples, .99), "max": max(samples)} for event, samples in durations.items()},
            "candidate_normalization_input_r3_s32_top20": input_values.most_common(20),
            "candidate_normalization_output_r3_s32_top20": output_values.most_common(20),
            "footer": end}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = summarize(args.trace)
        status = 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        result = {"result": "INVALID_CANDIDATE_TRACE", "error": str(error), "gameplay_120fps_verified": False}
        status = 2
    encoded = json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
