#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

SDK_PATH=$(xcrun --show-sdk-path)

echo "Generating AppIcon.icns and MenuBarIcons pack..."
mkdir -p .build/release Resources/MenuBarIcons BuildResources
swiftc -O -Xfrontend -disable-sandbox -target arm64-apple-macosx13.0 -sdk "${SDK_PATH}" \
    scripts/generate_icons.swift \
    -o .build/release/generate_icons
./.build/release/generate_icons
iconutil -c icns BuildResources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf BuildResources

echo "Building CodexContinue (Release)..."
swiftc -O -Xfrontend -disable-sandbox -target arm64-apple-macosx13.0 -sdk "${SDK_PATH}" \
    Sources/CodexContinue/*.swift \
    -o .build/release/CodexContinue

APP_NAME="CodexContinue"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}/MenuBarIcons"

cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

cp "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
cp Resources/MenuBarIcons/*.png "${RESOURCES_DIR}/MenuBarIcons/"

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Codex Continue</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.CodexContinue</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Continue</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>CodexContinue monitors your active Codex session and sends continue when subagents finish.</string>
</dict>
</plist>
EOF

# Sign bundle with stable identifier
codesign --force --deep --identifier "com.local.CodexContinue" --sign - "${APP_BUNDLE}"

echo "Built ${PWD}/${APP_BUNDLE} successfully!"

if [[ "${1:-}" == "--install" ]]; then
    TARGET_APPS_DIR="/Applications"
    if [[ ! -w "${TARGET_APPS_DIR}" ]]; then
        TARGET_APPS_DIR="${HOME}/Applications"
        mkdir -p "${TARGET_APPS_DIR}"
    fi
    rm -rf "${TARGET_APPS_DIR}/${APP_BUNDLE}"
    cp -R "${APP_BUNDLE}" "${TARGET_APPS_DIR}/${APP_BUNDLE}"
    /usr/bin/tccutil reset Accessibility com.local.CodexContinue 2>/dev/null || true
    echo "Installed to ${TARGET_APPS_DIR}/${APP_BUNDLE}"
fi
