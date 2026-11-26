#!/usr/bin/env bash
# Builds dspenc (jackoalan/gc-dspadpcm-encode, MIT) into tools/bin/. mkwvoice.py uses it to
# encode voice clips as DSP-ADPCM. Needs curl and a C compiler.
set -euo pipefail
COMMIT=039712baa1291fbd77a1390e0496757122efd81b
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=$(mktemp -d); trap 'rm -rf "$SRC"' EXIT
for f in main.c grok.c LICENSE; do
  curl -fsSL -o "$SRC/$f" "https://raw.githubusercontent.com/jackoalan/gc-dspadpcm-encode/$COMMIT/$f"
done
mkdir -p "$HERE/bin"
${CC:-cc} -O2 -o "$HERE/bin/dspenc" "$SRC/main.c" "$SRC/grok.c" -lm
cp "$SRC/LICENSE" "$HERE/bin/dspenc.LICENSE"
echo "built $HERE/bin/dspenc"
