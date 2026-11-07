"""Summarises a field-test journal (scripts/field-test.sh) as Markdown evidence.

Usage: python3 -I scripts/field-report.py journal.jsonl steps.jsonl > report.md
"""
import json
import statistics
import sys


def load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return rows


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    return v[min(len(v) - 1, int(len(v) * p))]


def fmt(x, unit="", digits=0):
    return "n/a" if x is None else f"{x:.{digits}f}{unit}"


def windows(steps):
    starts = {}
    out = []
    for s in steps:
        if s["phase"] == "start":
            starts[s["step"]] = s["wall"]
        elif s["phase"] == "end" and s["step"] in starts:
            out.append((s["step"], starts.pop(s["step"]), s["wall"]))
    return out


WARMUP = 5.0  # seconds after launch left out of pacing: scene setup, not steady state


def rate(r, key):
    span = r.get("span_s") or 1.0
    return r.get(key, 0) / span


def summarise(rows, t0, t1):
    launched = [r["wall"] for r in rows if r["kind"] == "start"]
    def steady(r):
        return not any(0 <= r["wall"] - t < WARMUP for t in launched) and "span_s" in r and r["span_s"] >= 0.5
    secs = [r for r in rows if r["kind"] == "second" and t0 <= r["wall"] <= t1 + 0.5 and steady(r)]
    events = [r for r in rows if r["kind"] != "second" and t0 <= r["wall"] <= t1 + 0.5]
    drawing = [r for r in secs if r.get("frames", 0) > 0]
    fps = [rate(r, "frames") for r in drawing]
    gaps = [r["frame_gap_max_ms"] for r in drawing if "frame_gap_max_ms" in r]
    streaming = [r for r in secs if r.get("samples", 0) > 0]
    rates = [rate(r, "samples") for r in streaming]
    sample_gaps = [r["sample_gap_max_ms"] for r in streaming if "sample_gap_max_ms" in r]
    lat = [r["latency_p50_ms"] for r in secs if "latency_p50_ms" in r]
    lat_max = [r["latency_max_ms"] for r in secs if "latency_max_ms" in r]
    return {
        "seconds": len(secs), "drawing": len(drawing), "fps": fps, "gaps": gaps,
        "streaming": len(streaming), "rates": rates, "sample_gaps": sample_gaps,
        "lat": lat, "lat_max": lat_max, "events": events, "secs": secs,
        "pointer": sum(r.get("pointer_px", 0) for r in secs),
        "front": sorted({r.get("front", "?") for r in secs}),
    }


def pacing_line(s):
    if not s["fps"]:
        return "Head not drawn in this window (Murmury hidden or minimised)."
    slow = sum(1 for f in s["fps"] if f < 55)
    return (f"{s['drawing']} s drawn: {fmt(statistics.median(s['fps']))} frames/s median, slowest second "
            f"{min(s['fps']):.0f}; worst frame gap per second p50 {fmt(pct(s['gaps'], 0.5), ' ms', 1)}, "
            f"p95 {fmt(pct(s['gaps'], 0.95), ' ms', 1)}, max {fmt(max(s['gaps']) if s['gaps'] else None, ' ms', 1)}; "
            f"seconds under 55 frames/s: {slow}.")


def stream_line(s):
    if not s["rates"]:
        return "No motion samples in this window."
    long_gaps = sum(1 for g in s["sample_gaps"] if g > 200)
    return (f"{s['streaming']} of {s['seconds']} s streaming, {fmt(statistics.median(s['rates']))} samples/s median; "
            f"worst sample gap per second p95 {fmt(pct(s['sample_gaps'], 0.95), ' ms')}, "
            f"max {fmt(max(s['sample_gaps']) if s['sample_gaps'] else None, ' ms')}; seconds with a gap over 200 ms: {long_gaps}.")


def latency_line(s):
    if not s["lat"]:
        return "No new samples drawn in this window."
    return (f"sample arrival to the frame that applies it: median of per-second medians {fmt(statistics.median(s['lat']), ' ms', 1)}, "
            f"p95 {fmt(pct(s['lat'], 0.95), ' ms', 1)}, worst single sample {fmt(max(s['lat_max']), ' ms', 1)}.")


def event_line(e, t0):
    k = e["kind"]
    t = f"+{e['wall'] - t0:5.1f} s"
    if k == "said":
        return f"{t} said{' (urgent)' if e.get('urgent') else ''}: \"{e.get('text', '')}\""
    if k == "command":
        return f"{t} command acted: {e.get('command')} (from {e.get('source')})"
    if k in ("conversation", "not-wearer"):
        label = "ignored, said inside conversation" if k == "conversation" else "ignored, not the wearer's voice"
        return f"{t} command words {label}: \"{e.get('words', '')}\""
    if k == "bud":
        return f"{t} reporting bud changed {e.get('from')} → {e.get('to')}"
    if k == "camera-fit":
        return f"{t} camera fit: lag {e.get('lag_s', 0) * 1000:.0f} ms, quality {e.get('quality', 0):.2f}"
    extra = {key: v for key, v in e.items() if key not in ("kind", "wall", "up")}
    return f"{t} {k}{' ' + json.dumps(extra) if extra else ''}"


def nearest_second(rows, wall):
    secs = [r for r in rows if r["kind"] == "second"]
    after = [r for r in secs if r["wall"] >= wall]
    return after[0] if after else (secs[-1] if secs else {})


def main():
    rows = load(sys.argv[1])
    steps = load(sys.argv[2])
    if not rows:
        print("# Field test\n\nThe journal is empty: Murmury didn't record (was it built with FieldJournal?).")
        return
    start, end = rows[0]["wall"], rows[-1]["wall"]
    whole = summarise(rows, start, end)
    print("# Murmury field test\n")
    print(f"Session: {(end - start) / 60:.1f} minutes. Journal: `journal.jsonl` (one line a second plus events); steps: `steps.jsonl`.\n")
    first = next((r for r in rows if r["kind"] == "second"), {})
    print(f"Settings: own voice only {first.get('own_voice_only')}, murmur model {first.get('murmur_model')}.\n")

    print("## Whole session\n")
    print(f"- Frame pacing: {pacing_line(whole)}")
    print(f"- Motion stream: {stream_line(whole)}")
    print(f"- Latency: {latency_line(whole)}")
    fit = [e for e in rows if e["kind"] == "camera-fit"]
    if fit and whole["lat"]:
        lag = fit[-1]["lag_s"]
        transport = max(0.0, -lag) * 1000
        med = statistics.median(whole["lat"])
        refresh = 1000 / max(statistics.median(whole["fps"]), 1) if whole["fps"] else 16.7
        print(f"- Physical motion to display, estimated: {transport:.0f} ms buds to Mac (camera fit, quality "
              f"{fit[-1]['quality']:.2f}) + {med:.1f} ms arrival to frame + up to {refresh:.1f} ms to the screen "
              f"≈ {transport + med + refresh:.0f} ms (median, counting a full refresh).")
    else:
        print("- Physical motion to display: not estimated (no camera fit in this session).")
    print()

    for name, t0, t1 in windows(steps):
        s = summarise(rows, t0, t1)
        print(f"## {name} ({t1 - t0:.0f} s)\n")
        print(f"- Front app: {', '.join(s['front'])}. Pointer travel: {s['pointer']:.0f} px.")
        print(f"- Frame pacing: {pacing_line(s)}")
        print(f"- Motion stream: {stream_line(s)}")
        print(f"- Latency: {latency_line(s)}")
        cmds = [e for e in s["events"] if e["kind"] == "command"]
        ignored = [e for e in s["events"] if e["kind"] in ("conversation", "not-wearer")]
        print(f"- Commands acted: {len(cmds)}; command words ignored: {len(ignored)}.")
        lost = next((e for e in s["events"] if e["kind"] == "buds-lost"), None)
        back = next((e for e in s["events"] if e["kind"] == "buds-back"), None)
        if lost:
            last_sample = max((r["wall"] for r in s["secs"] if r.get("samples", 0) > 0 and r["wall"] <= lost["wall"]), default=None)
            detect = f"noticed about {lost['wall'] - last_sample:.0f} s after the last samples" if last_sample else "noticed"
            print(f"- Buds lost: {detect}.", end="")
            if back:
                state = nearest_second(rows, back["wall"] + 2)
                pointer = {"pointer": "following the head", "scroll": "in scroll mode"}.get(state.get("pointer"), state.get("pointer"))
                print(f" Back {back['wall'] - lost['wall']:.1f} s later, hands-free; 2 s after, the pointer was "
                      f"{pointer} with {state.get('front')} in front.")
            else:
                print(" Not back within the step.")
        if s["events"]:
            print("\n```")
            for e in s["events"]:
                print(event_line(e, t0))
            print("```")
        print()


if __name__ == "__main__":
    main()
