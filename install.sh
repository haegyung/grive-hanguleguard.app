#!/bin/bash
set -e

# ==============================================================================
# macos-hangul-nfc-cleaner: Installer
# - Installs Swift native real-time FSEvents normalizer daemon
# - Installs Finder Quick Actions (Windows Clean Zip & NFC Fix)
# - Installs CLI tools (winzip, fix-korean-jamo)
# ==============================================================================

echo "============================================================"
echo "  🚀 macos-hangul-nfc-cleaner 설치를 시작합니다"
echo "============================================================"

# 1. OS Check
if [[ "$(uname)" != "Darwin" ]]; then
    echo "❌ 오류: macOS 환경에서만 실행할 수 있습니다."
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BIN_DIR="$HOME/.local/bin/finder-tools"
TARGET_STATE_DIR="$HOME/.local/state/finder-tools"
TARGET_CONFIG_DIR="$HOME/.config/finder-tools"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
SERVICES_DIR="$HOME/Library/Services"
LOCAL_BIN="$HOME/.local/bin"

# 2. Create Target Directories
echo "📁 필수 디렉터리 생성 중..."
mkdir -p "$TARGET_BIN_DIR" "$TARGET_STATE_DIR" "$TARGET_CONFIG_DIR" "$LAUNCH_AGENTS_DIR" "$SERVICES_DIR" "$LOCAL_BIN"

# 3. Build or Install Swift Binary
echo "⚙️  Swift 데몬 바이너리 준비 중..."
if command -v swiftc >/dev/null 2>&1; then
    echo "  -> swiftc 컴파일러 감지됨: 최적화 네이티브 바이너리 빌드 중..."
    swiftc -O "$PROJECT_DIR/src/nfc_watcher.swift" -o "$TARGET_BIN_DIR/nfc_watcher"
    # Also keep in project bin for offline distribution
    cp "$TARGET_BIN_DIR/nfc_watcher" "$PROJECT_DIR/bin/nfc_watcher"
else
    if [[ -f "$PROJECT_DIR/bin/nfc_watcher" ]]; then
        echo "  -> swiftc 미설치: 사전 컴파일된 번들 바이너리를 사용합니다."
        cp "$PROJECT_DIR/bin/nfc_watcher" "$TARGET_BIN_DIR/nfc_watcher"
    else
        echo "❌ 오류: swiftc 컴파일러가 없고 사전 빌드된 바이너리도 없습니다."
        exit 1
    fi
fi
chmod +x "$TARGET_BIN_DIR/nfc_watcher"

# 4. Copy Scripts
echo "📜 CLI 스크립트 복사 중..."
cp "$PROJECT_DIR/src/winzip.py" "$TARGET_BIN_DIR/winzip.py"
cp "$PROJECT_DIR/src/fix_korean_jamo.py" "$TARGET_BIN_DIR/fix_korean_jamo.py"
chmod +x "$TARGET_BIN_DIR/winzip.py" "$TARGET_BIN_DIR/fix_korean_jamo.py"

# 5. Symlinks for Terminal Usage
echo "🔗 터미널 CLI 심볼릭 링크 생성 중 (~/.local/bin)..."
ln -sf "$TARGET_BIN_DIR/winzip.py" "$LOCAL_BIN/winzip"
ln -sf "$TARGET_BIN_DIR/fix_korean_jamo.py" "$LOCAL_BIN/fix-korean-jamo"
ln -sf "$TARGET_BIN_DIR/nfc_watcher" "$LOCAL_BIN/nfc-watcher"

# 6. Install Finder Quick Actions
echo "🖱️  Finder 우클릭 빠른 동작(Quick Action) 설치 중..."
for wf in "$PROJECT_DIR"/services/*.workflow; do
    wf_name="$(basename "$wf")"
    target_wf="$SERVICES_DIR/$wf_name"
    
    rm -rf "$target_wf"
    cp -R "$wf" "$target_wf"
    
    # Replace {{HOME}} in document.wflow
    wflow_file="$target_wf/Contents/document.wflow"
    if [[ -f "$wflow_file" ]]; then
        sed -i '' "s|{{HOME}}|$HOME|g" "$wflow_file"
    fi
    echo "  -> '$wf_name' 설치 완료"
done

# Refresh Finder Services Cache
/System/Library/CoreServices/pbs -update 2>/dev/null || true

# 7. Install & Start launchd Agent
PLIST_LABEL="com.coos.korean-nfc-normalizer"
PLIST_TARGET="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

echo "🔄 시스템 상주 서비스(LaunchAgent) 등록 및 가동 중..."
# Unload if currently loaded
launchctl unload "$PLIST_TARGET" 2>/dev/null || true

# Generate plist from template
sed "s|{{HOME}}|$HOME|g" "$PROJECT_DIR/launchd/$PLIST_LABEL.plist.template" > "$PLIST_TARGET"

# Load new service
launchctl load -w "$PLIST_TARGET"

sleep 1
if launchctl list | grep -q "$PLIST_LABEL"; then
    echo "  ✅ 백그라운드 자동 정규화 데몬이 정상 가동되었습니다!"
else
    echo "  ⚠️ 서비스 로드 확인 필요: 'launchctl list | grep $PLIST_LABEL'"
fi

# 8. PATH check
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "💡 안내: ~/.local/bin 경로가 PATH에 포함되어 있지 않습니다."
    echo "   터미널에서 'winzip', 'fix-korean-jamo'를 어디서나 실행하려면"
    echo "   ~/.zshrc 파일 끝에 아래 한 줄을 추가해 주세요:"
    echo '   export PATH="$HOME/.local/bin:$PATH"'
fi

echo ""
echo "============================================================"
echo "  🎉 모든 설치가 완료되었습니다!"
echo "============================================================"
echo " 1. [실시간 자동]: 바탕화면/다운로드/문서에 생기는 파일은 자동으로 NFC 변환됩니다."
echo " 2. [우클릭 메뉴]: Finder에서 우클릭 ➔ 빠른 동작에서 아래 기능 사용 가능:"
echo "    - '한글 자모 결합 (NFC 변환)'"
echo "    - '윈도우 호환 압축 (ZIP)'"
echo " 3. [터미널 명령]: winzip, fix-korean-jamo"
echo " 4. [로그 확인]: tail -f ~/.local/state/finder-tools/nfc_watcher.log"
echo "============================================================"
