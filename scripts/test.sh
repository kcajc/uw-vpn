#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
common=(-swift-version 5 -parse-as-library -warnings-as-errors)
xcrun swiftc "${common[@]}" -D TESTING Sources/Core.swift Sources/IPC.swift Tests/CoreTests.swift -o build/tests/core
xcrun swiftc "${common[@]}" -D TESTING Sources/Core.swift Sources/IPC.swift Sources/Runner.swift -o build/tests/runner
xcrun swiftc "${common[@]}" Tests/FakeOpenConnect.swift -o build/tests/fake-openconnect
build/tests/core
python3 Tests/integration.py
if [[ "${1:-}" == --ui ]]; then
  xcrun swiftc "${common[@]}" -D UI_TEST Sources/Core.swift Sources/IPC.swift Sources/Keychain.swift \
    Sources/Capture.swift Sources/App.swift Tests/UITests.swift -framework AppKit -framework Security \
    -o build/tests/ui-smoke
  build/tests/ui-smoke
fi
