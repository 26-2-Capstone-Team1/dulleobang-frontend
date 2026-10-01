"""데모 사진 생성: 매물 12개 × 3장(L01_1.jpg …), 욕실 3장(bath_1.jpg …), 가구 썸네일 4장(F_bed.jpg …).
사용법:  python3 tools/mockgen/make_images.py  [출력 폴더, 기본 Dulleobang/Resources/Mock]
필요: pip install pillow numpy
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rooms, furniture_thumbs

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "Dulleobang", "Resources", "Mock")
os.makedirs(out, exist_ok=True)
rooms.build_all(out)
furniture_thumbs.build(out)
print("ok", os.path.abspath(out))
