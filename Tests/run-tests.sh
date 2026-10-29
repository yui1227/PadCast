#!/bin/bash
# 編譯並執行錄影引擎的自動測試（不需要 iPad）
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O Sources/Util.swift Sources/Settings.swift Sources/SegmentWriter.swift Sources/Recorder.swift \
    Sources/ReplayExporter.swift Tests/main.swift -o build/padcast-tests \
    -framework Cocoa -framework AVFoundation -framework CoreMediaIO -framework VideoToolbox
./build/padcast-tests build/test-output
