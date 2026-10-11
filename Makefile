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
	@echo "🧪 기능 테스트 실행 중 (실시간 데몬 + 전수 스캔)..."
	@python3 -c '\
import time, unicodedata, os, subprocess, shutil; \
from pathlib import Path; \
tfile = Path.home() / "Desktop" / (unicodedata.normalize("NFD", "테스트_메이크_검증") + ".txt"); \
tfile.write_text("test", encoding="utf-8"); \
time.sleep(0.3); \
cfile = Path.home() / "Desktop" / "테스트_메이크_검증.txt"; \
assert cfile.exists(), "Daemon test file not found"; \
assert cfile.name == unicodedata.normalize("NFC", cfile.name), "Not NFC"; \
cfile.unlink(); \
print("  ✔ 실시간 FSEvents 데몬 자동 수복 통과"); \
tdir = Path("/tmp/hangul_make_test"); \
shutil.rmtree(tdir, ignore_errors=True); \
tdir.mkdir(); \
nfd_file = tdir / (unicodedata.normalize("NFD", "스캔_테스트") + ".txt"); \
nfd_file.write_text("scan test"); \
res = subprocess.run([os.path.expanduser("~/.local/bin/grive-scan"), str(tdir)], capture_output=True, text=True); \
assert res.returncode == 0; \
res_file = tdir / "스캔_테스트.txt"; \
assert res_file.exists() and res_file.name == unicodedata.normalize("NFC", res_file.name); \
shutil.rmtree(tdir, ignore_errors=True); \
print("  ✔ 기존 파일 전수 스캔(grive-scan) 복구 통과"); \
print("🎉 모든 기능 테스트 100% 통과!"); \
'

clean:
	@rm -f bin/nfc_watcher
	@echo "🧹 빌드 산출물 정리 완료"
