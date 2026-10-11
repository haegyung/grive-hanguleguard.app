#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Korean Hangul Jamo Combiner (NFD -> NFC Normalizer) for macOS Finder
- Recursively normalizes filenames from NFD (decomposed) to NFC (composed)
- Fixes 'ㅂㅗㄱㅗㅅㅓ' into '보고서'
- Uses safe 2-step rename to overcome APFS normalization-preserving cache
- Shows native macOS notification on completion
"""

import sys
import os
import unicodedata
import subprocess
import uuid
from pathlib import Path

def notify(title: str, subtitle: str, message: str = ""):
    script = f'display notification "{message}" with title "{title}" subtitle "{subtitle}"'
    subprocess.run(["osascript", "-e", script], check=False)

def safe_nfc_rename(target_path: Path, nfc_name: str) -> bool:
    """Performs 2-step rename on APFS to guarantee directory catalog entry update."""
    parent = target_path.parent
    tmp_path = parent / f".__nfc_tmp_{uuid.uuid4().hex}"
    final_path = parent / nfc_name
    try:
        target_path.rename(tmp_path)
        tmp_path.rename(final_path)
        return True
    except Exception as e:
        # Rollback if needed
        if tmp_path.exists() and not target_path.exists():
            try:
                tmp_path.rename(target_path)
            except Exception:
                pass
        return False

def normalize_path(target_path: Path) -> int:
    """Recursively normalizes target_path to NFC. Returns count of renamed items."""
    renamed_count = 0

    if target_path.is_file() or target_path.is_symlink():
        name = target_path.name
        nfc_name = unicodedata.normalize('NFC', name)
        if name != nfc_name:
            if safe_nfc_rename(target_path, nfc_name):
                renamed_count += 1
        return renamed_count

    if target_path.is_dir():
        # Bottom-up traversal
        for root, dirs, files in os.walk(target_path, topdown=False):
            # Process files first
            for file in files:
                nfc_file = unicodedata.normalize('NFC', file)
                if file != nfc_file:
                    old_fpath = Path(root) / file
                    if safe_nfc_rename(old_fpath, nfc_file):
                        renamed_count += 1

            # Process directories bottom-up
            for d in dirs:
                nfc_d = unicodedata.normalize('NFC', d)
                if d != nfc_d:
                    old_dpath = Path(root) / d
                    if safe_nfc_rename(old_dpath, nfc_d):
                        renamed_count += 1

        # Finally, normalize the target folder itself if requested directly
        name = target_path.name
        nfc_name = unicodedata.normalize('NFC', name)
        if name != nfc_name:
            if safe_nfc_rename(target_path, nfc_name):
                renamed_count += 1

    return renamed_count

def main():
    raw_args = sys.argv[1:]
    if not raw_args:
        notify("자모 결합 실패", "선택된 파일이나 폴더가 없습니다.")
        sys.exit(1)

    items = [Path(p).resolve() for p in raw_args if Path(p).exists()]
    if not items:
        notify("자모 결합 실패", "유효한 파일이 없습니다.")
        sys.exit(1)

    total_renamed = 0
    for item in items:
        total_renamed += normalize_path(item)

    if total_renamed > 0:
        notify("한글 자모 결합 완료", f"총 {total_renamed}개 항목 결합됨", "NFD 자모 분리가 NFC 완성형으로 정상 변환되었습니다.")
    else:
        notify("한글 자모 확인", "변환할 항목 없음", "선택한 모든 파일과 폴더명이 이미 완성형(NFC)입니다.")

if __name__ == '__main__':
    main()
