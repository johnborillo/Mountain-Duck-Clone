#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/OpenDuck.app"
APPEX_BUNDLE="$APP_BUNDLE/Contents/PlugIns/OpenDuckFileProvider.appex"
SIGNING_IDENTITY="${OPENDUCK_SIGNING_IDENTITY:--}"
TEAM_IDENTIFIER="${OPENDUCK_TEAM_IDENTIFIER:-}"
APP_GROUP_IDENTIFIER="${OPENDUCK_APP_GROUP_IDENTIFIER:-}"
KEYCHAIN_ACCESS_GROUP="${OPENDUCK_KEYCHAIN_ACCESS_GROUP:-}"
SIGNING_ENTITLEMENTS_DIR=""

if [ "$SIGNING_IDENTITY" = "-" ]; then
    APP_GROUP_IDENTIFIER="${APP_GROUP_IDENTIFIER:-group.com.openduck}"
else
    if ! [[ "$TEAM_IDENTIFIER" =~ ^[A-Z0-9]+$ ]]; then
        echo "❌ OPENDUCK_TEAM_IDENTIFIER must be the uppercase Apple team identifier for the selected signing identity."
        exit 1
    fi
    # This macOS-only form needs no App Group provisioning profile. A release
    # may instead pass a registered group.* identifier explicitly.
    APP_GROUP_IDENTIFIER="${APP_GROUP_IDENTIFIER:-$TEAM_IDENTIFIER.com.openduck}"
    if [ -z "$KEYCHAIN_ACCESS_GROUP" ] && [[ "$APP_GROUP_IDENTIFIER" == group.* ]]; then
        KEYCHAIN_ACCESS_GROUP="$APP_GROUP_IDENTIFIER"
    fi
fi

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

/usr/libexec/PlistBuddy -c "Add :OpenDuckAppGroupIdentifier string '$APP_GROUP_IDENTIFIER'" "$APP_BUNDLE/Contents/Info.plist"

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

/usr/libexec/PlistBuddy -c "Set :NSExtension:NSExtensionFileProviderDocumentGroup '$APP_GROUP_IDENTIFIER'" "$APPEX_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :OpenDuckAppGroupIdentifier string '$APP_GROUP_IDENTIFIER'" "$APPEX_BUNDLE/Contents/Info.plist"
if [ -n "$KEYCHAIN_ACCESS_GROUP" ]; then
    /usr/libexec/PlistBuddy -c "Add :OpenDuckKeychainAccessGroup string '$KEYCHAIN_ACCESS_GROUP'" "$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :OpenDuckKeychainAccessGroup string '$KEYCHAIN_ACCESS_GROUP'" "$APPEX_BUNDLE/Contents/Info.plist"
fi

# 4. Sign the bundles
echo "🔏 Code-signing bundles..."
SIGNING_ENTITLEMENTS_DIR="$(mktemp -d)"
APP_ENTITLEMENTS="$SIGNING_ENTITLEMENTS_DIR/App.entitlements"
EXTENSION_ENTITLEMENTS="$SIGNING_ENTITLEMENTS_DIR/Extension.entitlements"
cp "$PROJECT_ROOT/scripts/App.entitlements" "$APP_ENTITLEMENTS"
cp "$PROJECT_ROOT/scripts/Extension.entitlements" "$EXTENSION_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 '$APP_GROUP_IDENTIFIER'" "$APP_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 '$APP_GROUP_IDENTIFIER'" "$EXTENSION_ENTITLEMENTS"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    # keychain-access-groups is restricted and makes an ad-hoc bundle fail AMFI
    # validation. Keep it in the canonical production entitlements, but omit it
    # for local builds; runtime capability detection then uses process-private
    # Keychain storage without pretending the extension can read it.
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$APP_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$EXTENSION_ENTITLEMENTS"
else
    if [ -n "$KEYCHAIN_ACCESS_GROUP" ]; then
        # Restricted Keychain sharing must be paired with provisioning that
        # authorizes these Xcode-generated identity entitlements.
        /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier '$TEAM_IDENTIFIER.com.openduck.app'" "$APP_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier '$TEAM_IDENTIFIER.com.openduck.app.fileprovider'" "$EXTENSION_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string '$TEAM_IDENTIFIER'" "$APP_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string '$TEAM_IDENTIFIER'" "$EXTENSION_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 '$KEYCHAIN_ACCESS_GROUP'" "$APP_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 '$KEYCHAIN_ACCESS_GROUP'" "$EXTENSION_ENTITLEMENTS"
    else
        # For the macOS team-prefixed App Group mode, the signing certificate's
        # TeamIdentifier is sufficient. Claiming application/team entitlements
        # without a provisioning profile causes AMFI to reject the processes.
        /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$APP_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$EXTENSION_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$APP_ENTITLEMENTS"
        /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$EXTENSION_ENTITLEMENTS"
    fi
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
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "⚠️  Ad-hoc signing cannot authorize a shared App Group for a File Provider extension."
    echo "   Finder registration can be inspected, but enumeration requires OPENDUCK_SIGNING_IDENTITY and OPENDUCK_TEAM_IDENTIFIER."
fi
