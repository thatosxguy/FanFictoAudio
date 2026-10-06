#!/usr/bin/env python3
"""Package just FanFicFare and Python, without the former Qt GUI."""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
# The helper owns its imported modules; no editable source path is needed at runtime.
spec = '''from PyInstaller.utils.hooks import collect_all, copy_metadata
from pathlib import Path
root = Path(SPECPATH).parent
all_data, all_bins, imports = [], [], []
for package in ("fanficfare", "cloudscraper"):
    data, bins, hidden = collect_all(package)
    all_data += data; all_bins += bins; imports += hidden
all_data += copy_metadata("FanFicFare")
a = Analysis([str(root / "Scripts/download-worker.py")],
    pathex=[str(root / "Vendor")], binaries=all_bins, datas=all_data,
    hiddenimports=imports, excludes=["PySide6", "PyQt6", "tkinter"], optimize=0)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="fanfic-download",
    console=True, strip=False, upx=False, codesign_identity=None)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="fanfic-download")
'''
(root / "build").mkdir(exist_ok=True)
path = root / "build/download-worker.spec"
path.write_text(spec)
environment = dict(os.environ, PYTHONPATH=str(root / "Vendor"), PYINSTALLER_CONFIG_DIR=str(root / "build/pyinstaller-cache"))
subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
    "--distpath", str(root / "build/worker"), "--workpath", str(root / "build/pyinstaller"),
    str(path)], cwd=root, env=environment, check=True)
