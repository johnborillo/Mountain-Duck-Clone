#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/OpenDuck.app"
APPEX_BUNDLE="$APP_BUNDLE/Contents/PlugIns/OpenDuckFileProvider.appex"
SIGNING_IDENTITY="${OPENDUCK_SIGNING_IDENTITY:--}"
SIGNING_ENTITLEMENTS_DIR=""

cleanup() {
    if [ -n "$SIGNING_ENTITLEMENTS_DIR" ] && [ -d "$SIGNING_ENTITLEMENTS_DIR" ]; then
        rm -rf "$SIGNING_ENTITLEMENTS_DIR"
    fi
}
trap cleanup EXIT

# A partially updated Command Line Tools install can contain a Swift compiler
# and SDK whose patch-level swiftlang builds differ. Swift normally rejects the
# SDK interfaces even though they are compatible. Detect that exact condition
# and identify the SDK interface version to the frontend; normal installations
# continue using swiftc directly.
SDK_PATH="$(xcrun --show-sdk-path)"
SDK_SWIFT_INTERFACE="$SDK_PATH/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
if [ -f "$SDK_SWIFT_INTERFACE" ]; then
    TOOLCHAIN_SWIFTLANG="$(swift --version | sed -n 's/.*swiftlang-\([^ )]*\).*/\1/p' | head -1)"
    SDK_SWIFTLANG="$(sed -n 's/.*swiftlang-\([^ )]*\).*/\1/p' "$SDK_SWIFT_INTERFACE" | head -1)"
    if [ -n "$TOOLCHAIN_SWIFTLANG" ] && [ -n "$SDK_SWIFTLANG" ] && [ "$TOOLCHAIN_SWIFTLANG" != "$SDK_SWIFTLANG" ]; then
        echo "ℹ️  Using SDK Swift interface compatibility mode ($TOOLCHAIN_SWIFTLANG -> $SDK_SWIFTLANG)."
        export OPENDUCK_INTERFACE_COMPILER_VERSION="$SDK_SWIFTLANG"
        export OPENDUCK_REAL_SWIFTC="$(xcrun --find swiftc)"
        export SWIFT_EXEC="$PROJECT_ROOT/scripts/swiftc_compat.sh"
    fi
fi

echo "🦆 Building OpenDuck release binaries..."
cd "$PROJECT_ROOT"
# SwiftPM accepts one --product per invocation. Building both explicitly
# prevents a stale host executable from being copied into the new bundle.
swift build -c release --product OpenDuckApp
swift build -c release --product OpenDuckExtension

echo "📦 Assembling macOS Application Bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APPEX_BUNDLE/Contents/MacOS"
mkdir -p "$APPEX_BUNDLE/Contents/Resources"

# 1. Copy Executables
cp "$PROJECT_ROOT/.build/release/OpenDuckApp" "$APP_BUNDLE/Contents/MacOS/OpenDuck"
cp "$PROJECT_ROOT/.build/release/OpenDuckExtension" "$APPEX_BUNDLE/Contents/MacOS/OpenDuckFileProvider"

# 2. Generate Host App Info.plist
cat << 'PLIST' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OpenDuck</string>
    <key>CFBundleIdentifier</key>
    <string>com.openduck.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OpenDuck</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>8</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# 3. Generate File Provider Extension Info.plist
cat << 'PLIST' > "$APPEX_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OpenDuckFileProvider</string>
    <key>CFBundleIdentifier</key>
    <string>com.openduck.app.fileprovider</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OpenDuckFileProvider</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>8</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <!-- fileproviderd reads this key directly from NSExtension. -->
        <key>NSExtensionFileProviderDocumentGroup</key>
        <string>group.com.openduck</string>
        <!-- This switches fileproviderd to the replicated/enumerating API
             implemented by FileProviderExtension. Without it macOS attempts
             to load the class as the legacy NSFileProviderExtension API. -->
        <key>NSExtensionFileProviderSupportsEnumeration</key>
        <true/>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.fileprovider-nonui</string>
        <key>NSExtensionPrincipalClass</key>
        <string>FileProviderExtension</string>
    </dict>
    <key>XPCService</key>
    <dict>
        <key>JoinExistingSession</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# 4. Sign the bundles
echo "🔏 Code-signing bundles..."
APP_ENTITLEMENTS="$PROJECT_ROOT/scripts/App.entitlements"
EXTENSION_ENTITLEMENTS="$PROJECT_ROOT/scripts/Extension.entitlements"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    # keychain-access-groups is restricted and makes an ad-hoc bundle fail AMFI
    # validation. Keep it in the canonical production entitlements, but omit it
    # for local builds; runtime capability detection then uses process-private
    # Keychain storage without pretending the extension can read it.
    SIGNING_ENTITLEMENTS_DIR="$(mktemp -d)"
    APP_ENTITLEMENTS="$SIGNING_ENTITLEMENTS_DIR/App.entitlements"
    EXTENSION_ENTITLEMENTS="$SIGNING_ENTITLEMENTS_DIR/Extension.entitlements"
    cp "$PROJECT_ROOT/scripts/App.entitlements" "$APP_ENTITLEMENTS"
    cp "$PROJECT_ROOT/scripts/Extension.entitlements" "$EXTENSION_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$APP_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$EXTENSION_ENTITLEMENTS"
fi

codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$EXTENSION_ENTITLEMENTS" "$APPEX_BUNDLE"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$APP_ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# 5. Install to /Applications for system-wide registration
echo "📂 Installing to /Applications/OpenDuck.app..."
rm -rf "/Applications/OpenDuck.app"
cp -R "$APP_BUNDLE" "/Applications/OpenDuck.app"

# 6. Register with LaunchServices
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/OpenDuck.app"

echo "✓ OpenDuck.app installed to /Applications!"
