"""Frame-pacing / hitch summary from a cod3-candidate-observation-v1 capture.

Uses the outer-frame probe (0x82536DD0) entry QPC as the frame boundary and the
ms-normalization probe (0x825298D8) entry r3 as the game's own measured frame
milliseconds. Reports only the trailing --seconds window (default 45 s) so
menus and loading screens can be excluded by timing the capture.

usage: python frame_hitches.py <capture.ndjson> [--seconds 45] [--skip-tail 0]
"""
import json
import sys


def pct(sorted_values, q):
    if not sorted_values:
        return 0.0
    i = min(len(sorted_values) - 1, int(round(q * (len(sorted_values) - 1))))
    return sorted_values[i]


def main():
    path = sys.argv[1]
    seconds = 45.0
    skip_tail = 0.0
    if '--seconds' in sys.argv:
        seconds = float(sys.argv[sys.argv.index('--seconds') + 1])
    if '--skip-tail' in sys.argv:
        skip_tail = float(sys.argv[sys.argv.index('--skip-tail') + 1])
    freq = 10_000_000
    frames, game_ms = [], []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if not line.startswith('{'):
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue  # last line may be partial while the game is running
            if r.get('kind') == 'metadata':
                freq = r.get('host_qpc_frequency_hz', freq)
            elif r.get('kind') == 'call_begin':
                if r['event'] == 'candidate_outer_frame':
                    frames.append(r['host_qpc'])
                elif r['event'] == 'candidate_ms_normalization':
                    game_ms.append((r['host_qpc'], r['r3_s32']))
    if len(frames) < 3:
        print('not enough frames')
        return
    end = frames[-1] - int(skip_tail * freq)
    start = end - int(seconds * freq)
    window = [q for q in frames if start <= q <= end]
    dts = [(b - a) * 1000.0 / freq for a, b in zip(window, window[1:])]
    ms = [v for q, v in game_ms if start <= q <= end]
    s = sorted(dts)
    span = (window[-1] - window[0]) / freq if len(window) > 1 else 0
    print('window_s=%.1f frames=%d avg_fps=%.1f' % (span, len(dts), len(dts) / span if span else 0))
    print('frame_ms p50=%.2f p90=%.2f p99=%.2f p99.9=%.2f max=%.2f' % (
        pct(s, .5), pct(s, .9), pct(s, .99), pct(s, .999), s[-1]))
    for limit in (20, 25, 33.4, 50, 100):
        print('  >%5.1f ms: %d' % (limit, sum(1 for d in dts if d > limit)))
    # Pacing regularity: consecutive frame-time jumps (judder)
    jumps = [abs(b - a) for a, b in zip(dts, dts[1:])]
    js = sorted(jumps)
    print('frame-to-frame jitter p50=%.2f p99=%.2f' % (pct(js, .5), pct(js, .99)))
    hist = {}
    for v in ms:
        hist[v] = hist.get(v, 0) + 1
    top = sorted(hist.items(), key=lambda kv: -kv[1])[:8]
    print('game-measured ms histogram (value:count):', ', '.join('%d:%d' % kv for kv in top))
    worst = sorted(range(len(dts)), key=lambda i: -dts[i])[:5]
    print('worst spikes at t(s)=', ', '.join('%.1f(%.0fms)' % ((window[i + 1] - window[0]) / freq, dts[i]) for i in sorted(worst)))


main()
