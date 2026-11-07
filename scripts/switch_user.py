#!/usr/bin/env python3
"""Switch the active development account and its cache without reading credentials.

Targets:
  real  .env is the real account (.env.test is parked); .cache is its cache.
  test  .env is the phototest account (.env.real is parked); .cache is its cache.
  none  no .env, so the app signs in itself; .cache is a fresh cache that is
        deleted when switching away from none.

Parked caches are .cache.real and .cache.test. Accounts signed in from the app are
kept in the Keychain, not in .cache; sign out in the app to remove them.
"""

import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys

TARGETS = ("real", "test", "none")


def active_target(root: Path) -> str:
    env, real_env, test_env = root / ".env", root / ".env.real", root / ".env.test"
    if env.is_file() and test_env.is_file() and not real_env.exists():
        return "real"
    if env.is_file() and real_env.is_file() and not test_env.exists():
        return "test"
    if not env.exists() and real_env.is_file() and test_env.is_file():
        return "none"
    raise RuntimeError("Expected .env with one of .env.real or .env.test, or no .env with both; no files were changed.")


def switch_user(root: Path, target: str) -> str:
    if target not in TARGETS:
        raise RuntimeError(f"Unknown target {target!r}; use one of {', '.join(TARGETS)}.")
    env = root / ".env"
    cache = root / ".cache"
    parked_env = {"real": root / ".env.real", "test": root / ".env.test"}
    parked_cache = {"real": root / ".cache.real", "test": root / ".cache.test"}
    discarded = root / ".cache.none-discard"

    paths = (env, cache, discarded, *parked_env.values(), *parked_cache.values())
    if any(path.is_symlink() for path in paths):
        raise RuntimeError("Account and cache paths must not be symbolic links; no files were changed.")
    current = active_target(root)
    if current == target:
        return target
    if cache.exists() and not cache.is_dir():
        raise RuntimeError("The active cache is not a directory; no files were changed.")
    if discarded.exists():
        raise RuntimeError(f"{discarded.name} is left from an earlier switch; remove it first. No files were changed.")
    if current in parked_cache and parked_cache[current].exists():
        raise RuntimeError(f"{parked_cache[current].name} already exists; no files were changed.")
    if target in parked_cache and parked_cache[target].exists() and not parked_cache[target].is_dir():
        raise RuntimeError(f"{parked_cache[target].name} is not a directory; no files were changed.")

    undo = []

    def move(source: Path, destination: Path) -> None:
        os.rename(source, destination)
        undo.append(lambda: os.rename(destination, source))

    def create(path: Path) -> None:
        path.mkdir()
        undo.append(path.rmdir)

    try:
        # Park or discard the current account's cache and credentials.
        if not cache.exists():
            create(cache)
        if current == "none":
            move(cache, discarded)
        else:
            move(cache, parked_cache[current])
            move(env, parked_env[current])
        # Activate the target.
        if target == "none":
            create(cache)
        else:
            if parked_cache[target].exists():
                move(parked_cache[target], cache)
            else:
                create(cache)
            move(parked_env[target], env)
    except BaseException:
        for restore in reversed(undo):
            restore()
        raise
    # Only after every rename succeeded: the none cache is not kept.
    if discarded.exists():
        shutil.rmtree(discarded)
    return target


def main(arguments: list[str]) -> int:
    if len(arguments) != 1 or arguments[0] not in TARGETS:
        print(f"Usage: make switch-user TARGET={'|'.join(TARGETS)}", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parent.parent
    with (root / ".switch-user.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another user switch is in progress.", file=sys.stderr)
            return 1
        running = subprocess.run(["pgrep", "-x", "CirrusPhotos"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if running.returncode == 0:
            print("Quit Cirrus Photos before switching accounts.", file=sys.stderr)
            return 1
        if running.returncode != 1:
            print("Could not check whether Cirrus Photos is running.", file=sys.stderr)
            return 1
        try:
            before = active_target(root)
            active = switch_user(root, arguments[0])
        except (OSError, RuntimeError) as error:
            print(f"Could not switch accounts: {error}", file=sys.stderr)
            return 1
        if before == active:
            print(f"Already active: {active}")
        else:
            print(f"Active: {active} (was {before})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
