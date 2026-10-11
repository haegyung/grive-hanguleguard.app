#!/bin/bash
set -e

# ==============================================================================
# macos-hangul-nfc-cleaner: Universal Native Installer
# - Installs Swift native multicall binary (daemon, fix, zip)
# - Zero runtime dependencies (NO Python required, 100% native macOS)
# - Installs Finder Quick Actions & LaunchAgent
# ==============================================================================

echo "============================================================"
echo "  🚀 macos-hangul-nfc-cleaner (Zero-Dependency) 설치 시작"
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
echo "📁 필수 디렉터리 준비 중..."
mkdir -p "$TARGET_BIN_DIR" "$TARGET_STATE_DIR" "$TARGET_CONFIG_DIR" "$LAUNCH_AGENTS_DIR" "$SERVICES_DIR" "$LOCAL_BIN"

# 3. Build or Install Swift Binary
echo "⚙️  Swift 올인원 네이티브 바이너리 준비 중..."
if command -v swiftc >/dev/null 2>&1; then
    echo "  -> swiftc 감지: 최신 소스코드에서 최적화(-O) 컴파일 중..."
    swiftc -O "$PROJECT_DIR/src/nfc_watcher.swift" -o "$TARGET_BIN_DIR/nfc_watcher"
    cp "$TARGET_BIN_DIR/nfc_watcher" "$PROJECT_DIR/bin/nfc_watcher"
else
    if [[ -f "$PROJECT_DIR/bin/nfc_watcher" ]]; then
        echo "  -> swiftc 미설치: 번들된 사전 컴파일 바이너리 설치..."
        cp "$PROJECT_DIR/bin/nfc_watcher" "$TARGET_BIN_DIR/nfc_watcher"
    else
        echo "❌ 오류: swiftc 컴파일러와 사전 빌드 바이너리가 모두 없습니다."
        exit 1
    fi
fi
chmod +x "$TARGET_BIN_DIR/nfc_watcher"

# 4. Multi-call Symlinks for Terminal
echo "🔗 터미널 CLI 심볼릭 링크 생성 중 (~/.local/bin)..."
ln -sf "$TARGET_BIN_DIR/nfc_watcher" "$LOCAL_BIN/winzip"
ln -sf "$TARGET_BIN_DIR/nfc_watcher" "$LOCAL_BIN/fix-korean-jamo"
ln -sf "$TARGET_BIN_DIR/nfc_watcher" "$LOCAL_BIN/nfc-watcher"

# 5. Install Finder Quick Actions
echo "🖱️  Finder 우클릭 빠른 동작(Quick Action) 설치 중..."
for wf in "$PROJECT_DIR"/services/*.workflow; do
    wf_name="$(basename "$wf")"
    target_wf="$SERVICES_DIR/$wf_name"
    
    rm -rf "$target_wf"
    cp -R "$wf" "$target_wf"
    
    # Replace {{HOME}} placeholder
    wflow_file="$target_wf/Contents/document.wflow"
    if [[ -f "$wflow_file" ]]; then
        sed -i '' "s|{{HOME}}|$HOME|g" "$wflow_file"
    fi
    echo "  -> '$wf_name' 설치 완료"
done

# Refresh Finder Services Cache
/System/Library/CoreServices/pbs -update 2>/dev/null || true

# 6. Install & Start launchd Agent
PLIST_LABEL="com.coos.korean-nfc-normalizer"
PLIST_TARGET="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

echo "🔄 시스템 상주 서비스(LaunchAgent) 등록 및 가동 중..."
launchctl unload "$PLIST_TARGET" 2>/dev/null || true

sed "s|{{HOME}}|$HOME|g" "$PROJECT_DIR/launchd/$PLIST_LABEL.plist.template" > "$PLIST_TARGET"
launchctl load -w "$PLIST_TARGET"

sleep 1
if launchctl list | grep -q "$PLIST_LABEL"; then
    echo "  ✅ 백그라운드 자동 정규화 데몬이 정상 가동되었습니다!"
else
    echo "  ⚠️ 서비스 로드 확인 필요: 'launchctl list | grep $PLIST_LABEL'"
fi

# 7. PATH check
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "💡 안내: ~/.local/bin 경로가 PATH에 포함되어 있지 않습니다."
    echo "   터미널에서 명령어를 편리하게 쓰시려면 ~/.zshrc 에 아래 한 줄을 추가하세요:"
    echo '   export PATH="$HOME/.local/bin:$PATH"'
fi

echo ""
echo "============================================================"
echo "  🎉 엔터프라이즈급 Swift 네이티브 올인원 설치 완료!"
echo "============================================================"
echo " 1. [파이썬 의존성 0%]: 순수 macOS 네이티브로 완전히 독립 구동됩니다."
echo " 2. [실시간 자동]: 바탕화면/다운로드/문서 파일 자동 NFC 정규화 & 충돌 복구 저널링."
echo " 3. [우클릭 메뉴]: Finder 우클릭 ➔ 빠른 동작에서 사용 가능:"
echo "    - '한글 자모 결합 (NFC 변환)'"
echo "    - '윈도우 호환 압축 (ZIP)' (.DS_Store 소거 + UTF-8 헤더 패치)"
echo " 4. [터미널 명령]: winzip, fix-korean-jamo, nfc-watcher"
echo "============================================================"
