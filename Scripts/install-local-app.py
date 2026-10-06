#!/usr/bin/env python3
"""Replace the existing local installation after preserving a recoverable bundle."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
source = root / "dist/FanFic to Audio.app"
installed = Path("/Applications/FanFic to Audio.app")
if not source.is_dir() or not installed.is_dir():
    raise SystemExit("Both the built bundle and existing Applications installation are required.")
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], check=True)
with (source / "Contents/Info.plist").open("rb") as handle:
    version = plistlib.load(handle)["CFBundleShortVersionString"]
backup = root / "dist/Previous Builds" / ("Installed FanFic to Audio-before-" + version + "-" + str(uuid.uuid4()) + ".app")
backup.parent.mkdir(parents=True, exist_ok=True)
stage = Path(tempfile.mkdtemp(prefix=".FanFicToAudio-update-", dir="/Applications"))
new = stage / "new.app"
previous = stage / "previous.app"
try:
    subprocess.run(["/usr/bin/ditto", str(source), str(new)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(new)], check=True)
    os.rename(installed, previous)
    try:
        os.rename(new, installed)
    except BaseException:
        os.rename(previous, installed)
        raise
    shutil.move(str(previous), str(backup))
    print(f"Updated: {installed}")
    print(f"Previous installation preserved: {backup}")
finally:
    # Never discard a previous installation if moving its backup failed.
    if not previous.exists():
        shutil.rmtree(stage)
    else:
        print(f"Previous installation still preserved at: {previous}")
