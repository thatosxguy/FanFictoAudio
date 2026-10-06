#!/usr/bin/env python3
"""Sign nested Mach-O code inside-out, retaining hardware-token private keys."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("--identity", default="-")
args = parser.parse_args()
app = args.app.resolve()
if not (app / "Contents/Info.plist").is_file():
    parser.error("Expected a complete application bundle")
if args.identity != "-" and not args.identity.startswith("Developer ID Application:"):
    parser.error("Distribution signing requires a Developer ID Application identity")
magic = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
code = []
for path in app.rglob("*"):
    if path.is_file() and not path.is_symlink():
        with path.open("rb") as handle:
            if handle.read(4) in magic:
                code.append(path)
frameworks = [path for path in app.rglob("*.framework") if path.is_dir() and not path.is_symlink()]
# Python framework binaries are signed before their enclosing framework.
base = ["/usr/bin/codesign", "--force", "--sign", args.identity]
if args.identity != "-":
    base += ["--options", "runtime", "--timestamp"]
ordered = sorted(code, key=lambda p: len(p.parts), reverse=True) + sorted(frameworks, key=lambda p: len(p.parts), reverse=True) + [app]
# Keep one signer/token session for the whole ordered batch. A process per
# library can repeatedly request token authorization or expire its PIN cache.
print(f"Signing {len(ordered)} code objects; respond to local token prompts when requested.", flush=True)
subprocess.run(base + [str(path) for path in ordered], check=True, timeout=1800)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(f"Verified signed bundle: {app}")
