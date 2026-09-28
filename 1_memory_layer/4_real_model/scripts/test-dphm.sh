#!/bin/bash
# Run the DPHM memory-layer test suite (unit tests + latency benchmarks).
#
# The extra flags exist because this machine builds with CommandLineTools
# (no Xcode): Swift Testing ships in the CLT but SwiftPM doesn't add its
# framework/plugin/rpath search paths automatically. With full Xcode
# installed, a plain `swift test --filter DPHMemoryTests` works too.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
FRAMEWORKS="$CLT/Library/Developer/Frameworks"

swift test --filter "${1:-DPHMemoryTests}" \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib"
