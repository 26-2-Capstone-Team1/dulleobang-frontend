"""둘러방 데모용 방 일러스트 생성기 (간단한 원근 투영 렌더러)."""
import math, random
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

SS = 2                      # 슈퍼샘플링 배율
OW, OH = 960, 720           # 출력 크기
W, H = OW * SS, OH * SS

def clamp(v, a=0, b=255): return max(a, min(b, int(round(v))))
def shade(c, k): return tuple(clamp(x * k) for x in c)
def mix(a, b, t): return tuple(clamp(a[i] * (1 - t) + b[i] * t) for i in range(3))

class Scene:
    def __init__(self, rw, rh, rd, cam, focal):
        self.rw, self.rh, self.rd = rw, rh, rd
        self.cx, self.cy, self.cz = cam
        self.f = focal * SS
        self.u0, self.v0 = W / 2, H / 2 + 20 * SS
        self.img = Image.new("RGB", (W, H), (240, 240, 240))
        self.d = ImageDraw.Draw(self.img, "RGBA")

    def P(self, x, y, z):
        dz = max(z - self.cz, 0.05)
        return (self.u0 + (x - self.cx) * self.f / dz, self.v0 - (y - self.cy) * self.f / dz)

    def poly(self, pts3, fill, outline=None, width=1):
        pts = [self.P(*p) for p in pts3]
        self.d.polygon(pts, fill=fill, outline=outline, width=width * SS if outline else 0)

    def line3(self, a, b, fill, width=1):
        self.d.line([self.P(*a), self.P(*b)], fill=fill, width=max(1, int(width * SS)))

    # ---- room shell
    def shell(self, wall, floor, ceiling, plank=True, floor_kind="wood"):
        rw, rh, rd = self.rw / 2, self.rh, self.rd
        n = -2.0   # 카메라 뒤까지 연장
        # 천장, 벽, 바닥
        self.poly([(-rw, rh, n), (rw, rh, n), (rw, rh, rd), (-rw, rh, rd)], ceiling)
        self.poly([(-rw, 0, n), (-rw, rh, n), (-rw, rh, rd), (-rw, 0, rd)], shade(wall, 0.9))
        self.poly([(rw, 0, n), (rw, rh, n), (rw, rh, rd), (rw, 0, rd)], shade(wall, 0.84))
        self.poly([(-rw, 0, rd), (rw, 0, rd), (rw, rh, rd), (-rw, rh, rd)], wall)
        self.poly([(-rw, 0, n), (rw, 0, n), (rw, 0, rd), (-rw, 0, rd)], floor)
        if floor_kind == "wood" and plank:
            k = 0.16
            x = -rw
            i = 0
            while x < rw:
                c = shade(floor, 0.95 if i % 2 else 1.03)
                self.poly([(x, 0.001, n), (min(x + k, rw), 0.001, n), (min(x + k, rw), 0.001, rd), (x, 0.001, rd)], c)
                self.line3((x, 0.002, n), (x, 0.002, rd), shade(floor, 0.8) + (120,), 1)
                # 판자 끝 이음새
                zz = (i * 0.37) % 1.2
                while zz < rd:
                    self.line3((x, 0.002, zz), (min(x + k, rw), 0.002, zz), shade(floor, 0.82) + (90,), 1)
                    zz += 1.2
                x += k
                i += 1
        elif floor_kind == "tile":
            k = 0.6
            x = -rw
            while x <= rw + 1e-6:
                self.line3((x, 0.002, n), (x, 0.002, rd), shade(floor, 0.85), 1)
                x += k
            z = 0.0
            while z <= rd:
                self.line3((-rw, 0.002, z), (rw, 0.002, z), shade(floor, 0.85), 1)
                z += k
        # 걸레받이
        for (a, b) in [((-rw, 0, n), (-rw, 0, rd)), ((rw, 0, n), (rw, 0, rd)), ((-rw, 0, rd), (rw, 0, rd))]:
            pass
        self.poly([(-rw, 0, rd - 0.001), (rw, 0, rd - 0.001), (rw, 0.07, rd - 0.001), (-rw, 0.07, rd - 0.001)], shade(wall, 0.93))
        self.poly([(-rw + 0.001, 0, n), (-rw + 0.001, 0.07, n), (-rw + 0.001, 0.07, rd), (-rw + 0.001, 0, rd)], shade(wall, 0.83))
        self.poly([(rw - 0.001, 0, n), (rw - 0.001, 0.07, n), (rw - 0.001, 0.07, rd), (rw - 0.001, 0, rd)], shade(wall, 0.78))
        # 모서리 선
        edge = shade(wall, 0.75) + (140,)
        for a, b in [((-rw, 0, rd), (-rw, rh, rd)), ((rw, 0, rd), (rw, rh, rd)), ((-rw, rh, rd), (rw, rh, rd)), ((-rw, 0, rd), (rw, 0, rd))]:
            self.line3(a, b, edge, 1.2)

    # ---- windows
    def window_back(self, x0, x1, y0, y1, sky=((170, 205, 235), (230, 240, 248)), curtain=None):
        z = self.rd - 0.002
        self.sky_quad([(x0, y1, z), (x1, y1, z), (x1, y0, z), (x0, y0, z)], sky)
        frame = (250, 250, 250)
        t = 0.05
        for q in [[(x0 - t, y0 - t, z), (x1 + t, y0 - t, z), (x1 + t, y0, z), (x0 - t, y0, z)],
                  [(x0 - t, y1, z), (x1 + t, y1, z), (x1 + t, y1 + t, z), (x0 - t, y1 + t, z)],
                  [(x0 - t, y0, z), (x0, y0, z), (x0, y1, z), (x0 - t, y1, z)],
                  [(x1, y0, z), (x1 + t, y0, z), (x1 + t, y1, z), (x1, y1, z)],
                  [((x0 + x1) / 2 - t / 2, y0, z), ((x0 + x1) / 2 + t / 2, y0, z), ((x0 + x1) / 2 + t / 2, y1, z), ((x0 + x1) / 2 - t / 2, y1, z)]]:
            self.poly(q, frame)
        # 창틀 선반
        self.box(x0 - 0.1, x1 + 0.1, y0 - 0.06, y0 - 0.02, z - 0.12, z, (245, 245, 245))
        if curtain:
            for cx0, cx1 in [(x0 - 0.35, x0 + 0.05), (x1 - 0.05, x1 + 0.35)]:
                self.poly([(cx0, y1 + 0.2, z - 0.05), (cx1, y1 + 0.2, z - 0.05), (cx1, 0.25, z - 0.05), (cx0, 0.25, z - 0.05)], curtain)
                n = 5
                for i in range(1, n):
                    xx = cx0 + (cx1 - cx0) * i / n
                    self.line3((xx, y1 + 0.2, z - 0.051), (xx, 0.25, z - 0.051), shade(curtain, 0.85) + (160,), 1.2)
        # 바닥 빛
        self.poly([(x0, 0.003, self.rd - 0.05), (x1, 0.003, self.rd - 0.05), (x1 + 0.4, 0.003, self.rd - 1.7), (x0 - 0.2, 0.003, self.rd - 1.7)], (255, 250, 230, 45))

    def window_left(self, z0, z1, y0, y1, sky=((170, 205, 235), (230, 240, 248))):
        x = -self.rw / 2 + 0.002
        self.sky_quad([(x, y1, z0), (x, y1, z1), (x, y0, z1), (x, y0, z0)], sky)
        t = 0.05
        frame = (248, 248, 248)
        for q in [[(x, y0 - t, z0 - t), (x, y0 - t, z1 + t), (x, y0, z1 + t), (x, y0, z0 - t)],
                  [(x, y1, z0 - t), (x, y1, z1 + t), (x, y1 + t, z1 + t), (x, y1 + t, z0 - t)],
                  [(x, y0, z0 - t), (x, y0, z0), (x, y1, z0), (x, y1, z0 - t)],
                  [(x, y0, z1), (x, y0, z1 + t), (x, y1, z1 + t), (x, y1, z1)],
                  [(x, y0, (z0 + z1) / 2 - t / 2), (x, y0, (z0 + z1) / 2 + t / 2), (x, y1, (z0 + z1) / 2 + t / 2), (x, y1, (z0 + z1) / 2 - t / 2)]]:
            self.poly(q, frame)
        self.poly([(x, 0.003, z0), (x, 0.003, z1), (x + 1.4, 0.003, z1 + 0.3), (x + 1.4, 0.003, z0 + 0.3)], (255, 250, 230, 50))

    def sky_quad(self, pts3, sky):
        pts = [self.P(*p) for p in pts3]
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        x0, x1, y0, y1 = int(min(xs)), int(max(xs)) + 1, int(min(ys)), int(max(ys)) + 1
        if x1 <= x0 or y1 <= y0: return
        grad = Image.new("RGB", (x1 - x0, y1 - y0))
        top, bot = sky
        arr = np.zeros((y1 - y0, x1 - x0, 3), dtype=np.uint8)
        for i in range(3):
            arr[:, :, i] = np.linspace(top[i], bot[i], y1 - y0)[:, None]
        grad = Image.fromarray(arr)
        mask = Image.new("L", (W, H), 0)
        ImageDraw.Draw(mask).polygon(pts, fill=255)
        layer = Image.new("RGB", (W, H))
        layer.paste(grad, (x0, y0))
        self.img.paste(layer, (0, 0), mask)
        # 먼 건물 실루엣
        rnd = random.Random(int(x0 + y0))
        d2 = ImageDraw.Draw(self.img, "RGBA")
        base = y1
        xx = x0
        while xx < x1:
            bw = rnd.randint(40, 110) * SS // 2
            bh = rnd.randint(int((y1 - y0) * 0.15), int((y1 - y0) * 0.45))
            poly = [(xx, base), (min(xx + bw, x1), base), (min(xx + bw, x1), base - bh), (xx, base - bh)]
            m2 = Image.new("L", (W, H), 0)
            ImageDraw.Draw(m2).polygon(poly, fill=90)
            m3 = Image.fromarray(np.minimum(np.array(m2), np.array(mask)))
            self.img.paste((150, 165, 185), (0, 0), m3)
            xx += bw + rnd.randint(2, 10)
        self.d = ImageDraw.Draw(self.img, "RGBA")

    # ---- primitive: 축 정렬 상자
    def box(self, x0, x1, y0, y1, z0, z1, color, top=None, lines=None):
        faces = []
        c = color
        # 보이는 면만 (카메라 기준)
        if self.cy > y1: faces.append(([(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], top or shade(c, 1.08)))
        if self.cy < y0: faces.append(([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], shade(c, 0.7)))
        if self.cx < x0: faces.append(([(x0, y0, z0), (x0, y1, z0), (x0, y1, z1), (x0, y0, z1)], shade(c, 0.86)))
        if self.cx > x1: faces.append(([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], shade(c, 0.8)))
        faces.append(([(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)], c))   # 앞면 (z0 이 카메라 쪽)
        for pts, col in faces:
            self.poly(pts, col, outline=shade(c, 0.72) + (90,), width=1)
        if lines:
            for a, b in lines:
                self.line3(a, b, shade(c, 0.7), 1.2)

    def shadow(self, x0, x1, z0, z1, a=38):
        e = 0.06
        self.poly([(x0 - e, 0.004, z0 - e), (x1 + e, 0.004, z0 - e), (x1 + e, 0.004, z1 + e), (x0 - e, 0.004, z1 + e)], (0, 0, 0, a))

    # ---- furniture
    def bed(self, x0, z0, w=1.1, d=2.0, frame=(170, 125, 85), sheet=(245, 244, 240), blanket=(120, 150, 190), head_back=True):
        x1, z1 = x0 + w, z0 + d
        self.shadow(x0, x1, z0, z1)
        if head_back:
            self.box(x0 - 0.02, x1 + 0.02, 0, 0.95, z1 - 0.06, z1, shade(frame, 0.95))
        self.box(x0, x1, 0.05, 0.3, z0, z1 - 0.06, frame)
        self.box(x0 + 0.02, x1 - 0.02, 0.3, 0.5, z0 + 0.02, z1 - 0.08, sheet)
        self.box(x0 + 0.1, x0 + w / 2 - 0.05, 0.5, 0.62, z1 - 0.5, z1 - 0.12, (252, 252, 250))
        self.box(x0 + w / 2 + 0.05, x1 - 0.1, 0.5, 0.62, z1 - 0.5, z1 - 0.12, (252, 252, 250))
        self.box(x0 - 0.01, x1 + 0.01, 0.34, 0.54, z0 + 0.0, z0 + d * 0.62, blanket)

    def desk(self, x0, z0, w=1.2, d=0.6, color=(200, 170, 130), legs=(60, 60, 65)):
        x1, z1 = x0 + w, z0 + d
        self.shadow(x0, x1, z0, z1, 25)
        for lx in (x0 + 0.03, x1 - 0.07):
            for lz in (z0 + 0.03, z1 - 0.07):
                self.box(lx, lx + 0.04, 0, 0.71, lz, lz + 0.04, legs)
        self.box(x0, x1, 0.71, 0.75, z0, z1, color)
        # 모니터, 스탠드
        mx = x0 + w * 0.35
        self.box(mx, mx + 0.5, 0.95, 1.25, z1 - 0.2, z1 - 0.17, (35, 35, 40))
        self.box(mx + 0.22, mx + 0.28, 0.75, 0.95, z1 - 0.19, z1 - 0.16, (60, 60, 65))
        self.box(x0 + 0.08, x0 + 0.2, 0.75, 1.1, z1 - 0.2, z1 - 0.1, (240, 225, 180))

    def chair(self, x0, z0, color=(80, 80, 90)):
        self.shadow(x0, x0 + 0.45, z0, z0 + 0.45, 25)
        self.box(x0 + 0.2, x0 + 0.25, 0, 0.45, z0 + 0.2, z0 + 0.25, (50, 50, 55))
        self.box(x0, x0 + 0.45, 0.45, 0.52, z0, z0 + 0.45, color)
        self.box(x0 + 0.02, x0 + 0.43, 0.52, 0.95, z0 + 0.4, z0 + 0.45, color)

    def wardrobe(self, x0, z0, w=0.9, d=0.6, h=1.95, color=(235, 232, 225)):
        x1, z1 = x0 + w, z0 + d
        self.shadow(x0, x1, z0, z1, 25)
        mid = (x0 + x1) / 2
        self.box(x0, x1, 0, h, z0, z1, color, lines=[((mid, 0.05, z0 - 0.001), (mid, h - 0.05, z0 - 0.001))])
        for hx in (mid - 0.06, mid + 0.04):
            self.box(hx, hx + 0.02, 0.9, 1.1, z0 - 0.02, z0, (160, 160, 165))

    def wardrobe_side(self, x_wall_left, z0, d=0.6, depth_len=1.0, h=1.95, color=(235, 232, 225), left=True):
        # 옆벽에 붙은 붙박이장
        if left:
            x0, x1 = x_wall_left, x_wall_left + d
        else:
            x0, x1 = x_wall_left - d, x_wall_left
        self.box(x0, x1, 0, h, z0, z0 + depth_len, color,
                 lines=[((x1 + 0.001 if left else x0 - 0.001, 0.05, z0 + depth_len / 2), (x1 + 0.001 if left else x0 - 0.001, h - 0.05, z0 + depth_len / 2))])

    def sofa(self, x0, z0, w=1.7, d=0.85, color=(150, 160, 170)):
        x1, z1 = x0 + w, z0 + d
        self.shadow(x0, x1, z0, z1)
        self.box(x0, x1, 0.08, 0.42, z0, z1, color)
        self.box(x0, x1, 0.42, 0.85, z1 - 0.22, z1, shade(color, 0.96))
        self.box(x0 - 0.02, x0 + 0.18, 0.08, 0.62, z0, z1, shade(color, 0.93))
        self.box(x1 - 0.18, x1 + 0.02, 0.08, 0.62, z0, z1, shade(color, 0.93))
        self.box(x0 + 0.25, x0 + 0.65, 0.42, 0.72, z1 - 0.3, z1 - 0.2, (235, 205, 150))

    def fridge(self, x0, z0, color=(225, 228, 230)):
        self.shadow(x0, x0 + 0.6, z0, z0 + 0.62, 25)
        self.box(x0, x0 + 0.6, 0, 1.55, z0, z0 + 0.62, color, lines=[((x0, 1.0, z0 - 0.001), (x0 + 0.6, 1.0, z0 - 0.001))])
        self.box(x0 + 0.5, x0 + 0.52, 1.1, 1.4, z0 - 0.02, z0, (170, 170, 175))

    def washer(self, x0, z0, color=(238, 240, 242)):
        self.box(x0, x0 + 0.6, 0, 0.85, z0, z0 + 0.6, color)
        c = self.P(x0 + 0.3, 0.42, z0 - 0.001)
        r = 0.18 * self.f / max(z0 - self.cz, 0.05)
        self.d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], fill=(90, 110, 130), outline=(200, 200, 205), width=3 * SS)

    def rug(self, x0, x1, z0, z1, color=(210, 190, 170)):
        self.poly([(x0, 0.006, z0), (x1, 0.006, z0), (x1, 0.006, z1), (x0, 0.006, z1)], color)
        m = 0.08
        self.poly([(x0 + m, 0.007, z0 + m), (x1 - m, 0.007, z0 + m), (x1 - m, 0.007, z1 - m), (x0 + m, 0.007, z1 - m)], shade(color, 1.06))

    def plant(self, x, z, h=1.1):
        self.box(x - 0.15, x + 0.15, 0, 0.32, z - 0.15, z + 0.15, (225, 220, 210))
        rnd = random.Random(int(x * 100 + z * 10))
        for i in range(9):
            px = x + rnd.uniform(-0.25, 0.25); py = 0.45 + rnd.uniform(0.1, h - 0.3)
            c = self.P(px, py, z)
            r = rnd.uniform(0.12, 0.2) * self.f / max(z - self.cz, 0.05)
            g = (rnd.randint(60, 95), rnd.randint(125, 160), rnd.randint(70, 100))
            self.d.ellipse([c[0] - r, c[1] - r * 0.8, c[0] + r, c[1] + r * 0.8], fill=g)

    def lamp(self, x, z):
        self.box(x - 0.13, x + 0.13, 0, 0.03, z - 0.13, z + 0.13, (60, 60, 60))
        self.box(x - 0.015, x + 0.015, 0.03, 1.35, z - 0.015, z + 0.015, (60, 60, 60))
        a = self.P(x - 0.22, 1.3, z); b = self.P(x + 0.22, 1.3, z); c = self.P(x + 0.14, 1.6, z); d = self.P(x - 0.14, 1.6, z)
        self.d.polygon([a, b, c, d], fill=(250, 238, 205))
        # 빛 번짐
        glow = Image.new("L", (W, H), 0)
        g = ImageDraw.Draw(glow)
        cc = self.P(x, 1.4, z)
        r = 0.7 * self.f / max(z - self.cz, 0.05)
        g.ellipse([cc[0] - r, cc[1] - r, cc[0] + r, cc[1] + r], fill=70)
        glow = glow.filter(ImageFilter.GaussianBlur(40 * SS))
        self.img.paste((255, 235, 190), (0, 0), glow)
        self.d = ImageDraw.Draw(self.img, "RGBA")

    def frame_art(self, x0, x1, y0, y1, colors):
        z = self.rd - 0.003
        self.poly([(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)], (60, 55, 50))
        m = 0.03
        self.poly([(x0 + m, y0 + m, z), (x1 - m, y0 + m, z), (x1 - m, y1 - m, z), (x0 + m, y1 - m, z)], colors[0])
        self.poly([(x0 + m, y0 + m, z), (x1 - m, y0 + m, z), ((x0 + x1) / 2, (y0 + y1) / 2 + 0.05, z)], colors[1])

    def shelf(self, x0, z0, w=0.8, d=0.35, h=1.2, color=(210, 185, 150)):
        x1, z1 = x0 + w, z0 + d
        self.box(x0, x1, 0, h, z0, z1, color)
        for i in range(1, 4):
            y = h * i / 4
            self.line3((x0, y, z0 - 0.001), (x1, y, z0 - 0.001), shade(color, 0.7), 1.5)
        rnd = random.Random(int(x0 * 50))
        for i in range(4):
            y = h * i / 4 + 0.02
            bx = x0 + 0.05
            while bx < x1 - 0.1:
                bw = rnd.uniform(0.03, 0.06)
                bh = rnd.uniform(0.15, h / 4 - 0.05)
                col = rnd.choice([(190, 80, 70), (70, 110, 150), (220, 190, 110), (90, 140, 110), (160, 140, 180)])
                self.box(bx, bx + bw, y, y + bh, z0 - 0.002, z0 + 0.02, col)
                bx += bw + 0.005

    def ceiling_light(self, x, z, r=0.25):
        c = self.P(x, self.rh - 0.01, z)
        rx = r * self.f / max(z - self.cz, 0.05)
        ry = rx * 0.25
        self.d.ellipse([c[0] - rx, c[1] - ry, c[0] + rx, c[1] + ry], fill=(255, 255, 250), outline=(220, 220, 215))

    def finish(self, path, warm=0.0):
        img = self.img.resize((OW, OH), Image.LANCZOS)
        a = np.asarray(img).astype(np.float32)
        yy, xx = np.mgrid[0:OH, 0:OW]
        r = np.sqrt(((xx - OW / 2) / (OW / 2)) ** 2 + ((yy - OH / 2) / (OH / 2)) ** 2)
        vig = 1 - 0.18 * np.clip(r - 0.35, 0, 1) ** 1.5
        a *= vig[:, :, None]
        if warm:
            a[:, :, 0] *= 1 + warm; a[:, :, 2] *= 1 - warm
        noise = np.random.default_rng(len(path)).normal(0, 2.0, a.shape)
        a = np.clip(a + noise, 0, 255).astype(np.uint8)
        Image.fromarray(a).save(path, quality=84, optimize=True, progressive=True)


WALLS = [(242, 238, 230), (236, 238, 240), (238, 232, 222), (226, 232, 224), (232, 236, 242), (244, 236, 232)]
FLOORS = [(196, 158, 118), (170, 128, 92), (214, 190, 160), (150, 110, 80), (205, 200, 195)]

def room(idx, out):
    rnd = random.Random(idx * 7919)
    rw = rnd.choice([3.2, 3.4, 3.6, 3.8]); rh = 2.4; rd = rnd.choice([3.8, 4.2, 4.6])
    camx = rnd.uniform(-0.35, 0.35)
    s = Scene(rw, rh, rd, (camx, 1.35, -0.9), focal=rnd.choice([430, 470, 500]))
    wall = WALLS[idx % len(WALLS)]; floor = FLOORS[(idx * 3) % len(FLOORS)]
    kind = "tile" if idx % 7 == 5 else "wood"
    s.shell(wall, floor if kind == "wood" else (225, 222, 218), shade(wall, 1.03), floor_kind=kind)
    L, R = -rw / 2, rw / 2
    variant = idx % 5
    curtain = rnd.choice([None, (245, 240, 230), (215, 220, 225), (230, 215, 200)])
    if variant in (0, 2, 4):
        s.window_back(-0.7, 0.7, 0.95, 2.05, curtain=curtain)
    else:
        s.window_left(rd - 2.2, rd - 0.9, 0.95, 2.0)
        s.frame_art(-0.35, 0.35, 1.35, 1.85, [(200, 170, 140), (120, 150, 170)])
    s.ceiling_light(0, rd * 0.55)
    items = []
    if variant == 0:      # 원룸: 침대 오른쪽, 책상 왼쪽
        s.rug(-0.8, 0.6, 1.2, 2.6, rnd.choice([(210, 190, 170), (190, 200, 210), (220, 205, 190)]))
        s.wardrobe(L + 0.05, rd - 0.65, color=(236, 232, 224))
        s.bed(R - 1.15, rd - 2.05, blanket=rnd.choice([(120, 150, 190), (200, 140, 120), (140, 170, 140)]))
        s.desk(L + 0.05, 1.3, w=1.1)
        s.chair(L + 0.35, 1.0)
        s.plant(R - 0.3, 0.9)
    elif variant == 1:    # 소파 + 선반
        s.rug(-1.0, 1.0, 1.3, 2.9, (215, 205, 190))
        s.sofa(-0.85, rd - 1.0, color=rnd.choice([(150, 160, 170), (180, 160, 140), (120, 135, 125)]))
        s.shelf(R - 0.85, rd - 0.4)
        s.lamp(L + 0.45, rd - 0.6)
        s.plant(L + 0.4, 1.3)
    elif variant == 2:    # 침대 가운데 + 협탁
        s.rug(-1.2, 1.2, 1.0, 2.2, (205, 195, 185))
        s.bed(-0.75, rd - 2.1, w=1.5, blanket=rnd.choice([(235, 225, 210), (150, 170, 200)]))
        s.box(-1.2, -0.85, 0, 0.5, rd - 0.45, rd - 0.05, (200, 170, 130))
        s.box(0.85, 1.2, 0, 0.5, rd - 0.45, rd - 0.05, (200, 170, 130))
        s.lamp(R - 0.35, rd - 0.9)
    elif variant == 3:    # 주방 겸 원룸: 냉장고·세탁기 + 책상
        s.fridge(L + 0.05, rd - 0.7)
        s.washer(L + 0.7, rd - 0.65)
        s.box(L + 1.35, L + 2.4, 0, 0.88, rd - 0.62, rd - 0.02, (235, 235, 235), top=(205, 200, 195))
        s.desk(R - 1.3, 1.6, w=1.2, color=(225, 215, 200))
        s.chair(R - 0.9, 1.25, color=(200, 90, 70))
        s.plant(R - 0.25, rd - 0.35, h=1.3)
    else:                 # 빈 방 (입주 예상 느낌)
        s.rug(-0.9, 0.9, 1.4, 2.8, (230, 222, 210))
        s.wardrobe(R - 0.95, rd - 0.62, w=0.9)
        s.plant(L + 0.35, rd - 0.4, h=1.0)
    s.finish(out, warm=rnd.uniform(0, 0.03))



# ---------------------------------------------------------------- 추가: 문, 욕실, 매물별 세트
def door_right(s, z0, z1, color=(214, 190, 160)):
    x = s.rw / 2 - 0.002
    s.poly([(x, 0, z0), (x, 2.1, z0), (x, 2.1, z1), (x, 0, z1)], color)
    t = 0.05
    fr = shade(color, 0.8)
    for q in [[(x, 2.1, z0 - t), (x, 2.1 + t, z0 - t), (x, 2.1 + t, z1 + t), (x, 2.1, z1 + t)],
              [(x, 0, z0 - t), (x, 2.1, z0 - t), (x, 2.1, z0), (x, 0, z0)],
              [(x, 0, z1), (x, 2.1, z1), (x, 2.1, z1 + t), (x, 0, z1 + t)]]:
        s.poly(q, fr)
    s.box(x - 0.05, x, 0.95, 1.0, z0 + 0.08, z0 + 0.2, (190, 190, 195))


def tile_wall_lines(s, color):
    rw, rh, rd = s.rw / 2, s.rh, s.rd
    k = 0.3
    y = k
    while y < rh:
        s.line3((-rw, y, -1), (-rw, y, rd), color, 1)
        s.line3((rw, y, -1), (rw, y, rd), color, 1)
        s.line3((-rw, y, rd - 0.002), (rw, y, rd - 0.002), color, 1)
        y += k
    x = -rw + k
    while x < rw:
        s.line3((x, 0, rd - 0.002), (x, rh, rd - 0.002), color, 1)
        x += k
    z = 0
    while z < rd:
        s.line3((-rw + 0.001, 0, z), (-rw + 0.001, rh, z), color, 1)
        s.line3((rw - 0.001, 0, z), (rw - 0.001, rh, z), color, 1)
        z += k


def bathroom(idx, out):
    rnd = random.Random(idx * 104729)
    s = Scene(1.9, 2.3, 2.4, (rnd.uniform(-0.12, 0.12), 1.4, -0.25), focal=420)
    wall = rnd.choice([(236, 238, 238), (232, 236, 240), (240, 236, 230)])
    s.shell(wall, (205, 205, 208), shade(wall, 1.03), floor_kind="tile")
    tile_wall_lines(s, shade(wall, 0.9) + (160,))
    L, R, D = -0.95, 0.95, 2.4
    # 세면대 + 거울 (뒷벽 왼쪽)
    s.box(L + 0.1, L + 0.9, 0, 0.82, D - 0.5, D - 0.02, (225, 220, 212), top=(245, 245, 245))
    s.poly([(L + 0.15, 1.1, D - 0.003), (L + 0.85, 1.1, D - 0.003), (L + 0.85, 1.85, D - 0.003), (L + 0.15, 1.85, D - 0.003)], (205, 220, 228))
    s.poly([(L + 0.2, 1.15, D - 0.004), (L + 0.45, 1.15, D - 0.004), (L + 0.3, 1.8, D - 0.004)], (235, 244, 248, 160))
    s.box(L + 0.47, L + 0.53, 0.82, 0.95, D - 0.2, D - 0.12, (190, 190, 195))
    # 변기 (오른쪽)
    tx = R - 0.55
    s.box(tx, tx + 0.4, 0, 0.42, D - 0.75, D - 0.2, (248, 248, 248))
    s.box(tx - 0.02, tx + 0.42, 0.42, 0.46, D - 0.78, D - 0.2, (240, 240, 240))
    s.box(tx + 0.02, tx + 0.38, 0.46, 0.85, D - 0.22, D - 0.02, (250, 250, 250))
    # 샤워 유리
    s.poly([(L + 0.95, 0, 0.9), (L + 0.95, 2.0, 0.9), (L + 0.95, 2.0, D - 0.55), (L + 0.95, 0, D - 0.55)], (210, 230, 240, 70), outline=(180, 200, 210, 150), width=1)
    # 수건
    s.box(R - 0.02, R, 1.1, 1.15, 0.9, 1.5, (180, 180, 185))
    s.poly([(R - 0.03, 0.6, 0.95), (R - 0.03, 1.12, 0.95), (R - 0.03, 1.12, 1.45), (R - 0.03, 0.6, 1.45)], rnd.choice([(230, 200, 180), (190, 210, 225), (245, 245, 240)]))
    s.ceiling_light(0, 1.4, 0.18)
    s.finish(out)


def listing_set(n, outdir):
    """매물 n 의 사진 세트: 같은 방을 다른 위치에서 본 2장 + 부분 확대 1장."""
    base = n - 1
    files = []
    for k, (dx, df) in enumerate([(0.0, 0), (0.55, -40)]):
        rnd_state = random.getstate()
        path = os.path.join(outdir, f"L{n:02d}_{k + 1}.jpg")
        room_view(base, path, cam_dx=dx if base % 2 == 0 else -dx, focal_delta=df)
        files.append(os.path.basename(path))
    # 부분 확대: 첫 장을 크게 렌더링해서 잘라낸다
    big = os.path.join(outdir, f"_big.jpg")
    room_view(base, big, cam_dx=0, focal_delta=0, scale=1.6)
    im = Image.open(big)
    w, h = im.size
    boxes = [(0.05, 0.45), (0.45, 0.45), (0.25, 0.2)]
    bx, by = boxes[base % 3]
    crop = im.crop((int(w * bx), int(h * by), int(w * bx) + int(w * 0.5), int(h * by) + int(h * 0.5))).resize((OW, OH), Image.LANCZOS)
    p3 = os.path.join(outdir, f"L{n:02d}_3.jpg")
    crop.save(p3, quality=84, optimize=True, progressive=True)
    os.remove(big)
    files.append(os.path.basename(p3))
    return files


def room_view(idx, out, cam_dx=0.0, focal_delta=0, scale=1.0):
    global OW, OH, W, H
    ow, oh = OW, OH
    if scale != 1.0:
        OW, OH = int(ow * scale), int(oh * scale)
        W, H = OW * SS, OH * SS
    try:
        _room_impl(idx, out, cam_dx, focal_delta, scale)
    finally:
        OW, OH = ow, oh
        W, H = OW * SS, OH * SS


def _room_impl(idx, out, cam_dx, focal_delta, scale):
    rnd = random.Random(idx * 7919)
    rw = rnd.choice([3.2, 3.4, 3.6, 3.8]); rh = 2.4; rd = rnd.choice([3.8, 4.2, 4.6])
    camx = rnd.uniform(-0.35, 0.35) + cam_dx
    focal = (rnd.choice([430, 470, 500]) + focal_delta) * scale
    s = Scene(rw, rh, rd, (camx, 1.35, -0.9), focal=focal / 1.0)
    s.u0 = W / 2; s.v0 = H / 2 + 20 * SS * scale
    wall = WALLS[idx % len(WALLS)]; floor = FLOORS[(idx * 3) % len(FLOORS)]
    kind = "tile" if idx % 7 == 5 else "wood"
    s.shell(wall, floor if kind == "wood" else (225, 222, 218), shade(wall, 1.03), floor_kind=kind)
    L, R = -rw / 2, rw / 2
    variant = idx % 5
    curtain = rnd.choice([None, (245, 240, 230), (215, 220, 225), (230, 215, 200)])
    if variant in (0, 2, 4):
        s.window_back(-0.7, 0.7, 0.95, 2.05, curtain=curtain)
    else:
        s.window_left(rd - 2.2, rd - 0.9, 0.95, 2.0)
        s.frame_art(-0.35, 0.35, 1.35, 1.85, [(200, 170, 140), (120, 150, 170)])
    if variant in (1, 3, 4):
        door_right(s, 0.3, 1.2)
    s.ceiling_light(0, rd * 0.55)
    if variant == 0:
        s.rug(-0.8, 0.6, 1.2, 2.6, rnd.choice([(210, 190, 170), (190, 200, 210), (220, 205, 190)]))
        s.wardrobe(L + 0.05, rd - 0.65, color=(236, 232, 224))
        s.bed(R - 1.15, rd - 2.05, blanket=rnd.choice([(120, 150, 190), (200, 140, 120), (140, 170, 140)]))
        s.desk(L + 0.05, 1.3, w=1.1)
        s.chair(L + 0.35, 1.0)
        s.plant(R - 0.3, 0.9)
    elif variant == 1:
        s.rug(-1.0, 1.0, 1.3, 2.9, (215, 205, 190))
        s.sofa(-0.85, rd - 1.0, color=rnd.choice([(150, 160, 170), (180, 160, 140), (120, 135, 125)]))
        s.shelf(R - 0.85, rd - 0.4)
        s.lamp(L + 0.45, rd - 0.6)
        s.plant(L + 0.4, 1.3)
    elif variant == 2:
        s.rug(-1.2, 1.2, 1.0, 2.2, (205, 195, 185))
        s.bed(-0.75, rd - 2.1, w=1.5, blanket=rnd.choice([(235, 225, 210), (150, 170, 200)]))
        s.box(-1.2, -0.85, 0, 0.5, rd - 0.45, rd - 0.05, (200, 170, 130))
        s.box(0.85, 1.2, 0, 0.5, rd - 0.45, rd - 0.05, (200, 170, 130))
        s.lamp(R - 0.35, rd - 0.9)
    elif variant == 3:
        s.fridge(L + 0.05, rd - 0.7)
        s.washer(L + 0.7, rd - 0.65)
        s.box(L + 1.35, L + 2.4, 0, 0.88, rd - 0.62, rd - 0.02, (235, 235, 235), top=(205, 200, 195))
        s.desk(R - 1.3, 1.6, w=1.2, color=(225, 215, 200))
        s.chair(R - 0.9, 1.25, color=(200, 90, 70))
        s.plant(R - 0.25, rd - 0.35, h=1.3)
    else:
        s.rug(-0.9, 0.9, 1.4, 2.8, (230, 222, 210))
        s.wardrobe(R - 0.95, rd - 0.62, w=0.9)
        s.plant(L + 0.35, rd - 0.4, h=1.0)
    s.finish(out, warm=rnd.uniform(0, 0.03))


import os
def build_all(outdir, nlist=12):
    os.makedirs(outdir, exist_ok=True)
    sets = {}
    for n in range(1, nlist + 1):
        sets[n] = listing_set(n, outdir)
    for b in range(1, 4):
        bathroom(b, os.path.join(outdir, f"bath_{b}.jpg"))
    return sets
