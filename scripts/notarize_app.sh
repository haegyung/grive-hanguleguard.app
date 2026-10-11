#!/bin/bash
set -e

# ==============================================================================
# GriveHangulGuard macOS Official Notarization & DMG Builder
# - Code Signing with Developer ID Application + Hardened Runtime + Timestamp
# - Apple Notary Service Submission & Waiting (xcrun notarytool)
# - Ticket Stapling (xcrun stapler)
# - Universal Gatekeeper Verification (spctl)
# - Clean Drag-and-Drop Notarized DMG Packaging
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SIGNING_IDENTITY="ACD36185D15F5900A601FFDF7D9D65AD081B5F88" # Developer ID Application: gyungman go (XYCW3PC8W6)
KEYCHAIN_PROFILE="co-os-notary"
APP_BUNDLE="$PROJECT_DIR/GriveHangulGuard.app"
BIN_FILE="$PROJECT_DIR/bin/nfc_watcher"
DIST_DIR="$PROJECT_DIR/dist"
DMG_OUTPUT="$DIST_DIR/GriveHangulGuard.dmg"
ZIP_FOR_NOTARY="/tmp/GriveHangulGuard-notarize.zip"
DMG_TEMP_DIR="/tmp/grive_dmg_staging"

# ANSI Colors
BOLD="\033[1m"
GREEN="\033[32m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${CYAN}  🍏 Grive한글가드 공식 배포용 Apple 코드 서명 및 공증(Notarization) 파이프라인${RESET}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════${RESET}"

mkdir -p "$DIST_DIR"

# ------------------------------------------------------------------------------
# 1. Swift 바이너리 및 앱 번들 최신 빌드
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[1/7] 🔨 Swift 네이티브 바이너리 및 앱 번들 컴파일...${RESET}"
swiftc -O "$PROJECT_DIR/src/nfc_watcher.swift" -o "$BIN_FILE"
bash "$PROJECT_DIR/app/build_app.sh"

# ------------------------------------------------------------------------------
# 2. Developer ID 서명 (Hardened Runtime + Secure Timestamp)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2/7] 🔏 Apple Developer ID 공식 코드 서명 적용 중...${RESET}"
echo -e "  인증서: ${CYAN}$SIGNING_IDENTITY${RESET}"

# Sign standalone CLI binary
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$BIN_FILE"
echo -e "  ${GREEN}✔${RESET} CLI 바이너리 서명 완료 ($BIN_FILE)"

# Sign internal executable inside .app
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$APP_BUNDLE/Contents/MacOS/GriveHangulGuard"

# Sign whole .app bundle
codesign --force --deep --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
echo -e "  ${GREEN}✔${RESET} GriveHangulGuard.app 번들 전체 서명 완료 (Hardened Runtime 활성화)"

# ------------------------------------------------------------------------------
# 3. 공증 제출용 아카이브 생성
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3/7] 📦 Apple 공증 서버 제출용 아카이브 패키징...${RESET}"
rm -f "$ZIP_FOR_NOTARY"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_FOR_NOTARY"
echo -e "  ${GREEN}✔${RESET} 아카이브 준비 완료: $ZIP_FOR_NOTARY"

# ------------------------------------------------------------------------------
# 4. Apple Notary Service 제출 및 승인 대기
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4/7] 🚀 Apple 공증 서버(notarytool) 제출 및 검증 대기 중...${RESET}"
echo -e "  키체인 프로필: ${CYAN}$KEYCHAIN_PROFILE${RESET}"

xcrun notarytool submit "$ZIP_FOR_NOTARY" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo -e "  ${GREEN}✔${RESET} Apple 공증 서버 승인(Accepted) 완료!"

# ------------------------------------------------------------------------------
# 5. 티켓 스테이플링 (Stapling) 및 로컬 Gatekeeper 검증
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[5/7] 🏷️  공증 티켓 부착(Staple) 및 Gatekeeper 최종 검증...${RESET}"
xcrun stapler staple "$APP_BUNDLE"
echo -e "  ${GREEN}✔${RESET} GriveHangulGuard.app에 Apple 공식 공증 티켓 부착 완료"

# Gatekeeper strict assessment
echo -e "  -> Gatekeeper 실측 검증 중 (spctl)..."
SPCTL_OUTPUT=$(spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1)
echo -e "     ${CYAN}$SPCTL_OUTPUT${RESET}"

if [[ "$SPCTL_OUTPUT" == *"accepted"* ]]; then
    echo -e "  ${GREEN}${BOLD}🎉 Gatekeeper 공인 검증 100% 통과!${RESET} (출처: Notarized Developer ID)"
else
    echo -e "  ${RED}❌ Gatekeeper 검증 실패: $SPCTL_OUTPUT${RESET}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. 배포용 Drag-and-Drop Notarized DMG 제작
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[6/7] 💿 배포용 설치 디스크 이미지(DMG) 패키징...${RESET}"
rm -rf "$DMG_TEMP_DIR" "$DMG_OUTPUT"
mkdir -p "$DMG_TEMP_DIR"

# Copy notarized app to staging
cp -R "$APP_BUNDLE" "$DMG_TEMP_DIR/"
ln -s /Applications "$DMG_TEMP_DIR/Applications"

# Create UDZO compressed DMG
hdiutil create -volname "Grive한글가드" \
    -srcfolder "$DMG_TEMP_DIR" \
    -ov -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_TEMP_DIR"
echo -e "  ${GREEN}✔${RESET} DMG 패키지 생성 완료: $DMG_OUTPUT"

# Sign and Notarize DMG itself
echo -e "  -> DMG 이미지 자체 코드 서명..."
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_OUTPUT"

echo -e "  -> DMG 이미지 Apple 공증 제출..."
xcrun notarytool submit "$DMG_OUTPUT" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

xcrun stapler staple "$DMG_OUTPUT"
echo -e "  ${GREEN}✔${RESET} DMG 파일에도 Apple 공증 티켓 부착 완료"

# ------------------------------------------------------------------------------
# 7. 최종 배포용 ZIP 생성 및 보고서
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[7/7] 📋 최종 배포 아티팩트 정리...${RESET}"
ZIP_OUTPUT="$DIST_DIR/GriveHangulGuard-v1.0.3-notarized.zip"
rm -f "$ZIP_OUTPUT"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_OUTPUT"

DMG_SIZE=$(ls -lh "$DMG_OUTPUT" | awk '{print $5}')
ZIP_SIZE=$(ls -lh "$ZIP_OUTPUT" | awk '{print $5}')

echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}        ✨ 모든 Apple 공식 코드 서명 및 공증(Notarization)이 완료되었습니다!        ${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════════════════${RESET}"
echo -e " 1. ${BOLD}공증된 DMG 설치 파일:${RESET} $DMG_OUTPUT ($DMG_SIZE)"
echo -e " 2. ${BOLD}공증된 ZIP 아카이브:${RESET} $ZIP_OUTPUT ($ZIP_SIZE)"
echo -e " 3. ${BOLD}서명 개발자 ID:${RESET} $SIGNING_IDENTITY"
echo -e " 4. ${BOLD}Gatekeeper 판정:${RESET} Notarized Developer ID (경고창 0회, 즉시 실행)"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════════════════${RESET}\n"
