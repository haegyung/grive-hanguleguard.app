#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Windows-Compatible Zip Compressor for macOS Finder
- Enforces Unicode NFC (Hangul syllable composition) in Zip file headers
- Excludes macOS junk files (.DS_Store, __MACOSX, ._* resource forks)
- Shows native macOS notification on completion
"""

import sys
import os
import zipfile
import unicodedata
import subprocess
from pathlib import Path
import datetime

EXCLUDE_NAMES = {'.DS_Store', '__MACOSX', 'Thumbs.db', 'desktop.ini'}

def is_excluded(name: str) -> bool:
    if name in EXCLUDE_NAMES:
        return True
    if name.startswith('._'):
        return True
    return False

def get_unique_zip_path(base_path: Path) -> Path:
    if not base_path.exists():
        return base_path
    stem = base_path.stem
    parent = base_path.parent
    counter = 1
    while True:
        candidate = parent / f"{stem} ({counter}).zip"
        if not candidate.exists():
            return candidate
        counter += 1

def notify(title: str, subtitle: str, message: str = ""):
    script = f'display notification "{message}" with title "{title}" subtitle "{subtitle}"'
    subprocess.run(["osascript", "-e", script], check=False)

def get_zip_datetime(mtime: float = None):
    if mtime:
        dt = datetime.datetime.fromtimestamp(mtime)
    else:
        dt = datetime.datetime.now()
    return (dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)

def main():
    raw_args = sys.argv[1:]
    if not raw_args:
        notify("압축 실패", "선택된 파일이나 폴더가 없습니다.")
        sys.exit(1)

    items = [Path(p).resolve() for p in raw_args if Path(p).exists()]
    if not items:
        notify("압축 실패", "유효한 파일이 없습니다.")
        sys.exit(1)

    first_item = items[0]
    parent_dir = first_item.parent

    if len(items) == 1:
        zip_base_name = f"{first_item.name}.zip"
    else:
        zip_base_name = f"{parent_dir.name}_윈도우호환.zip"

    output_zip = get_unique_zip_path(parent_dir / zip_base_name)

    total_files = 0
    try:
        with zipfile.ZipFile(output_zip, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for item in items:
                if item.is_file():
                    if is_excluded(item.name):
                        continue
                    arcname = unicodedata.normalize('NFC', item.name)
                    st = item.stat()
                    zinfo = zipfile.ZipInfo(arcname, date_time=get_zip_datetime(st.st_mtime))
                    zinfo.flag_bits |= 0x800  # Force UTF-8 flag
                    zinfo.external_attr = (st.st_mode & 0xFFFF) << 16
                    with open(item, 'rb') as f:
                        zf.writestr(zinfo, f.read(), compress_type=zipfile.ZIP_DEFLATED)
                    total_files += 1
                elif item.is_dir():
                    base_root = item.parent
                    for root, dirs, files in os.walk(item):
                        dirs[:] = [d for d in dirs if not is_excluded(d)]
                        
                        rel_dir = Path(root).relative_to(base_root)
                        norm_rel_dir = unicodedata.normalize('NFC', str(rel_dir)).replace(os.sep, '/')
                        if norm_rel_dir and not norm_rel_dir.endswith('/'):
                            norm_rel_dir += '/'

                        if norm_rel_dir:
                            st = Path(root).stat()
                            dinfo = zipfile.ZipInfo(norm_rel_dir, date_time=get_zip_datetime(st.st_mtime))
                            dinfo.flag_bits |= 0x800
                            dinfo.external_attr = 0o755 << 16 | 0x10  # Directory bit
                            zf.writestr(dinfo, '')

                        for file in files:
                            if is_excluded(file):
                                continue
                            file_path = Path(root) / file
                            if file_path.is_symlink() and not file_path.exists():
                                continue
                            rel_file = file_path.relative_to(base_root)
                            norm_arcname = unicodedata.normalize('NFC', str(rel_file)).replace(os.sep, '/')
                            
                            st = file_path.stat()
                            zinfo = zipfile.ZipInfo(norm_arcname, date_time=get_zip_datetime(st.st_mtime))
                            zinfo.flag_bits |= 0x800
                            zinfo.external_attr = (st.st_mode & 0xFFFF) << 16
                            with open(file_path, 'rb') as f:
                                zf.writestr(zinfo, f.read(), compress_type=zipfile.ZIP_DEFLATED)
                            total_files += 1

        notify("윈도우 호환 압축 완료", output_zip.name, f"총 {total_files}개 파일이 정상 압축되었습니다.")
    except Exception as e:
        if output_zip.exists():
            output_zip.unlink(missing_ok=True)
        notify("압축 오류", str(e))
        sys.exit(1)

if __name__ == '__main__':
    main()
