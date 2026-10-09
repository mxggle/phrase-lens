#!/usr/bin/env python3
"""Rebuild and relaunch the signed development app when project files change."""

import hashlib
from pathlib import Path
import subprocess
import time


PROJECT = Path(__file__).resolve().parent.parent
WATCHED = (PROJECT / "Sources", PROJECT / "packaging")
SINGLE_FILES = (
    PROJECT / "Package.swift",
    PROJECT / "scripts" / "run.sh",
    PROJECT / "scripts" / "package-app.sh",
    PROJECT / "scripts" / "toolchain-env.sh",
)


def fingerprint() -> str:
    files = list(SINGLE_FILES)
    for directory in WATCHED:
        files.extend(directory.rglob("*"))
    digest = hashlib.sha256()
    for path in sorted(path for path in files if path.is_file()):
        try:
            stat = path.stat()
        except FileNotFoundError:
            # An editor may atomically replace a source file during a scan.
            continue
        digest.update(f"{path.relative_to(PROJECT)}:{stat.st_mtime_ns}:{stat.st_size}\n".encode())
    return digest.hexdigest()


def main() -> None:
    print("Watching PhraseLens sources. Press Ctrl-C to stop watching.", flush=True)
    current = fingerprint()
    subprocess.run((str(PROJECT / "scripts" / "run.sh"),), cwd=PROJECT, check=False)
    current = fingerprint()
    try:
        while True:
            time.sleep(1)
            updated = fingerprint()
            if updated == current:
                continue
            current = updated
            print("Change detected; rebuilding and restarting PhraseLens…", flush=True)
            subprocess.run((str(PROJECT / "scripts" / "run.sh"),), cwd=PROJECT, check=False)
            # A failed build is retried when the next edit changes the inputs.
            current = fingerprint()
    except KeyboardInterrupt:
        print("Stopped watching.", flush=True)


if __name__ == "__main__":
    main()
