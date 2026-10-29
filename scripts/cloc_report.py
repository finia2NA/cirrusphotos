#!/usr/bin/env python3
"""Summarize cloc's Git-tracked file counts by language and directory."""

import csv
from collections import defaultdict
from pathlib import PurePosixPath
import shutil
import subprocess
import sys


def main():
    if shutil.which("cloc") is None:
        print("cloc is required; install it with: brew install cloc", file=sys.stderr)
        return 1

    result = subprocess.run(
        ["cloc", "--vcs=git", "--by-file-by-lang", "--csv", "--quiet"],
        check=True, capture_output=True, text=True,
    )
    languages = defaultdict(lambda: [0, 0, 0, 0])
    directories = defaultdict(lambda: [0, 0, 0, 0])
    for row in csv.reader(result.stdout.splitlines()):
        if row and row[0] == "SUM":
            break
        if len(row) < 5 or row[0] == "language":
            continue
        language, filename, blank, comment, code = row[:5]
        parts = PurePosixPath(filename).parts[:-1]
        directory = "/".join(parts[:2]) or "."
        for counts in (languages[language], directories[(directory, language)]):
            for index, value in enumerate((1, int(blank), int(comment), int(code))):
                counts[index] += value

    def report(title, rows):
        print(f"\n{title}")
        print(f"{'Group':<48} {'Files':>7} {'Blank':>8} {'Comment':>8} {'Code':>8}")
        for label, counts in rows:
            print(f"{label:<48} {counts[0]:>7} {counts[1]:>8} {counts[2]:>8} {counts[3]:>8}")

    print("Git-tracked files; submodules excluded. Directories grouped to two levels.")
    report("Languages", sorted(languages.items()))
    report("Total", [("All languages", [sum(counts[i] for counts in languages.values())
                                        for i in range(4)])])
    report("Directories and languages", ((f"{directory} / {language}", counts)
                                         for (directory, language), counts in sorted(directories.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
