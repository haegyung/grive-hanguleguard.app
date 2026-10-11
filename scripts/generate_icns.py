#!/usr/bin/env python3
"""
Generate macOS AppIcon.icns from AI master image with transparent alpha background.
"""

import os
import sys
from pathlib import Path
from PIL import Image, ImageFilter

def make_transparent_and_iconset(input_jpg_path, output_dir):
    img = Image.open(input_jpg_path).convert("RGBA")
    width, height = img.size
    
    # 1. 흰색 배경 투명화 처리 (Threshold & Flood/Distance based alpha)
    # 이미지 모서리 픽셀들이 순수 흰색(255,255,255)에 가까우므로,
    # 흰색 배경과 외곽 그림자를 부드럽게 알파 블렌딩
    datas = img.getdata()
    newData = []
    
    for item in datas:
        r, g, b, a = item
        # 밝기(Luminance) 계산
        brightness = (r + g + b) / 3.0
        
        # 완전 흰색 배경 (>248) 투명 처리
        if brightness > 250 and abs(r - g) < 5 and abs(g - b) < 5:
            newData.append((r, g, b, 0))
        elif brightness > 235 and abs(r - g) < 8 and abs(g - b) < 8:
            # 외곽 부드러운 페더링
            alpha = int(255 * (250 - brightness) / 15.0)
            newData.append((r, g, b, max(0, min(255, alpha))))
        else:
            newData.append((r, g, b, 255))
            
    img.putdata(newData)
    
    # 마스터 1024x1024 PNG 저장
    master_png = Path(output_dir) / "AppIcon_1024.png"
    img.save(master_png, "PNG")
    print(f"✔ 투명 마스터 PNG 저장 완료: {master_png}")
    
    # 2. Apple iconset 디렉터리 생성
    iconset_dir = Path(output_dir) / "AppIcon.iconset"
    iconset_dir.mkdir(parents=True, exist_ok=True)
    
    icon_specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    
    for filename, size in icon_specs:
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(iconset_dir / filename, "PNG")
        
    print(f"✔ 10종 해상도 iconset 생성 완료: {iconset_dir}")
    
    # 3. macOS 네이티브 iconutil로 .icns 컴파일
    icns_path = Path(output_dir) / "AppIcon.icns"
    os.system(f"iconutil -c icns '{iconset_dir}' -o '{icns_path}'")
    
    if icns_path.exists():
        print(f"🎉 Apple 네이티브 AppIcon.icns 빌드 성공! ({icns_path.stat().st_size // 1024} KB)")
        return icns_path
    else:
        print("❌ iconutil 변환 실패")
        sys.exit(1)

if __name__ == "__main__":
    input_img = "/Users/g/.gemini/antigravity/brain/6bf95682-41d1-47ab-b21e-5d28cac5db31/grive_app_icon_isolated_1791695355022.jpg"
    dest_dir = "/Volumes/Extend/Projects/DevWorkspace/macos-hangul-nfc-cleaner/app/Resources"
    Path(dest_dir).mkdir(parents=True, exist_ok=True)
    make_transparent_and_iconset(input_img, dest_dir)
