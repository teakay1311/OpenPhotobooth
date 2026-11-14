#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "=== 1. Generating Xcode project via xcodegen ==="
xcodegen generate --spec project.yml

echo "=== 2. Building Release configuration ==="
xcodebuild -project OpenPhotobooth.xcodeproj \
  -scheme OpenPhotobooth \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Release \
  build

DERIVED_DATA_APP="$(find ~/Library/Developer/Xcode/DerivedData -type d -name "Open Photobooth.app" -path "*/Release/*" 2>/dev/null | head -n 1)"

if [ -n "$DERIVED_DATA_APP" ] && [ -d "$DERIVED_DATA_APP" ]; then
  mkdir -p "$PROJECT_ROOT/Build/Release"
  rm -rf "$PROJECT_ROOT/Build/Release/Open Photobooth.app"
  cp -R "$DERIVED_DATA_APP" "$PROJECT_ROOT/Build/Release/"
  echo "=== 3. Successfully packaged app to: $PROJECT_ROOT/Build/Release/Open Photobooth.app ==="
else
  echo "Error: Could not locate built Open Photobooth.app" >&2
  exit 1
fi
