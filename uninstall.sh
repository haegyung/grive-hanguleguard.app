#!/bin/bash
set -e

# ==============================================================================
# macos-hangul-nfc-cleaner: Uninstaller
# - Stops and removes launchd daemon
# - Removes Finder Quick Actions
# - Cleans up installed binaries and symlinks
# ==============================================================================

echo "============================================================"
echo "  🗑️  macos-hangul-nfc-cleaner 제거를 시작합니다"
echo "============================================================"

PLIST_LABEL="com.grive.hangulguard"
LEGACY_LABEL="com.coos.korean-nfc-normalizer"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LEGACY_PLIST_PATH="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
SERVICES_DIR="$HOME/Library/Services"
LOCAL_BIN="$HOME/.local/bin"
TARGET_BIN_DIR="$HOME/.local/bin/finder-tools"

# 1. Stop and remove launchd agents
echo "🛑 백그라운드 데몬 중지 및 등록 해제 중..."
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"

launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || launchctl unload "$LEGACY_PLIST_PATH" 2>/dev/null || true
rm -f "$LEGACY_PLIST_PATH"
echo "  -> LaunchAgent plist 삭제 완료"

# 2. Remove Quick Actions
echo "🖱️  Finder 우클릭 빠른 동작(Quick Action) 제거 중..."
rm -rf "$SERVICES_DIR/윈도우 호환 압축 (ZIP).workflow"
rm -rf "$SERVICES_DIR/한글 자모 결합 (NFC 변환).workflow"
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "  -> 빠른 동작 메뉴 제거 완료"

# 3. Remove Symlinks
echo "🔗 터미널 CLI 심볼릭 링크 제거 중..."
rm -f "$LOCAL_BIN/winzip"
rm -f "$LOCAL_BIN/fix-korean-jamo"
rm -f "$LOCAL_BIN/nfc-watcher"

# 4. Remove Binary & Script directory
if [[ -d "$TARGET_BIN_DIR" ]]; then
    echo "📁 실행 도구 디렉터리 삭제 중 ($TARGET_BIN_DIR)..."
    rm -rf "$TARGET_BIN_DIR"
fi

echo ""
echo "💡 로그 및 설정 파일을 삭제하시겠습니까? (기본값: 유지)"
read -r -p "   로그/설정 파일도 완전 삭제하려면 'y'를 입력하세요 [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/.local/state/finder-tools"
    rm -rf "$HOME/.config/finder-tools"
    echo "  -> 로그 및 설정 파일이 완전 삭제되었습니다."
else
    echo "  -> 로그 및 설정 파일은 유지됩니다."
fi

echo ""
echo "============================================================"
echo "  ✅ macos-hangul-nfc-cleaner가 완전히 제거되었습니다."
echo "============================================================"
