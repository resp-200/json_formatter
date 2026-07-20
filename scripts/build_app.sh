#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/JSON Formatter.app"
DMG_PATH="$ROOT_DIR/dist/JSON Formatter.dmg"
DMG_STAGING_DIR="$ROOT_DIR/dist/dmg-staging"
EXECUTABLE_NAME="JSONFormatter"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cleanup() {
    rm -rf "$DMG_STAGING_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
rm -rf "$APP_DIR" "$DMG_PATH" "$DMG_STAGING_DIR"
swift build -c release

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/JSONFormatterApp" "$MACOS_DIR/$EXECUTABLE_NAME"
cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>JSONFormatter</string>
    <key>CFBundleIdentifier</key>
    <string>com.zz.jsonformatter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>JSON Formatter</string>
    <key>CFBundleDisplayName</key>
    <string>JSON Formatter</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>JSON Formatter URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>jsonformatter</string>
                <string>json-formatter</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>JSON File</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>json</string>
                <string>jsonc</string>
                <string>geojson</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.json</string>
                <string>public.text</string>
            </array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>Format JSON</string>
            </dict>
            <key>NSMessage</key>
            <string>openSelection</string>
            <key>NSPortName</key>
            <string>JSON Formatter</string>
            <key>NSSendTypes</key>
            <array>
                <string>NSStringPboardType</string>
                <string>public.utf8-plain-text</string>
            </array>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.4.0</string>
    <key>CFBundleVersion</key>
    <string>1.4.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleScriptEnabled</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_DIR"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    printf 'Signing app with identity: %s\n' "$SIGN_IDENTITY"
    codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    printf 'Warning: SIGN_IDENTITY is not set; using ad-hoc signing for local/temporary testing only.\n' >&2
    printf 'Warning: ad-hoc signing does not guarantee another Mac can approve this app in Privacy & Security.\n' >&2
    codesign --force --deep --sign - "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if command -v spctl >/dev/null 2>&1; then
    if SPCTL_OUTPUT="$(spctl --assess --type execute --verbose=4 "$APP_DIR" 2>&1)"; then
        printf 'spctl assessment passed:\n%s\n' "$SPCTL_OUTPUT"
    else
        printf 'spctl assessment did not pass; this is expected for non-notarized or non-Developer ID builds.\n' >&2
        printf '%s\n' "$SPCTL_OUTPUT" >&2
    fi
fi

mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_DIR" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create -volname "JSON Formatter" -srcfolder "$DMG_STAGING_DIR" -ov -format UDZO "$DMG_PATH"

printf 'Built app: %s\n' "$APP_DIR"
printf 'Built dmg: %s\n' "$DMG_PATH"
