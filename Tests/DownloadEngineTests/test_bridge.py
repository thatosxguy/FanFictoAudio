"""Real FanFicFare fixture adapter, packaged protocol, and commit boundary."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def worker(tmp_path, ack="commit\n", source="http://test1.com?sid=1[1-2]"):
    request = tmp_path / "request.json"
    request.write_text(json.dumps({"operation": "download", "source": source,
        "format": "epub", "output": str(tmp_path)}))
    return subprocess.run([sys.executable, str(ROOT / "Scripts/download-worker.py"), "--request", str(request)],
        input=ack, capture_output=True, text=True, timeout=40,
        env=dict(os.environ, PYTHONPATH=str(ROOT / "Vendor")))


def test_download_commits_only_with_ack(tmp_path):
    result = worker(tmp_path)
    assert result.returncode == 0, result.stderr
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert any(event.get("finalizing") for event in events)
    assert events[-1]["type"] == "result"
    assert Path(events[-1]["path"]).is_file()
    assert not list(tmp_path.glob(".fff-*"))


def test_client_disconnect_discards_book_before_publication(tmp_path):
    result = worker(tmp_path, ack="")
    assert result.returncode == 1
    assert json.loads(result.stdout.splitlines()[-1])["type"] == "error"
    assert not list(tmp_path.glob("*.epub"))
    assert not list(tmp_path.glob(".fff-*"))
