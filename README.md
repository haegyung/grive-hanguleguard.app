# Grive한글가드 (GriveHangulGuard) 🍏🇰🇷

> **macOS 한글 자모 분리(`ㅂㅗㄱㅗㅅㅓ`) 원천 방지 및 완성형(NFC) 자동 수복 올인원 솔루션**  
> Swift 6.4 네이티브 초경량 데몬(FSEvents) + 네이티브 관리 앱(`GriveHangulGuard.app`) + Finder 우클릭 빠른 동작 + CLI 도구

---

## 💡 왜 필요한가요?

macOS에서 한글 파일이나 폴더를 만들 때, 파일시스템(APFS)은 완성형(NFC)을 지원함에도 불구하고 **Finder의 텍스트 입력창과 기본 앱들이 수십 년 전 레거시 규칙(NFD, 자모 분리)으로 파일명을 기록**합니다.

이로 인해:
* 윈도우, 리눅스, 웹, NAS, 클라우드로 파일을 보내면 **`ㅂㅗㄱㅗㅅㅓ.docx`**처럼 자음과 모음이 낱글자로 깨집니다.
* 맥 기본 압축(ZIP)은 `.DS_Store`와 `__MACOSX` 찌꺼기를 포함하고 NFD 파일명을 그대로 압축해 상대방에게 불쾌한 경험을 줍니다.
* APFS 파일시스템 특성상 단순 이름 변경으로는 디렉터리 카탈로그가 갱신되지 않아 수동 수정이 까다롭습니다.

`macos-hangul-nfc-cleaner`는 이 모든 문제를 **사용자가 전혀 신경 쓸 필요 없이 시스템 차원에서 자동으로 해결**합니다.

---

## 🖥️ 네이티브 GUI 앱 지원 (GriveHangulGuard.app)

터미널이나 명령어가 익숙하지 않은 사용자를 위해 **독립형 macOS GUI 관리 앱 (`GriveHangulGuard.app`)**을 함께 제공합니다.

* **원클릭 설치 및 가동**: 버튼 클릭 한 번으로 모든 컴포넌트 설치 및 데몬 시작
* **권한 점검 및 바로가기**: 로그인 항목, 전체 디스크 접근 권한(TCC), Finder 확장 권한을 앱에서 원클릭으로 열고 확인
* **실시간 상태 & 로그 뷰어**: 데몬 실행 상태(PID)와 실시간 파일 변환 로그를 한눈에 모니터링
* **자가 진단 테스트**: 버튼 클릭으로 실시간 NFD ➔ NFC 변환이 정상 작동하는지 즉시 검증

```bash
# 앱 실행 (또는 Finder에서 GriveHangulGuard.app 더블클릭)
open GriveHangulGuard.app
```

---

## ✨ 핵심 기능

### 1. 100% 순수 macOS 네이티브 (Zero-Dependency)
* **Python 의존성 0%**: 개발자 도구(Xcode CLT)나 파이썬이 없는 순정 맥에서도 단 115KB짜리 **Swift 네이티브 단일 바이너리(`nfc_watcher`)** 하나로 모든 기능(데몬 + 우클릭 도구 + 터미널 CLI)이 동작합니다.
* **BusyBox 멀티콜 패턴**: 바이너리 심볼릭 링크 이름(`winzip`, `fix-korean-jamo`, `nfc-watcher`)에 따라 스스로 서브커맨드로 자동 라우팅됩니다.

### 2. POSIX 시스템 콜 직결 & APFS 저널링 크래시 복구
* **Apple Cocoa URL 강제 NFD 버그 우회**: Cocoa `URL` 레이어의 자동 NFD 분해를 원천 차단하기 위해 **POSIX C 표준 `rename()` 시스템 콜**을 직접 호출하여 APFS 디스크에 100% 순수 UTF-8 완성형(NFC) 바이트를 기록합니다.
* **의도 보존형 임시 파일 저널링 (`.__nfc_tmp_<UUID>_<TargetName>`)**: 2단계 Rename 도중 불시에 배터리가 방전되거나 전원이 꺼져도, 다음 부팅/스윕 시 고아 임시 파일을 감지하여 원래 이름으로 100% 자동 복구합니다.
* **I/O 안정화 검증 (File Quiescence)**: 대용량 파일 복사나 앱 쓰기 스트리밍 중에는 파일 디스크립터 상태를 점검하여 안전하게 쓰기가 닫힌 시점에 정규화를 수행합니다.

### 3. 실시간 백그라운드 자동 정규화 (FSEvents 데몬)
* **무소음 무개입 (Zero-Touch)**: 바탕화면(`~/Desktop`), 다운로드(`~/Downloads`), 문서(`~/Documents`)에 파일이 생기거나 이름이 바뀌는 순간을 **0.05초 만에 감지**하여 완성형(NFC)으로 즉시 자동 결합합니다.
* **초경량 저전력**: **RAM 약 9~10MB, CPU 0.0%**로 영구 상주합니다.
* **버퍼 오버플로우 자동 치유**: 수만 개 파일을 일괄 이동하여 FSEvents 버퍼가 가득 차면(`kFSEventStreamEventFlagMustScanSubDirs`), 해당 디렉터리를 자동으로 재귀 스윕합니다.

### 4. 윈도우 호환 클린 ZIP 압축 (0x0800 UTF-8 헤더 패처)
* macOS 기본 `ditto`와 `--norsrc`로 `.DS_Store`와 `__MACOSX` 찌꺼기를 원천 차단합니다.
* 자체 **Zip 바이너리 패처**가 ZIP Local/Central Directory 헤더에 `0x0800` (Language Encoding Flag) 비트를 강제 각인하여, 윈도우 탐색기 및 모든 서드파티 압축기에서 한글이 외계어로 깨지는 현상을 100% 방지합니다.

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
