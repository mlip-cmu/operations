#!/usr/bin/env bash
# Run the demo of each project (or of the folders given as arguments).
# Each demo writes its output to <folder>/transcript.txt.
set -euo pipefail
cd "$(dirname "$0")"
folders=("$@")
[ ${#folders[@]} -eq 0 ] && folders=([0-9][0-9]-*/)
for f in "${folders[@]}"; do
  f=${f%/}
  echo "### $f"
  "./$f/demo.sh"
done
