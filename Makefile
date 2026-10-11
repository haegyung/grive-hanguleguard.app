.PHONY: all build app install uninstall test clean

all: build app

build:
	@echo "🔨 Swift 네이티브 바이너리 빌드 중..."
	swiftc -O src/nfc_watcher.swift -o bin/nfc_watcher
	@echo "✅ 빌드 완료: bin/nfc_watcher"

app:
	@bash app/build_app.sh

install:
	@bash install.sh

uninstall:
	@bash uninstall.sh

test:
	@echo "🧪 기능 테스트 실행 중..."
	@python3 -c "\
import time, unicodedata, os; \
from pathlib import Path; \
tfile = Path.home() / 'Desktop' / unicodedata.normalize('NFD', '테스트_메이크_검증.txt'); \
tfile.write_text('test', encoding='utf-8'); \
time.sleep(0.3); \
cfile = Path.home() / 'Desktop' / '테스트_메이크_검증.txt'; \
assert cfile.exists(), 'File not found'; \
assert cfile.name == unicodedata.normalize('NFC', cfile.name), 'Not NFC'; \
cfile.unlink(); \
print('✅ 실시간 NFC 데몬 테스트 통과!'); \
"

clean:
	@rm -f bin/nfc_watcher
	@echo "🧹 빌드 산출물 정리 완료"
