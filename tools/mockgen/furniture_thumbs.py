"""가구 썸네일 (제품 사진 느낌): 물체를 가운데 두고 오른쪽 위에서 비스듬히 본다."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rooms
from rooms import Scene
from PIL import Image, ImageDraw
import numpy as np

SIZE = 480

def corners(x0, x1, y0, y1, z0, z1):
    return [(x, y, z) for x in (x0, x1) for y in (y0, y1) for z in (z0, z1)]

def thumb(kind, out):
    rooms.OW, rooms.OH = SIZE, SIZE
    rooms.W, rooms.H = SIZE * rooms.SS, SIZE * rooms.SS
    W, H = rooms.W, rooms.H
    dims = {"bed": (1.1, 0.95, 2.0), "desk": (1.2, 1.25, 0.6), "closet": (0.9, 1.8, 0.5), "sofa": (1.5, 0.85, 0.8)}[kind]
    w, h, d = dims
    cam = (w * 0.9 + 0.9, h + 1.0, -max(d, 1.2) * 1.6 - 0.8)
    s = Scene(4.0, 2.6, 4.0, cam, focal=500)
    # 화면에 꽉 차게: 모서리 8개를 정규화 투영해서 f, u0, v0 를 맞춘다
    pts = corners(-w / 2, w / 2, 0, h, 0, d)
    us = [(x - cam[0]) / max(z - cam[2], 0.05) for x, y, z in pts]
    vs = [(y - cam[1]) / max(z - cam[2], 0.05) for x, y, z in pts]
    f = 0.72 * W / max(max(us) - min(us), max(vs) - min(vs))
    s.f = f
    s.u0 = W / 2 - f * (max(us) + min(us)) / 2
    s.v0 = H / 2 + f * (max(vs) + min(vs)) / 2
    # 배경: 밝은 회색 그라데이션 + 바닥
    g = np.linspace(0, 1, H)[:, None]
    top, bot = np.array([248, 248, 250]), np.array([232, 231, 236])
    bg = (top * (1 - g) + bot * g).astype(np.uint8)
    s.img = Image.fromarray(np.repeat(bg[:, None, :], W, axis=1).reshape(H, W, 3))
    s.d = ImageDraw.Draw(s.img, "RGBA")
    x0 = -w / 2
    if kind == "bed":
        s.bed(x0, 0, w=w, d=d, blanket=(120, 150, 190))
    elif kind == "desk":
        s.desk(x0, 0, w=w, d=d)
    elif kind == "closet":
        s.wardrobe(x0, 0, w=w, d=d, h=h, color=(236, 232, 224))
    elif kind == "sofa":
        s.sofa(x0, 0, w=w, d=d, color=(150, 160, 170))
    img = s.img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(out, quality=86, optimize=True)

def build(out):
    for k in ["bed", "desk", "closet", "sofa"]:
        thumb(k, os.path.join(out, f"F_{k}.jpg"))


if __name__ == "__main__":
    build(sys.argv[1])
    print("ok")
