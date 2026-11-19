#!/bin/bash
set -euo pipefail

# Local debug build for machines that only have Command Line Tools + Swift 5.8
# (no full Xcode). It compiles the host directly with swiftc instead of SwiftPM.
#
# Limitations of this build:
#   - Sparkle auto-update is stubbed out
#   - Single architecture (the arch of this machine), not a universal binary
#   - Ad-hoc signed only; not notarized like the official release DMG
#
# The project sources are NEVER modified: all compatibility patches are applied
# to a temporary copy. The official release build is still scripts/build_mac.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$ROOT/MacHost/Sources"
OUT_DIR="$ROOT/MacHost/.build/local-compat"
OUT="$OUT_DIR/SideScreen"

# Pick the newest usable SDK shipped with Command Line Tools.
SDK=""
for candidate in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX13.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk; do
    if [ -d "$candidate" ]; then
        SDK="$candidate"
        break
    fi
done

if [ -z "$SDK" ]; then
    echo "error: no macOS SDK found in /Library/Developer/CommandLineTools/SDKs" >&2
    echo "Install Command Line Tools: xcode-select --install" >&2
    exit 1
fi

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx13.0"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sidescreen-local-compat.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Sources" "$OUT_DIR"
cp "$SOURCES"/*.swift "$WORK/Sources/"
cp "$SOURCES/module.modulemap" "$SOURCES/CGVirtualDisplayBridge.h" "$WORK/Sources/"

# 1. Sparkle needs the SwiftPM-resolved framework. Stub the updater so the
#    local binary can be built with plain swiftc. AppInfo is mirrored below.
cat > "$WORK/Sources/AppUpdater.swift" <<'SWIFT'
import Cocoa
import Combine

/// Local compatibility build: Sparkle is stubbed out. The real source is unchanged.
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    private override init() {
        super.init()
        debugLog("Sparkle disabled in local compatibility build")
    }
    @objc func checkForUpdates(_ sender: Any?) {}
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheckForUpdates }
}

enum AppInfo {
    static let version: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let website = URL(string: "https://sidescreen.dev")!
    static let donate = URL(string: "https://sidescreen.dev/donate.html")!
    static let github = URL(string: "https://github.com/tranvuongquocdat/SideScreen")!
    static let changelog = URL(string: "https://github.com/tranvuongquocdat/SideScreen/blob/main/CHANGELOG.md")!
    static let reportProblem = URL(string: "https://github.com/tranvuongquocdat/SideScreen/issues/new/choose")!
}
SWIFT

# 2. Swift 5.9 switch expressions are not understood by Swift 5.8.
if grep -q '= switch quality' "$WORK/Sources/VideoEncoder.swift"; then
    command -v python3 >/dev/null || {
        echo "error: python3 is required to patch VideoEncoder.swift" >&2
        exit 1
    }
    python3 - "$WORK/Sources/VideoEncoder.swift" <<'PY'
import sys

path = sys.argv[1]
with open(path) as f:
    source = f.read()

old = '''            qualityValue = switch quality {
            case "ultralow": 0.5  // Still fast but better text readability
            case "low": 0.65
            case "medium": 0.8   // Sharp text for productivity
            case "high": 0.9     // Very sharp, higher bitrate
            default: 0.5
            }'''
new = '''            qualityValue = {
                switch quality {
                case "ultralow": return 0.5  // Still fast but better text readability
                case "low": return 0.65
                case "medium": return 0.8   // Sharp text for productivity
                case "high": return 0.9     // Very sharp, higher bitrate
                default: return 0.5
                }
            }()'''

if old not in source:
    sys.exit("error: unexpected VideoEncoder.swift layout; patch it manually")

with open(path, "w") as f:
    f.write(source.replace(old, new))
print("patched VideoEncoder.swift for Swift 5.8")
PY
else
    echo "VideoEncoder.swift already Swift 5.8-compatible; skipping patch"
fi

echo "Swift:  $(swift --version 2>&1 | head -1)"
echo "SDK:    $SDK"
echo "Target: $TARGET"

swiftc -sdk "$SDK" -target "$TARGET" \
    -I "$WORK/Sources" \
    -Xcc -fmodule-map-file="$WORK/Sources/module.modulemap" \
    "$WORK"/Sources/*.swift -o "$OUT"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$OUT_DIR/SideScreen.app"
DMG="$OUT_DIR/SideScreen-local-${VERSION}.dmg"

# Use a distinct bundle ID so this local build can coexist with the official
# app installed from the DMG / Play-linked release.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT" "$APP/Contents/MacOS/SideScreen"
chmod +x "$APP/Contents/MacOS/SideScreen"

ICON_BLOCK=""
if [ -f "$ROOT/MacHost/Resources/AppIcon.icns" ]; then
    cp "$ROOT/MacHost/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_BLOCK='    <key>CFBundleIconFile</key>
    <string>AppIcon</string>'
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
$ICON_BLOCK
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app.local</string>
    <key>CFBundleName</key>
    <string>Side Screen (Local)</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen (Local)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display and stream it to your Android device.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Side Screen needs Local Network access so your Android tablet can connect over WiFi.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is enough to launch a locally built app; it is not notarized.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP" 2>/dev/null || \
        echo "warning: ad-hoc codesign failed; if macOS blocks it, run: xattr -cr $APP"
fi

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "error: hdiutil not found; cannot create DMG" >&2
    exit 1
fi
rm -f "$DMG"
hdiutil create -volname "Side Screen" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

file "$OUT"
echo "Build succeeded:"
echo "  binary: $OUT"
echo "  app:    $APP"
echo "  dmg:    $DMG"
