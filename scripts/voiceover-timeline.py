"""Lines up what VoiceOver spoke (captions.tsv, from vo-listen) with the sheet probe's steps.

Usage: python3 -I scripts/voiceover-timeline.py <voiceover-evidence-dir> > README.md
"""
import os
import re
import sys

STEP = re.compile(r"^> (.*?)  @(\d+\.\d+)$")


def captions(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t", 2)
            if len(parts) == 3:
                rows.append((float(parts[0]), parts[1], parts[2]))
    return rows


def main():
    folder = sys.argv[1]
    spoken = captions(os.path.join(folder, "captions.tsv"))
    heard = [r for r in spoken if r[1] in ("caption", "spoke")]
    notes = [r for r in spoken if r[1] == "listener"]
    print("# Live VoiceOver check\n")
    print("VoiceOver ran with the sound muted. `captions.tsv` holds every phrase it showed in its caption panel "
          "(read with text recognition, so spelling can differ slightly from the speech) or, where AppleScript "
          "control was allowed, its exact last phrase (`spoke`). Each run's probe log (`<run>.txt`) has the steps, "
          "keyboard focus and the announcements Murmury requested; below, each step is followed by what VoiceOver "
          "said before the next step.\n")
    print(f"Phrases recorded: {len(heard)}. Listener: " + "; ".join(n[2] for n in notes) + ".\n")
    runs = sorted(f for f in os.listdir(folder) if f.endswith(".txt") and not f.endswith(".launch.log"))
    for name in runs:
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            lines = f.read().splitlines()
        steps = []
        for i, line in enumerate(lines):
            m = STEP.match(line)
            if m:
                steps.append((float(m.group(2)), m.group(1), i))
        print(f"## {name[:-4]}\n")
        if not steps:
            print("No steps recorded.\n")
            continue
        print("```")
        for k, (t, step, i) in enumerate(steps):
            t_next = steps[k + 1][0] if k + 1 < len(steps) else t + 4
            print(f"> {step}")
            # The probe's own lines for this step (focus, presses, announcements requested).
            end = steps[k + 1][2] if k + 1 < len(steps) else len(lines)
            for extra in lines[i + 1:end]:
                if extra.startswith("#"):
                    continue
                print(f"  probe: {extra.strip()}")
            for when, source, text in heard:
                if t <= when < t_next:
                    print(f"  VoiceOver ({source}, +{when - t:.1f} s): \"{text}\"")
        print("```\n")


if __name__ == "__main__":
    main()
