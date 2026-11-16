#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qa_root="$(mktemp -d /tmp/open-photobooth-qa.XXXXXX)"
printf 'QA workspace: %s\n' "$qa_root"
cp -R "$project_root/Sources" "$project_root/Resources" "$project_root/Tests" "$project_root/project.yml" "$qa_root/"
cd "$qa_root"
/usr/bin/sed -i '' \
    -e 's/PRODUCT_BUNDLE_IDENTIFIER: vn.openphotobooth.app$/PRODUCT_BUNDLE_IDENTIFIER: vn.openphotobooth.qa.app/' \
    -e 's/PRODUCT_BUNDLE_IDENTIFIER: vn.openphotobooth.tests$/PRODUCT_BUNDLE_IDENTIFIER: vn.openphotobooth.qa.tests/' project.yml
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Open Photobooth QA' Resources/Info.plist
xcodegen generate --spec project.yml
exec xcodebuild -project OpenPhotobooth.xcodeproj -scheme OpenPhotobooth \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -derivedDataPath "$qa_root/DerivedData" -resultBundlePath "$qa_root/QA.xcresult" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PHOTOBOOTH_QA_HOST' "$@" test
