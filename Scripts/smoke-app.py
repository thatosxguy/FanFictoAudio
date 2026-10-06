#!/usr/bin/env python3
"""Exercise the installed helper -> EPUB -> native narration/FFmpeg pipeline.
FanFicFare's test1 adapter is offline; this does not contact a real story site.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import uuid

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path, default=root / "dist/FanFic to Audio.app")
parser.add_argument("--cli", type=Path, required=True)
parser.add_argument("--output", type=Path, help="New, empty output directory (defaults to a unique validation folder)")
parser.add_argument("--ffprobe", default=shutil.which("ffprobe"), help="FFprobe executable, otherwise resolved from PATH")
parser.add_argument("--voice", help="Optional macOS voice name exposed by epub-audio voices")
args = parser.parse_args()
if not args.ffprobe:
    parser.error("FFprobe is missing. Install FFmpeg or pass --ffprobe PATH.")
helper = args.app / "Contents/Resources/Downloader/fanfic-download"
work = (args.output or root / "dist/Validation" / f"Smoke-{uuid.uuid4().hex}").resolve()
if work.exists() and any(work.iterdir()):
    parser.error("Choose a new or empty output directory.")
work.mkdir(parents=True, exist_ok=True)
request = work / "download-request.json"
request.write_text(json.dumps({"operation": "download", "source": "http://test1.com?sid=1[1-2]",
    "format": "epub", "output": str(work)}))
result = subprocess.run([str(helper), "--request", str(request)], input="commit\n",
    text=True, capture_output=True, timeout=90)
request.unlink()
if result.returncode: raise RuntimeError(result.stdout + result.stderr)
events = [json.loads(line) for line in result.stdout.splitlines()]
book = Path(events[-1]["path"])
assert book.is_file()
assert any(event.get("finalizing") for event in events)
subprocess.run([str(args.cli), "inspect", str(book)], check=True, timeout=30)
for mode in ("single", "chapters"):
    destination = work / ("Downloaded Story.mp3" if mode == "single" else "Downloaded Story Chapters")
    command = [str(args.cli), "export", str(book), str(destination), "--rate", "1000"]
    if args.voice: command.extend(["--voice", args.voice])
    if mode == "chapters": command.append("--chapters")
    subprocess.run(command, check=True, timeout=180)
    files = [destination] if mode == "single" else list(destination.glob("*.mp3"))
    assert files and all(path.stat().st_size > 1000 for path in files)
    for audio in files:
        probe = subprocess.run([args.ffprobe, "-v", "error", "-show_entries",
            "format=duration:format_tags=title,artist,album,track", "-of", "json", str(audio)],
            check=True, capture_output=True, text=True)
        details = json.loads(probe.stdout)["format"]
        assert float(details["duration"]) > 0
        assert details["tags"]["title"] and details["tags"]["artist"]
        print(probe.stdout.strip())
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.app)], check=True)
print("PASS: bundled downloader, EPUB reading order, one MP3, chapter MP3s, metadata, and bundle signature.")
