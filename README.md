# macos-hangul-nfc-cleaner 🍏🇰🇷

> **macOS 한글 자모 분리(`ㅂㅗㄱㅗㅅㅓ`) 원천 방지 및 완성형(NFC) 자동 수복 올인원 솔루션**  
> Swift 6.4 네이티브 초경량 데몬(FSEvents) + Finder 우클릭 빠른 동작(Quick Action) + CLI 유틸리티

---

## 💡 왜 필요한가요?

macOS에서 한글 파일이나 폴더를 만들 때, 파일시스템(APFS)은 완성형(NFC)을 지원함에도 불구하고 **Finder의 텍스트 입력창과 기본 앱들이 수십 년 전 레거시 규칙(NFD, 자모 분리)으로 파일명을 기록**합니다.

이로 인해:
* 윈도우, 리눅스, 웹, NAS, 클라우드로 파일을 보내면 **`ㅂㅗㄱㅗㅅㅓ.docx`**처럼 자음과 모음이 낱글자로 깨집니다.
* 맥 기본 압축(ZIP)은 `.DS_Store`와 `__MACOSX` 찌꺼기를 포함하고 NFD 파일명을 그대로 압축해 상대방에게 불쾌한 경험을 줍니다.
* APFS 파일시스템 특성상 단순 이름 변경으로는 디렉터리 카탈로그가 갱신되지 않아 수동 수정이 까다롭습니다.

`macos-hangul-nfc-cleaner`는 이 모든 문제를 **사용자가 전혀 신경 쓸 필요 없이 시스템 차원에서 자동으로 해결**합니다.

---

## ✨ 핵심 기능

### 1. 실시간 백그라운드 자동 정규화 (Swift 네이티브 데몬)
* **무소음 무개입 (Zero-Touch)**: 바탕화면(`~/Desktop`), 다운로드(`~/Downloads`), 문서(`~/Documents`)에 파일이 생기거나 이름이 바뀌는 순간을 **0.05초 만에 감지**하여 완성형(NFC)으로 즉시 자동 결합합니다.
* **초경량 저전력**: Python 인터프리터 없이 순수 **Swift 네이티브 arm64 바이너리**로 컴파일되어 **RAM 약 8.9MB, CPU 0.0%**로 상주합니다.
* **APFS 2단계 갱신**: macOS 디렉터리 캐시를 완벽히 우회하여 디스크 실제 파일명 레코드를 확실하게 완성형으로 교체합니다.
* **자동 실행**: `launchd` 서비스로 등록되어 맥을 켜거나 로그인할 때 자동으로 가동됩니다.

### 2. Finder 우클릭 [빠른 동작 (Quick Action)] 2종
Finder에서 파일이나 폴더를 선택하고 우클릭 메뉴에서 바로 사용합니다:
* **한글 자모 결합 (NFC 변환)**: 외장하드나 메신저로 받아 이미 자모가 분리되어 버린 다량의 파일/하위 폴더를 한 번에 정상 완성형으로 복원.
* **윈도우 호환 압축 (ZIP)**: Zip 헤더 파일명을 무조건 UTF-8 + NFC 완성형으로 강제하고, 맥 찌꺼기 파일(`.DS_Store`, `__MACOSX`, `._*`)을 100% 필터링하여 순수 zip 생성.

### 3. 터미널 CLI 명령어 지원
개발자나 파워유저를 위해 터미널 명령어 심볼릭 링크를 기본 제공합니다:
```bash
# 윈도우 호환 클린 압축
winzip ./프로젝트폴더

# 특정 폴더 하위 한글 자모 일괄 복구
fix-korean-jamo ./외장하드폴더
```

---

## 🚀 다른 맥에 설치하는 방법 (초간단)

### 방법 A. 패키지 다운로드 후 원클릭 설치
이 저장소(또는 폴더)를 내려받은 뒤 터미널에서 다음 명령어를 실행합니다:

```bash
cd macos-hangul-nfc-cleaner
./install.sh
```

또는 `make` 지원:
```bash
make install
```

> **설치 스크립트(`install.sh`)가 자동으로 처리하는 내용:**
> 1. Swift 컴파일러가 있으면 최신 최적화 바이너리 즉시 빌드 (없으면 동봉된 바이너리 사용)
> 2. `~/.local/bin/finder-tools/`에 도구 배치 및 `~/.local/bin/`에 심볼릭 링크 생성
> 3. Finder 우클릭 [빠른 동작] 메뉴 2종 자동 설치 및 서비스 캐시 갱신
> 4. `launchd` 백그라운드 데몬 등록 및 즉시 가동 (`com.coos.korean-nfc-normalizer`)

---

## ⚙️ 설정 커스터마이징

기본 감시 경로는 `바탕화면`, `다운로드`, `문서`입니다. 추가로 감시하고 싶은 폴더가 있다면 설정 파일에 추가할 수 있습니다:

* **설정 파일 위치**: `~/.config/finder-tools/watcher_config.json`
```json
{
  "watch_paths": [
    "/Users/username/Desktop",
    "/Users/username/Downloads",
    "/Users/username/Documents",
    "/Users/username/Projects"
  ]
}
```
* 변경 후 데몬 재시작:
```bash
launchctl unload ~/Library/LaunchAgents/com.coos.korean-nfc-normalizer.plist
launchctl load -w ~/Library/LaunchAgents/com.coos.korean-nfc-normalizer.plist
```

---

## 📊 상태 및 로그 확인

백그라운드 데몬이 정상 작동 중인지 확인하거나 변환 내역을 보려면:

```bash
# 데몬 프로세스 상주 여부 확인
launchctl list | grep korean-nfc

# 실시간 파일 변환 로그 스트리밍
tail -f ~/.local/state/finder-tools/nfc_watcher.log
```

---

## 🗑️ 완전 제거 (Uninstall)

설치된 모든 컴포넌트(데몬, 우클릭 메뉴, CLI 명령어, 바이너리)를 깔끔하게 지우고 싶다면:

```bash
cd macos-hangul-nfc-cleaner
./uninstall.sh
```
또는
```bash
make uninstall
```

---

## 📂 프로젝트 구조

```
macos-hangul-nfc-cleaner/
├── README.md                 # 프로젝트 문서
├── Makefile                  # make 빌드/설치 지원
├── install.sh                # 원클릭 멱등 설치 스크립트
├── uninstall.sh              # 완전 제거 스크립트
├── bin/
│   └── nfc_watcher           # 컴파일된 Swift 네이티브 arm64 바이너리
├── src/
│   ├── nfc_watcher.swift     # Swift FSEvents 실시간 감시 데몬 소스
│   ├── winzip.py             # 윈도우 호환 클린 ZIP 압축 CLI
│   └── fix_korean_jamo.py    # APFS 2단계 한글 자모 복구 CLI
├── services/
│   ├── 윈도우 호환 압축 (ZIP).workflow
│   └── 한글 자모 결합 (NFC 변환).workflow
└── launchd/
    └── com.coos.korean-nfc-normalizer.plist.template
```

---

## 🛡️ 라이선스
MIT License. 자유롭게 복제, 수정 및 배포가 가능합니다.
