#!/usr/bin/env python3
"""Switch the active credentials and their caches without reading credentials."""

import fcntl
import os
from pathlib import Path
import subprocess
import sys


def switch_user(root: Path) -> str:
    env = root / ".env"
    real_env = root / ".env.real"
    test_env = root / ".env.test"
    cache = root / ".cache"
    real_cache = root / ".cache.real"
    test_cache = root / ".cache.test"

    paths = (env, real_env, test_env, cache, real_cache, test_cache)
    if any(path.is_symlink() for path in paths):
        raise RuntimeError("User and cache paths must not be symbolic links; no files were changed.")
    if not env.is_file() or real_env.exists() == test_env.exists():
        raise RuntimeError("Expected .env and exactly one of .env.real or .env.test; no files were changed.")
    to_test = test_env.exists()
    source_env, target_env = (test_env, real_env) if to_test else (real_env, test_env)
    source_cache, target_cache = (test_cache, real_cache) if to_test else (real_cache, test_cache)
    if not source_env.is_file():
        raise RuntimeError("The inactive credential file is not a regular file; no files were changed.")
    if target_cache.exists() or (source_cache.exists() and not source_cache.is_dir()):
        raise RuntimeError("Cache layout is ambiguous; no files were changed.")
    if cache.exists() and not cache.is_dir():
        raise RuntimeError("The active cache is not a directory; no files were changed.")
    if not to_test and not source_cache.is_dir():
        raise RuntimeError("The real-user cache backup is missing; no files were changed.")

    undo = []

    def move(source: Path, destination: Path) -> None:
        os.rename(source, destination)
        undo.append(lambda: os.rename(destination, source))

    def create(path: Path) -> None:
        path.mkdir()
        undo.append(path.rmdir)

    try:
        if not cache.exists():
            create(cache)
        move(cache, target_cache)
        if source_cache.exists():
            move(source_cache, cache)
        else:
            create(cache)
        move(env, target_env)
        move(source_env, env)
    except BaseException:
        for restore in reversed(undo):
            restore()
        raise
    return "phototest" if to_test else "real user"


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    with (root / ".switch-user.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another user switch is in progress.", file=sys.stderr)
            return 1
        running = subprocess.run(["pgrep", "-x", "SynoTimeline"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if running.returncode == 0:
            print("Quit SynoTimeline before switching users.", file=sys.stderr)
            return 1
        if running.returncode != 1:
            print("Could not check whether SynoTimeline is running.", file=sys.stderr)
            return 1
        try:
            active = switch_user(root)
        except (OSError, RuntimeError) as error:
            print(f"Could not switch users: {error}", file=sys.stderr)
            return 1
        print(f"Active user: {active}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
