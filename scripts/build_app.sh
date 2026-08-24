#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
APP_BUNDLE="$BUILD_DIR/OpenMountainDuck.app"
APPEX_BUNDLE="$APP_BUNDLE/Contents/PlugIns/OpenMountainDuckFileProvider.appex"

echo "🦆 Building OpenMountainDuck release binaries..."
cd "$PROJECT_ROOT"
swift build -c release

echo "📦 Assembling macOS Application Bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APPEX_BUNDLE/Contents/MacOS"
mkdir -p "$APPEX_BUNDLE/Contents/Resources"

# 1. Copy Executables
cp "$PROJECT_ROOT/.build/release/OpenMountainDuckApp" "$APP_BUNDLE/Contents/MacOS/OpenMountainDuck"
cp "$PROJECT_ROOT/.build/release/OpenMountainDuckExtension" "$APPEX_BUNDLE/Contents/MacOS/OpenMountainDuckFileProvider"

# 2. Generate Host App Info.plist
cat << 'PLIST' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>OpenMountainDuck</string>
    <key>CFBundleIdentifier</key>
    <string>com.openmountainduck.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OpenMountainDuck</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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
    <string>OpenMountainDuckFileProvider</string>
    <key>CFBundleIdentifier</key>
    <string>com.openmountainduck.app.fileprovider</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OpenMountainDuckFileProvider</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.fileprovider-nonui</string>
        <key>NSExtensionFileProviderDocumentGroup</key>
        <string>group.com.openmountainduck</string>
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
codesign --force --sign - --entitlements "$PROJECT_ROOT/scripts/Extension.entitlements" "$APPEX_BUNDLE"
codesign --force --sign - "$APP_BUNDLE"

# 5. Install to /Applications for system-wide registration
echo "📂 Installing to /Applications/OpenMountainDuck.app..."
rm -rf "/Applications/OpenMountainDuck.app"
cp -R "$APP_BUNDLE" "/Applications/OpenMountainDuck.app"

# 6. Register with LaunchServices
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/OpenMountainDuck.app"

echo "✓ OpenMountainDuck.app installed to /Applications!"
