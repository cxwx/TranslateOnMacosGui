#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs
rsvg-convert -w 2880 -h 1800 docs/screenshot.svg -o docs/screenshot.png
printf 'Created: %s\n' "$PWD/docs/screenshot.png"
