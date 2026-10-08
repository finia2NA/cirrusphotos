#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v cloc >/dev/null 2>&1; then
    echo "cloc is required to count lines of code. Install it with: brew install cloc" >&2
    exit 1
fi

printf '%-28s %6s %8s %9s %9s\n' "Language" "Files" "Blank" "Comment" "Code"

cloc --quiet --csv Sources Tests scripts Package.swift Makefile |
    tail -n +2 |
    sort -t, -k5 -nr |
    awk -F, '
        $2 == "SUM" { next }
        {
            printf "%-28s %6d %8d %9d %9d\n", $2, $1, $3, $4, $5
            files += $1; blank += $3; comment += $4; code += $5
        }
        END { printf "%-28s %6d %8d %9d %9d\n", "Total", files, blank, comment, code }
    '

echo
printf '%-28s %6s %8s %9s %9s\n' "Folder" "Files" "Blank" "Comment" "Code"

folders=()
for dir in Sources/*/ Tests/*/; do
    folders+=("${dir%/}")
done
folders+=(scripts)

{
    for dir in "${folders[@]}"; do
        cloc --quiet --csv "$dir" | awk -F, -v name="$dir" '$2 == "SUM" { print name "," $1 "," $3 "," $4 "," $5 }'
    done
    cloc --quiet --csv Package.swift Makefile | awk -F, '$2 == "SUM" { print "Root files," $1 "," $3 "," $4 "," $5 }'
} |
    sort -t, -k5 -nr |
    awk -F, '
        {
            printf "%-28s %6d %8d %9d %9d\n", $1, $2, $3, $4, $5
            files += $2; blank += $3; comment += $4; code += $5
        }
        END { printf "%-28s %6d %8d %9d %9d\n", "Total", files, blank, comment, code }
    '
