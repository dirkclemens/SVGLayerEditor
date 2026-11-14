#!/bin/sh
# Builds and runs the standalone test harness against the app sources.
# Usage: Tests/run.sh   (set EXPORT_DIR=/some/dir to also write the sample .icon bundle)
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/SVGLayerEditorTests"
SRC=SVGLayerEditor
swiftc -parse-as-library -o "$OUT" \
    "$SRC"/Domain/*.swift \
    "$SRC"/SVGIO/*.swift \
    "$SRC"/Clipboard/ClipboardService.swift \
    "$SRC"/UI/SVGColor+SwiftUI.swift \
    "$SRC"/ViewModel/SVGLayerEditorViewModel.swift \
    Tests/TestHarness.swift
"$OUT"
