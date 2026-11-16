#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

release_dir="$PROJECT_ROOT/Build/Release"
app_name="Open Photobooth.app"
destination="$release_dir/$app_name"
lock="$release_dir/.packaging"
mkdir -p "$release_dir"
if ! mkdir "$lock"; then
  echo "Error: Release packaging is already in progress: $lock" >&2
  exit 1
fi
backup="$lock/previous.app"
installed=0
complete=0
cleanup() {
  status=$?
  trap - EXIT
  if [ "$complete" -eq 0 ]; then
    if [ "$installed" -eq 1 ]; then
      rm -rf "$destination" || exit 1
    fi
    if [ -d "$backup" ] && ! mv "$backup" "$destination"; then
      echo "Error: Previous app is still available at $backup" >&2
      exit 1
    fi
  fi
  rm -rf "$lock"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "=== 1. Generating Xcode project via xcodegen ==="
xcodegen generate --spec project.yml

echo "=== 2. Building universal Release configuration ==="
xcodebuild -project OpenPhotobooth.xcodeproj \
  -scheme OpenPhotobooth \
  -destination 'generic/platform=macOS' \
  -configuration Release \
  -derivedDataPath "$lock/DerivedData" \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  build

source_app="$lock/DerivedData/Build/Products/Release/$app_name"
staged="$lock/$app_name"
test -d "$source_app"
ditto "$source_app" "$staged"
diff -qr "$source_app" "$staged"
plist="$staged/Contents/Info.plist"
plutil -lint "$plist"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")" = vn.openphotobooth.app
binary="$staged/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
test -x "$binary"
source_binary="$source_app/Contents/MacOS/${binary##*/}"
source_hash="$(shasum -a 256 < "$source_binary")"
test "$(shasum -a 256 < "$binary")" = "$source_hash"
architectures="$(xcrun lipo -archs "$binary")"
case "$architectures" in
  "arm64 x86_64"|"x86_64 arm64") ;;
  *) echo "Error: Unexpected Release architectures: $architectures" >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$staged"

if [ -e "$destination" ]; then
  mv "$destination" "$backup"
fi
installed=1
mv "$staged" "$destination"
codesign --verify --deep --strict "$destination"
test "$(shasum -a 256 < "$destination/Contents/MacOS/${binary##*/}")" = "$source_hash"
complete=1
echo "Executable SHA-256: ${source_hash%% *}"
echo "=== 3. Successfully packaged app to: $destination ==="
