#!/usr/bin/env python3
"""Record the installed dependency closure for this macOS build environment."""
from importlib.metadata import distribution
from pathlib import Path
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

root = Path(__file__).resolve().parents[1]
pending = [Requirement(line) for line in (root / "requirements-build.txt").read_text().splitlines()
           if line.strip() and not line.startswith(("#", "-"))]
seen = set()
versions = {}
while pending:
    requested = pending.pop()
    key = (canonicalize_name(requested.name), tuple(sorted(requested.extras)))
    if key in seen:
        continue
    seen.add(key)
    installed = distribution(requested.name)
    if not requested.specifier.contains(installed.version, prereleases=True):
        raise RuntimeError(f"Installed {requested.name} does not satisfy {requested.specifier}")
    versions[installed.metadata["Name"]] = installed.version
    for text in installed.requires or []:
        dependency = Requirement(text)
        if dependency.marker is None or any(dependency.marker.evaluate({"extra": extra}) for extra in (requested.extras or {""})):
            pending.append(dependency)
lock = root / "requirements-build.lock"
lock.write_text("# macOS Python 3.12 dependency closure for version 1.3.0.\n# Regenerate in a tested build venv with Scripts/lock-build-dependencies.py.\n" +
                "\n".join(f"{name}=={version}" for name, version in sorted(versions.items(), key=lambda item: item[0].lower())) + "\n")
print(f"Locked {len(versions)} build dependencies")
