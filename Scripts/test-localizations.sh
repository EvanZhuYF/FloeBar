#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/FloeBar/Resources/Localizable.xcstrings"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

python3 - "$CATALOG" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    catalog = json.load(source)

assert catalog["sourceLanguage"] == "en"
assert catalog["strings"]
for key, value in catalog["strings"].items():
    unit = value.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
    assert unit.get("state") == "translated", f"Missing zh-Hans translation: {key}"
    translation = unit.get("value")
    assert translation is not None, f"Missing zh-Hans value: {key}"
    assert key.count("%@") == translation.count("%@"), f"Placeholder mismatch: {key}"

print(f"PASS: {len(catalog['strings'])} localization keys")
PY

xcrun xcstringstool compile "$CATALOG" \
    --output-directory "$TEMP_DIR" \
    --language zh-Hans \
    --serialization-format text
test -s "$TEMP_DIR/zh-Hans.lproj/Localizable.strings"
