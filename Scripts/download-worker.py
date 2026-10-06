#!/usr/bin/env python3
"""Single-job bridge. stdout is JSON; publication requires a parent ACK."""
from contextlib import redirect_stdout
from pathlib import Path
import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", type=Path, required=True)
    args = parser.parse_args()
    channel = sys.stdout

    def emit(event):
        channel.write(json.dumps(event, ensure_ascii=False) + "\n")
        channel.flush()
        if event.get("finalizing"):
            # The native client serializes cancellation with this ACK. EOF
            # means the client quit; leave the completed EPUB unpublished.
            if sys.stdin.readline().strip() != "commit":
                raise RuntimeError("Publication cancelled before saving.")

    try:
        with redirect_stdout(sys.stderr):
            from fanficfare_gui.engine import execute
            from fanficfare_gui.session import Session
            request = json.loads(args.request.read_text(encoding="utf-8"))
            if request.get("format", "epub") != "epub":
                raise ValueError("This audiobook app downloads EPUB files.")
            session = Session()
            try:
                result = execute(request, emit, session)
            finally:
                session.close()
        emit({"type": "result", **result})
        return 0
    except Exception as error:
        emit({"type": "error", "message": f"{type(error).__name__}: {error}"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
