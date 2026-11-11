#!/usr/bin/env bash
# Compile the runtime Metal shader source offline, so shader errors fail CI
# instead of silently falling back to the debug overlay at app launch.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Sources/Sugrob/Render/ShaderSource.swift"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Take the body of `static let source = """ ... """` and drop the 4-space indent
# that the Swift multi-line literal strips at runtime.
awk '
  /static let source = """/ { inside = 1; next }
  inside && /^    """$/      { exit }
  inside                     { sub(/^    /, ""); print }
' "$SRC" > "$OUT/Shaders.metal"

if grep -q '\\(' "$OUT/Shaders.metal"; then
  echo "error: shader source uses Swift string interpolation; this check cannot extract it" >&2
  exit 1
fi

xcrun -sdk macosx metal -std=macos-metal2.4 -Werror -c "$OUT/Shaders.metal" -o "$OUT/Shaders.air"
echo "Shaders compiled: $(wc -l < "$OUT/Shaders.metal") lines"
