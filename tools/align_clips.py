#!/usr/bin/env python3
"""Frame-align the videos of one SyncCam take.

SyncCam already starts every phone on a shared clock, but phone video
pipelines need a variable 50-300 ms to begin writing frames. This tool
removes that residue:

  1. Start from the per-clip start times in manifest.json (host clock).
  2. If the take has a slate (the host's 2 kHz beep), find the beep in every
     clip's audio and use it as the exact common instant.
     Otherwise, cross-correlate each clip's audio against the first clip.
  3. Write trimmed, re-encoded copies that all begin at the same instant,
     plus an optional side-by-side grid preview.

Requires ffmpeg on PATH and numpy (pip install numpy).

  python align_clips.py path/to/take_folder            # align + write ./aligned
  python align_clips.py path/to/take_folder --report    # just print offsets
  python align_clips.py path/to/take_folder --grid      # also build grid.mp4
"""
import argparse
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

RATE = 16000  # analysis sample rate
SLATE_HZ = 2000
SLATE_MS = 120


def load_audio(path: Path, start_s: float = 0.0, dur_s: float = 0.0):
    import numpy as np

    cmd = ["ffmpeg", "-v", "error", "-ss", f"{max(0.0, start_s):.3f}", "-i", str(path)]
    if dur_s > 0:
        cmd += ["-t", f"{dur_s:.3f}"]
    cmd += ["-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def find_slate(audio, offset_s: float):
    """Return the time (s, in clip timeline) where the slate beep starts."""
    import numpy as np

    n = int(RATE * SLATE_MS / 1000)
    t = np.arange(n) / RATE
    tone = np.sin(2 * math.pi * SLATE_HZ * t).astype(np.float32)
    if len(audio) < n:
        return None
    # Matched filter: correlate with the known tone, then take the envelope.
    corr = np.abs(np.convolve(audio, tone[::-1], mode="valid"))
    peak = int(np.argmax(corr))
    if corr[peak] < 25 * (np.median(corr) + 1e-9):
        return None  # no clear beep
    return offset_s + peak / RATE


def xcorr_lag(ref, sig, max_lag_s: float = 2.0):
    """Seconds by which `sig` lags `ref` (positive = sig started earlier)."""
    import numpy as np

    size = 1 << int(math.ceil(math.log2(len(ref) + len(sig))))
    R = np.fft.rfft(ref, size)
    S = np.fft.rfft(sig, size)
    cc = np.fft.irfft(S * np.conj(R), size)
    max_lag = int(max_lag_s * RATE)
    cc = np.concatenate([cc[-max_lag:], cc[: max_lag + 1]])
    return (int(np.argmax(cc)) - max_lag) / RATE


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("take", type=Path)
    ap.add_argument("--report", action="store_true", help="print offsets only")
    ap.add_argument("--grid", action="store_true", help="also write a side-by-side grid.mp4")
    ap.add_argument("--no-audio-refine", action="store_true", help="trust manifest timing only")
    ap.add_argument("--extra", type=Path, action="append", default=[],
                    help="another camera's clip (e.g. the Wi-Fi camera that led the take), aligned by audio; repeatable")
    args = ap.parse_args()

    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found on PATH")
    manifest = json.loads((args.take / "manifest.json").read_text())
    devices = {d["id"]: d for d in manifest["devices"]}
    clips = []
    for it in manifest["items"]:
        if it["kind"] != "video" or not it.get("file"):
            continue
        path = args.take / it["file"]
        if not path.exists():
            print(f"missing {path.name}, skipping")
            continue
        start = it["timing"].get("startReturnedHostUs") or it["timing"].get("startCalledHostUs")
        clips.append({"dev": devices.get(it["device"], {"name": it["device"]}), "path": path, "start_us": start})
    clips.sort(key=lambda c: c["dev"].get("slot", 0))
    # Clips from other cameras: their start is unknown to SyncCam, except
    # when a Wi-Fi camera led the take and the host logged when it started.
    seen = (manifest.get("externalCamera") or {}).get("seenHostUs")
    for p in args.extra:
        if not p.exists():
            sys.exit(f"extra clip not found: {p}")
        clips.append({"dev": {"name": p.stem, "slot": 99}, "path": p, "start_us": seen, "unknown": seen is None})
    if len(clips) < 2:
        sys.exit("need at least two video clips in this take")
    if args.extra and args.no_audio_refine:
        print("note: --extra clips are only placed precisely with audio refinement")

    # 1) Clock-based estimate: trim = how much earlier this clip started than the latest one.
    latest = max(c["start_us"] for c in clips if c["start_us"] is not None)
    for c in clips:
        if c["start_us"] is None:
            c["start_us"] = latest
    for c in clips:
        c["trim_s"] = (latest - c["start_us"]) / 1e6
        c["method"] = "clock"

    # 2) Audio refinement.
    if not args.no_audio_refine:
        try:
            import numpy  # noqa: F401
        except ImportError:
            print("numpy not installed: using clock timing only (pip install numpy)")
            args.no_audio_refine = True
    if not args.no_audio_refine:
        slates = manifest.get("slatesHostUs") or []
        if slates:
            slate_us = slates[0]
            found = []
            for c in clips:
                if c.get("unknown"):
                    win0, dur = 0.0, 30.0  # search the start of the clip
                else:
                    guess = (slate_us - c["start_us"]) / 1e6
                    win0, dur = max(0.0, guess - 1.5), 3.0
                audio = load_audio(c["path"], win0, dur)
                found.append(find_slate(audio, win0))
            if all(f is not None for f in found):
                first = min(found)
                for c, f in zip(clips, found):
                    c["trim_s"] = f - first
                    c["method"] = "slate"
            else:
                print("slate not heard in every clip; falling back to cross-correlation")
                slates = []
        if not slates:
            ref = clips[0]
            ref_audio = load_audio(ref["path"], ref["trim_s"], 20)
            for c in clips[1:]:
                sig = load_audio(c["path"], c["trim_s"], 20)
                lag = xcorr_lag(ref_audio, sig, max_lag_s=10.0 if c.get("unknown") else 2.0)
                c["trim_s"] += lag
                c["method"] = "xcorr"
            base = min(c["trim_s"] for c in clips)
            for c in clips:
                c["trim_s"] -= base

    print(f"{'slot':>4}  {'camera':<24} {'trim head':>10}  method")
    for c in clips:
        print(f"{c['dev'].get('slot', 0) + 1:>4}  {c['dev']['name'][:24]:<24} {c['trim_s'] * 1000:>8.1f}ms  {c['method']}")
    if args.report:
        return

    out = args.take / "aligned"
    out.mkdir(exist_ok=True)
    for c in clips:
        dst = out / c["path"].name
        # Re-encode so the cut is frame-accurate rather than snapping to a keyframe.
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", str(c["path"]), "-ss", f"{c['trim_s']:.4f}",
             "-c:v", "libx264", "-crf", "17", "-preset", "medium", "-c:a", "aac", "-b:a", "192k", str(dst)],
            check=True,
        )
        c["aligned"] = dst
        print(f"wrote {dst}")

    if args.grid:
        n = len(clips)
        cols = math.ceil(math.sqrt(n))
        inputs, scaled, layout = [], [], []
        for i, c in enumerate(clips):
            inputs += ["-i", str(c["aligned"])]
            scaled.append(f"[{i}:v]scale=640:640:force_original_aspect_ratio=decrease,"
                          f"pad=640:640:(ow-iw)/2:(oh-ih)/2[v{i}]")
            layout.append(f"{(i % cols) * 640}_{(i // cols) * 640}")
        graph = ";".join(scaled) + ";" + "".join(f"[v{i}]" for i in range(n)) + \
            f"xstack=inputs={n}:layout={'|'.join(layout)}:fill=black[out]"
        subprocess.run(["ffmpeg", "-v", "error", "-y", *inputs, "-filter_complex", graph, "-map", "[out]",
                        "-map", "0:a?", "-shortest", "-c:v", "libx264", "-crf", "20", str(out / "grid.mp4")],
                       check=True)
        print(f"wrote {out / 'grid.mp4'}")


if __name__ == "__main__":
    main()
