#!/usr/bin/env python3
"""Retain available dependency licenses from the helper's build environment."""
from importlib.metadata import distributions
from pathlib import Path
import shutil
import sys

output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
index = []
for dist in sorted(distributions(), key=lambda d: d.metadata.get("Name", "").lower()):
    name = dist.metadata.get("Name", "unknown")
    # GUI and development tools are excluded from the helper.
    if name.lower().startswith(("pyside", "shiboken", "pytest", "pyinstaller")) or name.lower() in {"fanficfare-desktop", "setuptools", "pip", "pluggy", "iniconfig"}:
        continue
    folder = output / name
    folder.mkdir(exist_ok=True)
    metadata = dist.read_text("METADATA")
    if metadata:
        (folder / "METADATA.txt").write_text(metadata, encoding="utf-8")
    for entry in dist.files or []:
        if any(word in str(entry).lower() for word in ("license", "copying", "notice", "copyright")):
            source = Path(dist.locate_file(entry))
            if source.is_file():
                relative = Path(*[p for p in entry.parts if p not in (".", "..")])
                target = folder / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
    index.append(f"{name} {dist.version}")
(output / "README.txt").write_text("Available dependency notices from the build environment. This may include packages not present in the frozen helper.\n\n" + "\n".join(index) + "\n", encoding="utf-8")
# Python's own runtime notice is separate from package distributions.
for source in [Path(sys.base_prefix) / "lib/python3.12/LICENSE.txt", Path(sys.base_prefix) / "LICENSE.txt", Path(sys.base_prefix) / "Resources/Python.app/Contents/Resources/License.rtf"]:
    if source.is_file(): shutil.copy2(source, output / ("Python-" + source.name))
