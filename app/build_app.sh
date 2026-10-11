#!/bin/bash
set -e

# ==============================================================================
# Build Script for HangulGuard.app (macOS Native GUI Management App)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/HangulGuard.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "🔨 HangulGuard.app 번들 빌드를 시작합니다..."

# 1. Clean previous bundle
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 2. Compile SwiftUI App Binary
echo "  -> SwiftUI 네이티브 바이너리 컴파일 중..."
swiftc -O \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreServices \
    "$SCRIPT_DIR/src/main.swift" \
    -o "$MACOS_DIR/HangulGuard"

chmod +x "$MACOS_DIR/HangulGuard"

# 3. Create Info.plist
echo "  -> Info.plist 메타데이터 생성 중..."
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>HangulGuard</string>
	<key>CFBundleIdentifier</key>
	<string>com.coos.hangulguard</string>
	<key>CFBundleName</key>
	<string>한글가드</string>
	<key>CFBundleDisplayName</key>
	<string>한글가드</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

# 4. Create PkgInfo
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# 5. Ad-hoc Code Signing for Apple Silicon TCC Stability
if command -v codesign >/dev/null 2>&1; then
    echo "  -> Apple Silicon Ad-hoc 코드 서명(codesign) 적용 중..."
    codesign -s - --force --deep "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "✅ HangulGuard.app 번들 빌드가 완료되었습니다!"
echo "   경로: $APP_BUNDLE"
