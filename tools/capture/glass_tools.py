"""투명 유리(유리창 · 유리벽 · 유리문) 때문에 메시 · 점군이 깨지는 것을 막는다.

LiDAR 레이저는 맑은 유리를 거의 그대로 통과한다. 그래서 유리 너머(옆방 · 복도 · 바깥)까지 깊이가 찍히고, 그 점이 메시에
섞이면 벽 자리에 구멍이 나고 벽 밖에 엉뚱한 덩어리가 붙는다. 이 도구는 RoomPlan 이 찾은 벽 · 창 · 문을 기준으로
LiDAR 점이 '벽 밖으로 나가는' 곳을 찾아 투명 유리로 판단하고, 메시를 만들기 전 · 후 양쪽에서 고친다.
유리는 LiDAR · 사진으로 재구성할 수 없으므로, 유리로 판단한 자리에는 크기 · 위치 · 방향을 맞춘 유리 3D 물체를 따로 만든다.

사용법 (Mac 터미널):
  python3 tools/capture/glass_tools.py ~/Downloads/capture                     # 압축 푼 폴더 (zip 도 됨)
  python3 tools/capture/glass_tools.py ~/Downloads/capture --mesh mesh.ply     # 이미 만든 메시도 방 밖을 잘라냄 (PLY · OBJ)
  옵션: --margin 0.2 (벽에서 이만큼 밖이면 '벽 밖', m)  --thickness 0.01 (유리 두께, m)  --no-masks  --no-ply  --voxel 0.015

capture 폴더 안에 만드는 것:
  glass.glb             유리 3D 물체. 유리 하나 = 노드 하나(glass_0_window …, 두께 1 cm 상자), 노드에 위치 · 회전.
                        ARKit 월드 좌표(m, Y-up)라 메시 · 3DGS 와 같은 자리에 겹친다. 재질은 앱 블록아웃 뷰의 유리처럼 반투명 하늘색
                        (#cfe7ff, 알파 0.35, 약한 발광) — 투과 유리는 뒤가 비쳐 구멍처럼 보여서. 노드 extras 에 종류 · 폭 · 높이 · 두께 · yaw
  glass.json            창 · 문 · 벽마다 '벽 밖으로 나간 LiDAR 점' 수 · 프레임 수 · 유리 판정 · 유리판 꼭짓점, 프레임별로 지운 비율,
                        objects: 앱 SpaceResponse.objects 와 같은 형식(category "glass", position = 중심, rotation.yaw, dimensions)
  depth_clean/          depth/ 와 같은 형식(uint16 mm, 0 = 없음). 벽 밖으로 나간 픽셀만 0 → TSDF 등 메시 입력으로 이걸 쓰세요
  points_clean.ply      points.ply 와 같은 방식(신뢰도 높음, 1.5 cm 격자)이지만 depth_clean 기준 → 포아송 메시 · 3DGS 초기 점군
  glass_panes.obj/.mtl  glass.glb 와 같은 유리 상자 (OBJ, 반투명 재질) — Blender · MeshLab 에서 메시와 같이 불러오면 구멍이 막힘
  glass_panes.ply       같은 유리 상자 (PLY, 꼭짓점 색 RGBA)
  glass_mask/           프레임별 마스크(컬러 해상도, 흰색 = 유리 · 열린 문 너머가 보이는 픽셀) → 텍스처 · 3DGS 학습에서 뺄 곳
  --mesh 를 주면 그 메시 옆에 <이름>_room.ply|obj — 꼭짓점이 모두 방 밖인 면을 지운 메시 (OBJ 는 유리 상자까지 붙임)

판단 기준: 창 · 닫힌 문은 그 사각형을 지나 벽 밖에 찍힌 점이 500개 이상 · 2프레임 이상이면 유리,
RoomPlan 이 창 · 문으로 못 찾은 벽(또는 벽이 빠진 자리)은 전체 점의 0.4% 이상 · 3프레임 이상이면 유리로 본다.
유리판 크기: 문은 RoomPlan 사각형 그대로. 창은 RoomPlan 사각형(창틀 · 위 벽까지 크게 잡히곤 함)에서, 벽은 벽 전체에서 시작해
LiDAR 가 지나간 범위 밖의 띠가 벽면에 맞은 점(불투명)으로 채워져 있으면 그쪽을 줄인다. 아무것도 안 찍힌 띠는 유리일 수 있어 남긴다.
열린 문 · 문 없는 통로는 유리판을 만들지 않고(공기라서) 벽 밖 점만 지운다. 거울도 벽 밖에 '거울 속 방' 이 찍히므로 같은 방식으로
지워지고 그 자리에 유리판이 생긴다. roomplan.json 없이 roomplan_structure.json 만 있는 예전 촬영본은 문이 열렸는지 몰라 닫힌 문으로 본다.
원본(depth/ · frames/ · points.ply)은 건드리지 않는다. 필요: pip install numpy pillow
"""
import argparse
import json
import math
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw

sys.dont_write_bytecode = True                    # 저장소에 __pycache__/ 를 남기지 않는다
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from depth_tools import find_capture, write_ply  # noqa: E402  (같은 폴더의 depth_tools 를 그대로 쓴다)

NEAR_M, FAR_M = 0.2, 5.0             # 믿을 만한 LiDAR 거리
EDGE_TOL_M = 0.3                     # 벽 끝점끼리 이만큼 가까우면 이어진 것으로 본다
OPENING_TOL_M = 0.15                 # 창 · 문 사각형을 이만큼 넉넉하게 본다
GLASS_RGBA = (207, 231, 255, 90)     # 유리 색 #cfe7ff, 알파 0.35 (앱 블록아웃 뷰의 유리와 같은 색)


# ---------------------------------------------------------------- RoomPlan

def _read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _mat(t):
    """RoomPlan JSON 의 transform (열 우선 16개) → 4×4 행렬"""
    return np.array(t, dtype=np.float64).reshape(4, 4).T


def load_room(cap):
    """벽 · 창 · 문 · 바닥 높이 · 천장 높이. roomplan.json(애플 형식)을 먼저 보고, 없으면 roomplan_structure.json"""
    p = os.path.join(cap, "roomplan.json")
    if os.path.isfile(p):
        return _room_from_roomplan(_read_json(p))
    p = os.path.join(cap, "roomplan_structure.json")
    if os.path.isfile(p):
        return _room_from_structure(_read_json(p))
    sys.exit("roomplan.json / roomplan_structure.json 이 없어 벽 위치를 알 수 없습니다 (LiDAR 기기에서 방 촬영으로 찍은 capture 가 필요)")


def _room_from_roomplan(r):
    walls = []
    for w in r.get("walls", []):
        T = _mat(w["transform"])
        c, ax = T[:3, 3], T[:3, 0] / max(np.linalg.norm(T[:3, 0]), 1e-9)
        width, height = float(w["dimensions"][0]), float(w["dimensions"][1])
        walls.append({"id": w.get("identifier"), "a": (c - ax * width / 2)[[0, 2]], "b": (c + ax * width / 2)[[0, 2]],
                      "bottom": c[1] - height / 2, "top": c[1] + height / 2})
    openings = []
    for key, kind in (("windows", "window"), ("doors", "door"), ("openings", "opening")):
        for o in r.get(key, []):
            cat = o.get("category") or {}
            T = _mat(o["transform"])
            openings.append({"id": o.get("identifier"), "kind": kind, "parent": o.get("parentIdentifier"),
                             "open": kind == "opening" or bool((cat.get("door") or {}).get("isOpen", False)),
                             "center": T[:3, 3].copy(),
                             "width": float(o["dimensions"][0]), "height": float(o["dimensions"][1])})
    floor_poly = floor_y = None
    for f in r.get("floors", []):
        T = _mat(f["transform"])
        corners = f.get("polygonCorners") or []
        if len(corners) >= 3:
            loc = np.array([[q[0], q[1], q[2] if len(q) > 2 else 0.0, 1.0] for q in corners], float)
        else:
            hw, hh = f["dimensions"][0] / 2, f["dimensions"][1] / 2
            loc = np.array([[-hw, -hh, 0, 1], [hw, -hh, 0, 1], [hw, hh, 0, 1], [-hw, hh, 0, 1]], float)
        world = (T @ loc.T).T
        floor_poly, floor_y = world[:, [0, 2]], float(world[:, 1].mean())
        break
    if floor_y is None:
        floor_y = min((w["bottom"] for w in walls), default=0.0)
    ceiling_y = max((w["top"] for w in walls), default=floor_y + 2.4)
    return {"walls": walls, "openings": openings, "floorY": floor_y, "ceilingY": ceiling_y, "floorPoly": floor_poly}


def _room_from_structure(s):
    g = s.get("roomGeometry") or s
    floor_y, height = float(g.get("floorHeight", 0.0)), float(g.get("ceilingHeight", 2.4))
    walls = [{"id": w.get("id"), "a": np.array(w["from"], float), "b": np.array(w["to"], float),
              "bottom": floor_y, "top": floor_y + float(w.get("height", height))} for w in g.get("walls", [])]
    openings = []
    for key in ("windows", "doors"):
        for o in g.get(key) or []:
            pos, dim = o["position"], o["dimensions"]
            openings.append({"id": o.get("id"), "kind": o.get("type", key[:-1]), "parent": None, "open": False,
                             "center": np.array([pos["x"], pos["y"], pos["z"]], float),
                             "width": float(dim["width"]), "height": float(dim["height"])})
    return {"walls": walls, "openings": openings, "floorY": floor_y, "ceilingY": floor_y + height, "floorPoly": None}


# ---------------------------------------------------------------- 방 모양 (바닥 위에서 본 다각형, x-z)

def room_polygon(room):
    """(꼭짓점 (M,2), 변마다 벽 번호 또는 -1, 출처). 벽이 닫힌 고리로 이어지면 벽, 아니면 RoomPlan 바닥, 그것도 없으면 볼록 껍질"""
    walls = room["walls"]
    loop = _chain(walls) if len(walls) >= 3 else None
    if loop is not None:
        return loop[0], loop[1], "walls"
    if room.get("floorPoly") is not None and len(room["floorPoly"]) >= 3:
        poly = np.asarray(room["floorPoly"], float)
        return poly, _match_edges(poly, walls), "floor"
    pts = np.array([w[k] for w in walls for k in ("a", "b")], float)
    if len(pts) < 3:
        sys.exit("RoomPlan 벽이 너무 적어 방 모양을 알 수 없습니다")
    poly = _convex_hull(pts)
    return poly, _match_edges(poly, walls), "hull"


def _chain(walls):
    segs = [(np.asarray(w["a"], float), np.asarray(w["b"], float)) for w in walls]
    used, order = [False] * len(segs), [0]
    used[0] = True
    pts, cur = [segs[0][0], segs[0][1]], segs[0][1]
    while True:
        best = None
        for j, (a, b) in enumerate(segs):
            if used[j]:
                continue
            for end, other in ((a, b), (b, a)):
                d = np.linalg.norm(end - cur)
                if d < EDGE_TOL_M and (best is None or d < best[0]):
                    best = (d, j, other)
        if best is None:
            break
        _, j, other = best
        used[j] = True
        order.append(j)
        pts.append(other)
        cur = other
    if not all(used) or np.linalg.norm(cur - pts[0]) >= EDGE_TOL_M:
        return None
    return np.array(pts[:-1]), order


def _match_edges(poly, walls):
    out = []
    for a, b in zip(poly, np.roll(poly, -1, axis=0)):
        d = (b - a) / max(np.linalg.norm(b - a), 1e-9)
        best = -1
        for j, w in enumerate(walls):
            wd = w["b"] - w["a"]
            mid = (w["a"] + w["b"]) / 2
            along = np.clip(np.dot(mid - a, d), 0, np.linalg.norm(b - a))
            if abs(np.dot(wd, d)) > 0.9 * np.linalg.norm(wd) and np.linalg.norm(mid - (a + d * along)) < EDGE_TOL_M:
                best = j
        out.append(best)
    return out


def _convex_hull(pts):
    pts = sorted(set(map(tuple, np.round(pts, 4))))
    def half(seq):
        h = []
        for p in seq:
            while len(h) >= 2 and ((h[-1][0] - h[-2][0]) * (p[1] - h[-2][1]) - (h[-1][1] - h[-2][1]) * (p[0] - h[-2][0])) <= 0:
                h.pop()
            h.append(p)
        return h
    lower, upper = half(pts), half(pts[::-1])
    return np.array(lower[:-1] + upper[:-1], float)


def signed_distance(poly, q, chunk=200000):
    """q (N,2) 의 다각형까지 거리. 안쪽 −, 바깥 +"""
    out = np.empty(len(q))
    a, b = poly, np.roll(poly, -1, axis=0)
    ab = b - a
    len2 = np.maximum((ab * ab).sum(-1), 1e-12)
    dy = np.where(np.abs(b[:, 1] - a[:, 1]) < 1e-12, 1e-12, b[:, 1] - a[:, 1])
    for s in range(0, len(q), chunk):
        p = q[s:s + chunk]
        ap = p[:, None, :] - a[None]
        t = np.clip((ap * ab[None]).sum(-1) / len2[None], 0, 1)
        d = np.linalg.norm(ap - t[..., None] * ab[None], axis=-1).min(1)
        y = p[:, 1:2]
        crosses = (a[None, :, 1] > y) != (b[None, :, 1] > y)
        xint = a[None, :, 0] + (y - a[None, :, 1]) * (b[None, :, 0] - a[None, :, 0]) / dy[None]
        inside = (crosses & (p[:, 0:1] < xint)).sum(1) % 2 == 1
        out[s:s + chunk] = np.where(inside, -d, d)
    return out


def first_crossing(poly, c, p):
    """카메라 c (2,) → 점 p (N,2) 선분이 처음 지나는 방 경계 변 번호와 그 비율 t (못 찾으면 가장 가까운 변, t=1)"""
    a, s = poly, np.roll(poly, -1, axis=0) - poly
    r = p - c
    denom = r[:, None, 0] * s[None, :, 1] - r[:, None, 1] * s[None, :, 0]
    denom = np.where(np.abs(denom) < 1e-12, np.nan, denom)
    ac = (a - c)[None]
    with np.errstate(invalid="ignore"):
        t = (ac[..., 0] * s[None, :, 1] - ac[..., 1] * s[None, :, 0]) / denom
        u = (ac[..., 0] * r[:, None, 1] - ac[..., 1] * r[:, None, 0]) / denom
        t = np.where((t >= 0) & (t <= 1) & (u >= 0) & (u <= 1), t, np.inf)
    e = t.argmin(1)
    tt = t[np.arange(len(p)), e]
    miss = ~np.isfinite(tt)
    if miss.any():
        ap = p[miss][:, None, :] - a[None]
        k = np.clip((ap * s[None]).sum(-1) / np.maximum((s * s).sum(-1), 1e-12)[None], 0, 1)
        e[miss] = np.linalg.norm(ap - k[..., None] * s[None], axis=-1).argmin(1)
        tt = np.where(miss, 1.0, tt)
    return e, tt


# ---------------------------------------------------------------- 유리 후보 (창 · 문 · 벽)

def build_candidates(room, poly, edge_wall):
    """창 · 문은 RoomPlan 사각형 그대로, 벽(창 · 문 밖 부분)과 벽이 빠진 자리는 변 하나를 후보로"""
    ends = list(zip(poly, np.roll(poly, -1, axis=0)))
    wall_edge = {room["walls"][w]["id"]: e for e, w in enumerate(edge_wall) if w >= 0}
    cands = []
    for o in room["openings"]:
        e = wall_edge.get(o["parent"])
        if e is None:      # 부모 벽을 모르면 가장 가까운 변
            q = o["center"][[0, 2]]
            e = int(np.argmin([_seg_dist(q, a, b) for a, b in ends]))
        a, b = ends[e]
        d = (b - a) / max(np.linalg.norm(b - a), 1e-9)
        cands.append({"kind": o["kind"], "id": o["id"], "edge": e, "open": o["open"],
                      "s": float(np.dot(o["center"][[0, 2]] - a, d)), "y": float(o["center"][1]),
                      "width": o["width"], "height": o["height"]})
    for e, w in enumerate(edge_wall):
        cands.append({"kind": "wall" if w >= 0 else "gap", "id": room["walls"][w]["id"] if w >= 0 else None,
                      "edge": e, "open": False})
    for c in cands:
        c.update(points=0, frames=0, _s=[], _y=[])
    return cands


def _seg_dist(q, a, b):
    ab = b - a
    t = np.clip(np.dot(q - a, ab) / max(np.dot(ab, ab), 1e-12), 0, 1)
    return float(np.linalg.norm(q - (a + t * ab)))


def attribute(cands, poly, cam, pts):
    """벽 밖 점들(pts (N,3))이 어느 창 · 문 · 벽을 지나 나갔는지 → 후보 번호 배열"""
    e, t = first_crossing(poly, cam[[0, 2]], pts[:, [0, 2]])
    hit_xz = cam[[0, 2]] + t[:, None] * (pts[:, [0, 2]] - cam[[0, 2]])
    hit_y = cam[1] + t * (pts[:, 1] - cam[1])
    a = poly[e]
    b = np.roll(poly, -1, axis=0)[e]
    d = (b - a) / np.maximum(np.linalg.norm(b - a, axis=1, keepdims=True), 1e-9)
    s = ((hit_xz - a) * d).sum(1)
    owner = np.full(len(pts), -1)
    for i, c in enumerate(cands):            # 벽 후보 먼저 정하고, 그 안의 창 · 문 사각형에 들면 창 · 문으로 덮어쓴다
        if c["kind"] in ("wall", "gap"):
            owner[e == c["edge"]] = i
    for i, c in enumerate(cands):
        if c["kind"] in ("wall", "gap"):
            continue
        inside = ((e == c["edge"]) & (np.abs(s - c["s"]) <= c["width"] / 2 + OPENING_TOL_M)
                  & (np.abs(hit_y - c["y"]) <= c["height"] / 2 + OPENING_TOL_M))
        owner[inside] = i
    return owner, s, hit_y


CELL_M = 0.05                        # 벽면에 맞은 점을 세는 칸 크기


def init_grids(cands, poly, room):
    """창은 사각형 ±10 cm, 벽 · 빠진 벽은 변 전체 × 바닥~천장 범위에 5 cm 칸을 만든다 (유리판 범위를 정할 때 씀)"""
    for c in cands:
        if c["kind"] == "window":
            s0, s1 = c["s"] - c["width"] / 2 - 0.1, c["s"] + c["width"] / 2 + 0.1
            y0, y1 = c["y"] - c["height"] / 2 - 0.1, c["y"] + c["height"] / 2 + 0.1
        elif c["kind"] in ("wall", "gap"):
            a = poly[c["edge"]]
            s0, s1 = 0.0, float(np.linalg.norm(np.roll(poly, -1, axis=0)[c["edge"]] - a))
            y0, y1 = room["floorY"], room["ceilingY"]
        else:
            continue
        ns, ny = max(1, int(np.ceil((s1 - s0) / CELL_M))), max(1, int(np.ceil((y1 - y0) / CELL_M)))
        c["_grid"] = (s0, y0, np.zeros((ns, ny), np.int64))


def collect_solid(cands, poly, pts):
    """벽면 ±6 cm 에 맞은 점 = 그 자리는 유리가 아니라는 증거(창틀 · 위아래 벽 · 막힌 벽 부분). 후보 격자에 센다"""
    if not len(pts):
        return
    for c in cands:
        if "_grid" not in c:
            continue
        a = poly[c["edge"]]
        b = np.roll(poly, -1, axis=0)[c["edge"]]
        d = (b - a) / max(np.linalg.norm(b - a), 1e-9)
        q = pts[:, [0, 2]] - a
        s0, y0, grid = c["_grid"]
        i = np.floor(((q @ d) - s0) / CELL_M).astype(np.int64)
        j = np.floor((pts[:, 1] - y0) / CELL_M).astype(np.int64)
        m = (np.abs(q[:, 0] * d[1] - q[:, 1] * d[0]) <= 0.06) & (i >= 0) & (i < grid.shape[0]) & (j >= 0) & (j < grid.shape[1])
        if m.any():
            np.add.at(grid, (i[m], j[m]), 1)


def shrink_to_glass(c, s0, s1, y0, y1, lo, hi):
    """유리판 사각형(s0..s1, y0..y1)을 LiDAR 가 지나간 범위(lo–hi 백분위) 쪽으로 줄인다. 단 그 사이 띠가
    벽면에 맞은 점(불투명)으로 채워져 있을 때만. 아무것도 안 찍힌 띠(유리 너머가 5 m 밖 · 화면에 안 들어옴)는 유리일 수 있어 그대로"""
    if len(c["_s"]) < 500 or "_grid" not in c:
        return s0, s1, y0, y1
    ls0, ls1 = np.percentile(c["_s"], [lo, hi])
    ly0, ly1 = np.percentile(c["_y"], [lo, hi])
    gs0, gy0, grid = c["_grid"]
    cs = gs0 + (np.arange(grid.shape[0]) + 0.5) * CELL_M
    cy = gy0 + (np.arange(grid.shape[1]) + 0.5) * CELL_M

    def solid(sa, sb, ya, yb):
        hits = grid[(cs >= sa) & (cs <= sb)][:, (cy >= ya) & (cy <= yb)].sum()
        seen = ((c["_s"] >= sa) & (c["_s"] <= sb) & (c["_y"] >= ya) & (c["_y"] <= yb)).sum()
        return hits >= 100 and hits >= 4 * seen
    if ly1 + 0.05 < y1 and solid(s0, s1, ly1 + 0.05, y1):
        y1 = ly1 + 0.05
    if ly0 - 0.05 > y0 and solid(s0, s1, y0, ly0 - 0.05):
        y0 = ly0 - 0.05
    if ls1 + 0.05 < s1 and solid(ls1 + 0.05, s1, y0, y1):
        s1 = ls1 + 0.05
    if ls0 - 0.05 > s0 and solid(s0, ls0 - 0.05, y0, y1):
        s0 = ls0 - 0.05
    return s0, s1, y0, y1


def decide(cands, total_points):
    for c in cands:
        if c["open"]:
            c["glass"], c["reason"] = False, "열린 문 · 통로 (공기라서 유리판 없음, 벽 밖 점만 지움)"
        elif c["kind"] in ("window", "door"):
            c["glass"] = c["points"] >= 500 and c["frames"] >= 2
            c["reason"] = ("LiDAR 가 이 사각형을 지나 벽 밖까지 찍힘" if c["glass"]
                           else "벽 밖으로 나간 점이 거의 없음 (불투명하거나 블라인드 · 시트가 있음)")
        else:
            c["glass"] = c["points"] >= max(500, 0.004 * total_points) and c["frames"] >= 3
            c["reason"] = (("RoomPlan 은 벽이라고 했지만" if c["kind"] == "wall" else "RoomPlan 이 벽을 못 찾은 자리인데")
                           + " LiDAR 가 지나감" if c["glass"] else "막힌 벽")


def pane_corners(c, poly, room):
    """유리판 꼭짓점 4개 (월드, m). 창 · 문은 RoomPlan 사각형, 벽은 LiDAR 가 지나간 범위"""
    a = poly[c["edge"]]
    b = np.roll(poly, -1, axis=0)[c["edge"]]
    length = float(np.linalg.norm(b - a))
    d = (b - a) / max(length, 1e-9)
    if c["kind"] in ("window", "door", "opening"):
        s0, s1 = c["s"] - c["width"] / 2, c["s"] + c["width"] / 2
        y0, y1 = c["y"] - c["height"] / 2, c["y"] + c["height"] / 2
        if c["kind"] == "window":           # RoomPlan 창 사각형은 창틀 · 위 벽까지 크게 잡히곤 해서 줄일 수 있으면 줄인다
            s0, s1, y0, y1 = shrink_to_glass(c, s0, s1, y0, y1, 1, 99)
    else:                                    # 벽 전체에서 시작해 막힌 부분만 걷어낸다
        s0, s1, y0, y1 = shrink_to_glass(c, 0.0, length, room["floorY"], room["ceilingY"], 2, 98)
    p0, p1 = a + d * s0, a + d * s1
    return [[float(p0[0]), float(y0), float(p0[1])], [float(p1[0]), float(y0), float(p1[1])],
            [float(p1[0]), float(y1), float(p1[1])], [float(p0[0]), float(y1), float(p0[1])]]


def glass_objects(panes, thickness):
    """유리판 사각형 → 3D 물체: 중심 · 폭 · 높이 · 두께 · yaw(+Y 축 반시계, 위에서 볼 때). 앱 SpaceResponse.objects 와 같은 규약"""
    objs = []
    for k, p in enumerate(panes):
        c = np.array(p["corners"], float)
        along = c[1] - c[0]
        width = float(np.linalg.norm(along))
        d = along / max(width, 1e-9)
        yaw = math.atan2(-d[2], d[0])                     # 물체의 +x(폭 방향)가 벽을 따라가게
        objs.append({"name": f"glass_{k}_{p['kind']}", "kind": p["kind"], "center": c.mean(0),
                     "along": d, "normal": np.array([math.sin(yaw), 0.0, math.cos(yaw)]),
                     "width": width, "height": float(c[3][1] - c[0][1]), "depth": float(thickness), "yaw": yaw})
    return objs


# 상자 꼭짓점 (−,−,−) (+,−,−) (+,+,−) (−,+,−) (−,−,+) (+,−,+) (+,+,+) (−,+,+) 과 바깥을 향한 면 (반시계)
_BOX_SIGNS = np.array([[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]], float)
_BOX_QUADS = [((0, 3, 2, 1), (0, 0, -1)), ((4, 5, 6, 7), (0, 0, 1)), ((0, 1, 5, 4), (0, -1, 0)),
              ((3, 7, 6, 2), (0, 1, 0)), ((0, 4, 7, 3), (-1, 0, 0)), ((1, 2, 6, 5), (1, 0, 0))]


def box_corners(o, local=False):
    """물체의 상자 꼭짓점 8개. local=True 면 물체 좌표(중심 원점), 아니면 월드"""
    half = np.array([o["width"], o["height"], o["depth"]]) / 2
    L = _BOX_SIGNS * half
    if local:
        return L
    return o["center"] + L[:, :1] * o["along"] + L[:, 1:2] * np.array([0.0, 1.0, 0.0]) + L[:, 2:] * o["normal"]


def _box_triangles(base=0):
    return [(base + q[0], base + q[1], base + q[2]) for q, _ in _BOX_QUADS] + \
           [(base + q[0], base + q[2], base + q[3]) for q, _ in _BOX_QUADS]


def write_glb(path, objs):
    """glTF 2.0 바이너리(.glb). 유리 하나 = 노드 하나(이름 · extras), 두께 있는 상자, 위치 · 회전은 노드에.
    좌표는 ARKit 월드 그대로(glTF 도 Y-up · 오른손 · 미터). 재질: 반투명 하늘색(#cfe7ff, 알파 0.35) + 약한 푸른 발광 —
    진짜 유리처럼 투과(transmission)시키면 뒤가 그대로 비쳐 구멍처럼 보여서, 앱 블록아웃 뷰의 유리처럼 '보이는 유리' 로 했다"""
    views, accessors, meshes, nodes, chunks = [], [], [], [], []
    offset = 0

    def view(data, target):
        nonlocal offset
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(data), "target": target})
        pad = (-len(data)) % 4
        chunks.append(data + b"\x00" * pad)
        offset += len(data) + pad
        return len(views) - 1

    for k, o in enumerate(objs):
        L = box_corners(o, local=True)
        pos = np.array([L[i] for q, _ in _BOX_QUADS for i in q], np.float32)          # 면마다 꼭짓점 4개 (평평한 법선)
        nrm = np.array([n for _, n in _BOX_QUADS for _ in range(4)], np.float32)
        idx = np.array([(4 * f, 4 * f + 1, 4 * f + 2, 4 * f, 4 * f + 2, 4 * f + 3) for f in range(6)], np.uint16).reshape(-1)
        vp, vn, vi = view(pos.tobytes(), 34962), view(nrm.tobytes(), 34962), view(idx.tobytes(), 34963)
        accessors += [{"bufferView": vp, "componentType": 5126, "count": len(pos), "type": "VEC3",
                       "min": [float(x) for x in pos.min(0)], "max": [float(x) for x in pos.max(0)]},
                      {"bufferView": vn, "componentType": 5126, "count": len(nrm), "type": "VEC3"},
                      {"bufferView": vi, "componentType": 5123, "count": len(idx), "type": "SCALAR"}]
        meshes.append({"name": o["name"], "primitives": [{"attributes": {"POSITION": 3 * k, "NORMAL": 3 * k + 1},
                                                          "indices": 3 * k + 2, "material": 0}]})
        nodes.append({"name": o["name"], "mesh": k,
                      "translation": [float(x) for x in o["center"]],
                      "rotation": [0.0, math.sin(o["yaw"] / 2), 0.0, math.cos(o["yaw"] / 2)],
                      "extras": {"category": "glass", "glassKind": o["kind"], "widthM": round(o["width"], 4),
                                 "heightM": round(o["height"], 4), "depthM": round(o["depth"], 4),
                                 "yawDeg": round(math.degrees(o["yaw"]), 3)}})
    gltf = {"asset": {"version": "2.0", "generator": "dulleobang glass_tools"},
            "scene": 0, "scenes": [{"name": "glass", "nodes": list(range(len(nodes)))}]}
    if objs:
        gltf.update({
            "nodes": nodes, "meshes": meshes, "accessors": accessors, "bufferViews": views,
            "buffers": [{"byteLength": offset}],
            "materials": [{"name": "glass", "alphaMode": "BLEND", "doubleSided": True,
                           "pbrMetallicRoughness": {"baseColorFactor": [0.624, 0.807, 1.0, 0.35],   # #cfe7ff (선형)
                                                    "metallicFactor": 0.0, "roughnessFactor": 0.1},
                           "emissiveFactor": [0.05, 0.11, 0.2]}]})
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((-len(js)) % 4)
    body = struct.pack("<I4s", len(js), b"JSON") + js
    if objs:
        bin_ = b"".join(chunks)
        body += struct.pack("<I4s", len(bin_), b"BIN\x00") + bin_
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + len(body)) + body)


def write_panes(folder, objs):
    """glass_panes.obj/.mtl/.ply — glass.glb 와 같은 유리 상자 (Blender · MeshLab 등 OBJ/PLY 쓰는 도구용)"""
    with open(os.path.join(folder, "glass_panes.mtl"), "w") as f:
        f.write("# dulleobang glass_tools: translucent glass (#cfe7ff, alpha 0.35)\nnewmtl glass\nKa 0 0 0\nKd 0.81 0.906 1.0\n"
                "Ks 0.6 0.6 0.6\nNs 120\nKe 0.12 0.2 0.32\nd 0.35\nTr 0.65\nillum 4\n")
    with open(os.path.join(folder, "glass_panes.obj"), "w") as f:
        f.write("# dulleobang glass_tools: glass boxes (ARKit world, meters, y-up)\nmtllib glass_panes.mtl\n")
        f.write(obj_glass_block(objs, relative=False))
    xyz = np.array([box_corners(o) for o in objs], np.float32).reshape(-1, 3)
    vert = np.empty(len(xyz), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
                                     ("red", "u1"), ("green", "u1"), ("blue", "u1"), ("alpha", "u1")])
    vert["x"], vert["y"], vert["z"] = xyz[:, 0], xyz[:, 1], xyz[:, 2]
    vert["red"], vert["green"], vert["blue"], vert["alpha"] = GLASS_RGBA
    tris = [t for k in range(len(objs)) for t in _box_triangles(8 * k)]
    farr = np.empty(len(tris), np.dtype([("n", "u1"), ("v", "<i4", (3,))]))
    farr["n"] = 3
    farr["v"] = np.array(tris, np.int32).reshape(-1, 3)
    header = ("ply\nformat binary_little_endian 1.0\ncomment dulleobang glass boxes: ARKit world, meters, y-up\n"
              f"element vertex {len(vert)}\nproperty float x\nproperty float y\nproperty float z\n"
              "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\n"
              f"element face {len(tris)}\nproperty list uchar int vertex_indices\nend_header\n")
    with open(os.path.join(folder, "glass_panes.ply"), "wb") as f:
        f.write(header.encode("ascii") + vert.tobytes() + farr.tobytes())


def obj_glass_block(objs, relative):
    out = []
    for k, o in enumerate(objs):
        out.append(f"o {o['name']}\nusemtl glass\n")
        out += [f"v {x:.5f} {y:.5f} {z:.5f}\n" for x, y, z in box_corners(o)]
        base = -8 if relative else 8 * k + 1
        out += [f"f {a + base} {b + base} {c + base}\n" for a, b, c in _box_triangles()]
    return "".join(out)


# ---------------------------------------------------------------- 프레임 처리

def unproject(p, raw_depth):
    """depth_tools 와 같은 방식: 깊이 픽셀 → 월드 (T_wc). 반환: 월드 점 (N,3), 픽셀 (ys, xs), 거리 (m)"""
    hd, wd = raw_depth.shape
    ys, xs = np.nonzero(raw_depth > 0)
    d = raw_depth[ys, xs].astype(np.float64) / 1000.0
    sx, sy = p["width"] / wd, p["height"] / hd
    K = p["K"]
    u = (xs + 0.5) * sx - 0.5
    v = (ys + 0.5) * sy - 0.5
    cam = np.stack([(u - K["cx"]) / K["fx"] * d, -(v - K["cy"]) / K["fy"] * d, -d, np.ones_like(d)], 0)
    T = np.array(p["T_wc"], dtype=np.float64)
    return (T @ cam)[:3].T, ys, xs, d


def dilate(mask):
    """3×3 팽창 — 유리 테두리의 '날아다니는' 깊이 픽셀까지 지운다"""
    m = np.pad(mask, 1)
    out = np.zeros_like(mask)
    for dy in (0, 1, 2):
        for dx in (0, 1, 2):
            out |= m[dy:dy + mask.shape[0], dx:dx + mask.shape[1]]
    return out


def project_polygon(p, corners, near=0.1):
    """월드 사각형 → 컬러 이미지 다각형 (카메라 앞 near m 로 자른 뒤 투영). 화면 뒤면 []"""
    Tcw = np.linalg.inv(np.array(p["T_wc"], dtype=np.float64))
    cam = [(Tcw @ np.array([*q, 1.0]))[:3] for q in corners]
    clipped = []
    for i in range(len(cam)):                       # z ≤ −near 쪽만 남기는 서덜랜드-호지먼
        P, Q = cam[i], cam[(i + 1) % len(cam)]
        pin, qin = P[2] <= -near, Q[2] <= -near
        if pin:
            clipped.append(P)
        if pin != qin:
            t = (-near - P[2]) / (Q[2] - P[2])
            clipped.append(P + t * (Q - P))
    K = p["K"]
    return [(K["cx"] + K["fx"] * q[0] / -q[2], K["cy"] - K["fy"] * q[1] / -q[2]) for q in clipped] if len(clipped) >= 3 else []


# ---------------------------------------------------------------- 메시 자르기 (PLY · OBJ)

_PLY_T = {"char": "i1", "int8": "i1", "uchar": "u1", "uint8": "u1", "short": "i2", "int16": "i2", "ushort": "u2",
          "uint16": "u2", "int": "i4", "int32": "i4", "uint": "u4", "uint32": "u4", "float": "f4", "float32": "f4",
          "double": "f8", "float64": "f8"}
_PLY_NAME = {"i1": "char", "u1": "uchar", "i2": "short", "u2": "ushort", "i4": "int", "u4": "uint", "f4": "float", "f8": "double"}


def read_ply(path):
    with open(path, "rb") as f:
        if f.readline().strip() != b"ply":
            raise ValueError("PLY 파일이 아닙니다")
        fmt, elements, comments = None, [], []
        while True:
            line = f.readline()
            if not line:
                raise ValueError("PLY 헤더가 끝나지 않습니다")
            t = line.decode("ascii", "replace").split()
            if not t:
                continue
            if t[0] == "format":
                fmt = t[1]
            elif t[0] in ("comment", "obj_info"):
                comments.append(line.decode("ascii", "replace").rstrip("\r\n"))
            elif t[0] == "element":
                elements.append({"name": t[1], "count": int(t[2]), "props": []})
            elif t[0] == "property":
                elements[-1]["props"].append(("list", t[2], t[3], t[4]) if t[1] == "list" else ("scalar", t[1], t[2]))
            elif t[0] == "end_header":
                break
        body = f.read()
    if fmt == "ascii":
        _ply_ascii(body, elements)
    elif fmt in ("binary_little_endian", "binary_big_endian"):
        _ply_binary(body, elements, "<" if fmt == "binary_little_endian" else ">")
    else:
        raise ValueError(f"모르는 PLY 형식: {fmt}")
    return fmt, elements, comments


def _ply_binary(body, elements, en):
    off = 0
    for el in elements:
        props, n = el["props"], el["count"]
        if all(p[0] == "scalar" for p in props):
            dt = np.dtype([(p[2], en + _PLY_T[p[1]]) for p in props])
            el["data"] = np.frombuffer(body, dt, n, off).copy()
            off += n * dt.itemsize
        elif len(props) == 1:
            _, ct, it, _ = props[0]
            ctd, itd = np.dtype(en + _PLY_T[ct]), np.dtype(en + _PLY_T[it])
            if n == 0:
                el["data"] = np.zeros((0, 3), np.int64)
                continue
            k = int(np.frombuffer(body, ctd, 1, off)[0])
            dt = np.dtype([("n", ctd), ("v", itd, (k,))])
            arr = np.frombuffer(body, dt, n, off) if off + n * dt.itemsize <= len(body) else None
            if arr is not None and np.all(arr["n"] == k):
                el["data"] = arr["v"].astype(np.int64)
                off += n * dt.itemsize
            else:                                            # 면마다 꼭짓점 수가 다르면 하나씩
                lists = []
                for _ in range(n):
                    c = int(np.frombuffer(body, ctd, 1, off)[0])
                    off += ctd.itemsize
                    lists.append(np.frombuffer(body, itd, c, off).astype(np.int64))
                    off += c * itd.itemsize
                el["data"] = lists
        else:
            raise ValueError(f"이 PLY 요소는 지원하지 않습니다: {el['name']} (리스트 + 다른 속성)")


def _ply_ascii(body, elements):
    rows_all = [r.split() for r in body.decode("ascii", "replace").splitlines() if r.strip()]
    i = 0
    for el in elements:
        rows = rows_all[i:i + el["count"]]
        i += el["count"]
        props = el["props"]
        if all(p[0] == "scalar" for p in props):
            dt = np.dtype([(p[2], _PLY_T[p[1]]) for p in props])
            arr = np.zeros(len(rows), dt)
            vals = np.array(rows, dtype=np.float64).reshape(len(rows), len(props)) if rows else np.zeros((0, len(props)))
            for j, p in enumerate(props):
                arr[p[2]] = vals[:, j]
            el["data"] = arr
        elif len(props) == 1:
            lists = [np.array(r[1:1 + int(r[0])], np.int64) for r in rows]
            el["data"] = np.stack(lists) if lists and len({len(x) for x in lists}) == 1 else lists
        else:
            raise ValueError(f"이 PLY 요소는 지원하지 않습니다: {el['name']}")


def write_ply_mesh(path, ascii_out, vert, faces, comments):
    vdt = vert.dtype
    head = ["ply", "format ascii 1.0" if ascii_out else "format binary_little_endian 1.0", *comments,
            "comment dulleobang glass_tools: faces outside the room removed", f"element vertex {len(vert)}"]
    head += [f"property {_PLY_NAME[vdt[n].str[1:]]} {n}" for n in vdt.names]
    head += [f"element face {len(faces)}", "property list uchar int vertex_indices", "end_header"]
    header = ("\n".join(head) + "\n").encode("ascii", "replace")          # PLY 헤더는 ASCII 만 (원본 주석의 한글은 ? 로)
    with open(path, "wb") as f:
        f.write(header)
        if ascii_out:
            lines = [" ".join(str(v) for v in row) for row in vert.tolist()]
            f.write(("\n".join(lines) + ("\n" if lines else "")).encode("ascii"))
            f.write("".join(f"{len(fc)} " + " ".join(map(str, fc)) + "\n" for fc in faces).encode("ascii"))
        else:
            f.write(vert.astype(vdt.newbyteorder("<")).tobytes())
            if isinstance(faces, np.ndarray) and faces.ndim == 2:
                fdt = np.dtype([("n", "u1"), ("v", "<i4", (faces.shape[1],))])
                arr = np.empty(len(faces), fdt)
                arr["n"], arr["v"] = faces.shape[1], faces
                f.write(arr.tobytes())
            else:
                for fc in faces:
                    f.write(np.array([len(fc)], np.uint8).tobytes() + np.asarray(fc, "<i4").tobytes())


def clip_mesh(path, outside_fn, objs, glass_mtl_src):
    """꼭짓점이 모두 방 밖인 면을 지운다. 결과: 같은 폴더의 <이름>_room.<확장자>. (지운 면 수, 전체 면 수, 출력 경로)"""
    base, ext = os.path.splitext(path)
    out_path = base + "_room" + ext
    ext = ext.lower()
    if ext == ".ply":
        fmt, elements, comments = read_ply(path)
        V = next(el for el in elements if el["name"] == "vertex")
        F = next((el for el in elements if el["name"] == "face"), None)
        xyz = np.stack([V["data"][k] for k in ("x", "y", "z")], 1).astype(np.float64)
        out_v = outside_fn(xyz)
        _check_frame(out_v)
        if F is None:                                        # 점군이면 방 안 점만
            write_ply_mesh(out_path, fmt == "ascii", V["data"][~out_v], [], comments)
            return int(out_v.sum()), len(out_v), out_path
        faces = F["data"]
        if isinstance(faces, np.ndarray):
            keep = ~np.all(out_v[faces], axis=1) if len(faces) else np.zeros(0, bool)
            kept = faces[keep]
            used = np.unique(kept)
            remap = np.full(len(xyz), -1, np.int64)
            remap[used] = np.arange(len(used))
            new_faces = remap[kept]
        else:
            keep = np.array([not np.all(out_v[fc]) for fc in faces], bool)
            kept = [fc for fc, k in zip(faces, keep) if k]
            used = np.unique(np.concatenate(kept)) if kept else np.zeros(0, np.int64)
            remap = np.full(len(xyz), -1, np.int64)
            remap[used] = np.arange(len(used))
            new_faces = [remap[fc] for fc in kept]
        write_ply_mesh(out_path, fmt == "ascii", V["data"][used], new_faces, comments)
        return int((~keep).sum()), len(keep), out_path
    if ext == ".obj":
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        xyz = np.array([[float(v) for v in ln.split()[1:4]] for ln in lines if ln.startswith("v ")], np.float64).reshape(-1, 3)
        out_v = outside_fn(xyz)
        _check_frame(out_v)
        res, nv, dropped, total = [], 0, 0, 0
        for ln in lines:
            if ln.startswith("v "):
                nv += 1
            elif ln.startswith("f "):
                total += 1
                idx = [int(tok.split("/")[0]) for tok in ln.split()[1:]]
                idx = [i - 1 if i > 0 else nv + i for i in idx]
                if idx and all(out_v[i] for i in idx):
                    dropped += 1
                    continue
            res.append(ln)
        if objs:
            res.append("# dulleobang glass_tools: glass boxes")
            res.append("mtllib glass_panes.mtl")
            res.append(obj_glass_block(objs, relative=True).rstrip("\n"))
            dst = os.path.join(os.path.dirname(out_path), "glass_panes.mtl")
            if os.path.abspath(dst) != os.path.abspath(glass_mtl_src):
                with open(glass_mtl_src) as s, open(dst, "w") as d:
                    d.write(s.read())
        with open(out_path, "w", encoding="utf-8") as f:
            f.write("\n".join(res) + "\n")
        return dropped, total, out_path
    raise ValueError("메시는 .ply 또는 .obj 만 됩니다 (glb 는 Blender 등에서 PLY · OBJ 로 바꿔서)")


def _check_frame(out_v):
    if len(out_v) and out_v.mean() > 0.9:
        raise ValueError(f"꼭짓점의 {100 * out_v.mean():.0f}% 가 방 밖입니다 — 메시 좌표가 촬영 좌표계(ARKit 월드, m)와 다른 것 같아 "
                         "자르지 않았습니다. 메시를 원점 이동 · 축 변환 없이 내보냈는지 확인해 주세요")


# ---------------------------------------------------------------- 실행

def main():
    ap = argparse.ArgumentParser(description="투명 유리 찾기 · 벽 밖 깊이 지우기 · 유리판 · 메시 자르기")
    ap.add_argument("capture", help="capture 폴더 또는 capture.zip")
    ap.add_argument("--margin", type=float, default=0.2, help="RoomPlan 벽에서 이만큼(m) 밖이면 '벽 밖'")
    ap.add_argument("--voxel", type=float, default=0.015, help="points_clean.ply 격자 크기 (m)")
    ap.add_argument("--thickness", type=float, default=0.01, help="유리 물체 두께 (m)")
    ap.add_argument("--mesh", action="append", default=[], help="방 밖을 잘라낼 메시 (.ply/.obj, 여러 번 가능)")
    ap.add_argument("--no-masks", action="store_true", help="glass_mask/ 생략")
    ap.add_argument("--no-ply", action="store_true", help="points_clean.ply 생략")
    args = ap.parse_args()

    cap = find_capture(args.capture)
    poses = _read_json(os.path.join(cap, "poses.json"))
    meta_path = os.path.join(cap, "meta.json")
    meta = _read_json(meta_path) if os.path.isfile(meta_path) else {}
    room = load_room(cap)
    poly, edge_wall, source = room_polygon(room)
    floor_y, ceil_y = room["floorY"], room["ceilingY"]
    cands = build_candidates(room, poly, edge_wall)
    init_grids(cands, poly, room)

    def outside(xyz, margin=args.margin):
        return ((signed_distance(poly, xyz[:, [0, 2]]) > margin)
                | (xyz[:, 1] < floor_y - margin - 0.1) | (xyz[:, 1] > ceil_y + margin + 0.1))

    # 1) 프레임마다: 벽 밖 점 찾기 · 어느 창/문/벽으로 나갔는지 · depth_clean 저장
    os.makedirs(os.path.join(cap, "depth_clean"), exist_ok=True)
    frames, removed_pix, total_points = [], {}, 0
    for p in poses:
        name = f"{p['frameId']:06d}"
        dpath = os.path.join(cap, "depth", name + ".png")
        if not os.path.isfile(dpath):
            continue
        raw = np.array(Image.open(dpath))
        cpath = os.path.join(cap, "confidence", name + ".png")
        conf = np.array(Image.open(cpath)) if os.path.isfile(cpath) else np.full(raw.shape, 2, np.uint8)
        world, ys, xs, d = unproject(p, raw)
        out = outside(world)
        # 통계는 믿을 만한 점(신뢰도 중간 이상 · 0.2–5 m)으로. 유리 너머 옆방의 바닥 · 천장도 '유리 너머' 증거라 높이로는 거르지 않는다
        good = (conf[ys, xs] >= 1) & (d > NEAR_M) & (d < FAR_M)
        sd = signed_distance(poly, world[:, [0, 2]])
        sel = good & (sd > args.margin)
        collect_solid(cands, poly, world[good & (np.abs(sd) <= 0.06)])
        total_points += int(good.sum())
        if sel.any():
            cam = np.array(p["T_wc"], dtype=np.float64)[:3, 3]
            owner, s, hy = attribute(cands, poly, cam, world[sel])
            for i, c in enumerate(cands):
                m = owner == i
                if m.any():
                    c["points"] += int(m.sum())
                    c["frames"] += int(m.sum() >= 0.02 * max(int(good.sum()), 1))
                    if c["kind"] in ("wall", "gap", "window"):
                        c["_s"].append(s[m])
                        c["_y"].append(hy[m])
        bad = np.zeros(raw.shape, bool)
        bad[ys[out], xs[out]] = True
        bad = dilate(bad) & (raw > 0)
        clean = raw.copy()
        clean[bad] = 0
        Image.fromarray(clean).save(os.path.join(cap, "depth_clean", name + ".png"))
        removed_pix[p["frameId"]] = bad
        frames.append({"frameId": p["frameId"], "removed": round(float(bad.sum() / max(int((raw > 0).sum()), 1)), 4),
                       "seeThroughPoints": int(sel.sum())})
    if not frames:
        sys.exit("depth/*.png 가 없습니다 (LiDAR 없는 기기로 촬영했거나 깊이가 저장되지 않음)")
    for c in cands:
        for k in ("_s", "_y"):
            c[k] = np.concatenate(c[k]) if c[k] else np.zeros(0)
    decide(cands, total_points)
    panes = [{"kind": c["kind"], "corners": pane_corners(c, poly, room)} for c in cands if c["glass"]]
    objs = glass_objects(panes, args.thickness)

    # 2) 유리 3D 물체 · 마스크 · 깨끗한 점군
    write_glb(os.path.join(cap, "glass.glb"), objs)
    write_panes(cap, objs)
    if not args.no_masks:
        os.makedirs(os.path.join(cap, "glass_mask"), exist_ok=True)
        for p in poses:
            if p["frameId"] not in removed_pix:
                continue
            W, H = p["width"], p["height"]
            mask = Image.new("L", (W, H), 0)
            draw = ImageDraw.Draw(mask)
            for pane in panes:
                poly2d = project_polygon(p, pane["corners"])
                if poly2d:
                    draw.polygon(poly2d, fill=255)
            lidar = Image.fromarray(removed_pix[p["frameId"]].astype(np.uint8) * 255).resize((W, H), Image.NEAREST)
            ImageChops.lighter(mask, lidar).convert("1").save(os.path.join(cap, "glass_mask", f"{p['frameId']:06d}.png"))
    n_points = None
    if not args.no_ply:
        pts, cols = [], []
        for p in poses:
            name = f"{p['frameId']:06d}"
            dpath = os.path.join(cap, "depth_clean", name + ".png")
            fpath = os.path.join(cap, "frames", name + ".jpg")
            if p["frameId"] not in removed_pix or not os.path.isfile(fpath):
                continue
            raw = np.array(Image.open(dpath))
            cpath = os.path.join(cap, "confidence", name + ".png")
            conf = np.array(Image.open(cpath)) if os.path.isfile(cpath) else np.full(raw.shape, 2, np.uint8)
            raw = np.where((conf == 2) & (raw > NEAR_M * 1000) & (raw < FAR_M * 1000), raw, 0)
            world, ys, xs, _ = unproject(p, raw)
            if len(world) == 0:
                continue
            hd, wd = raw.shape
            rgb = np.array(Image.open(fpath).convert("RGB").resize((wd, hd), Image.BILINEAR))
            pts.append(world.astype(np.float32))
            cols.append(rgb[ys, xs])
        if pts:
            xyz, rgb = np.concatenate(pts), np.concatenate(cols)
            _, idx = np.unique(np.floor(xyz / args.voxel).astype(np.int64), axis=0, return_index=True)
            write_ply(os.path.join(cap, "points_clean.ply"), xyz[idx], rgb[idx])
            n_points = int(len(idx))

    # 3) 이미 만든 메시 자르기
    meshes = []
    for mp in args.mesh:
        mp = os.path.abspath(os.path.expanduser(mp))
        try:
            dropped, total, out_path = clip_mesh(mp, outside, objs, os.path.join(cap, "glass_panes.mtl"))
            meshes.append({"mesh": mp, "out": out_path, "droppedFaces": dropped, "faces": total})
        except (ValueError, OSError) as e:
            meshes.append({"mesh": mp, "error": str(e)})

    # 4) glass.json + 요약
    see = sum(c["points"] for c in cands)
    names = {"window": "창", "door": "문", "opening": "통로", "wall": "벽", "gap": "벽이 빠진 자리"}
    out_c = []
    for c in cands:
        item = {k: v for k, v in c.items() if not k.startswith("_") and k not in ("s", "y")}
        item["share"] = round(c["points"] / max(total_points, 1), 4)
        if c["glass"]:
            item["pane"] = pane_corners(c, poly, room)
        out_c.append(item)
    summary = {
        "captureId": meta.get("captureId"),
        "about": "RoomPlan 벽 밖으로 나간 LiDAR 점 = 투명 유리(또는 열린 문) 너머. 좌표는 ARKit 월드(m, y-up). "
                 "seeThroughShare · share 의 분모 = 신뢰도 중간 이상 · 0.2–5 m 인 LiDAR 점 전체",
        "marginM": args.margin,
        "room": {"source": source, "polygonXZ": [[round(float(x), 3), round(float(z), 3)] for x, z in poly],
                 "floorY": round(float(floor_y), 3), "ceilingY": round(float(ceil_y), 3)},
        "seeThroughShare": round(see / max(total_points, 1), 4),
        "candidates": out_c,
        "objects": [{"objectId": f"glass-{k + 1}", "category": "glass", "glassKind": o["kind"], "node": o["name"],
                     "position": {a: round(float(v), 4) for a, v in zip("xyz", o["center"])},
                     "rotation": {"yaw": round(math.degrees(o["yaw"]), 3)},
                     "dimensions": {"width": round(o["width"], 4), "height": round(o["height"], 4), "depth": round(o["depth"], 4)},
                     "removable": False} for k, o in enumerate(objs)],
        "files": {"depthClean": "depth_clean/NNNNNN.png — depth/ 와 같은 형식, 벽 밖 픽셀만 0",
                  "points": None if args.no_ply else "points_clean.ply",
                  "glass": "glass.glb — 유리 하나 = 노드 하나(두께 있는 상자, 유리 재질), ARKit 월드 좌표",
                  "panes": "glass_panes.obj · glass_panes.mtl · glass_panes.ply — 같은 유리 상자 (OBJ/PLY)",
                  "masks": None if args.no_masks else "glass_mask/NNNNNN.png — 컬러 해상도, 흰색 = 유리 · 열린 문 너머"},
        "meshes": meshes,
        "frames": frames,
    }
    with open(os.path.join(cap, "glass.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)

    size = np.ptp(poly, axis=0)
    src = {"walls": "RoomPlan 벽", "floor": "RoomPlan 바닥", "hull": "벽 끝점 볼록 껍질"}[source]
    print(cap)
    print(f"  방 {size[0]:.2f} × {size[1]:.2f} m ({src} 기준) · 믿을 만한 LiDAR 점 중 {100 * summary['seeThroughShare']:.1f}% 가 벽 밖")
    for c in sorted(cands, key=lambda c: -c["points"]):
        if c["points"] == 0 and not c["glass"]:
            continue
        dims = f" {c['width']:.2f}×{c['height']:.2f} m" if "width" in c else ""
        print(f"    {names.get(c['kind'], c['kind'])}{dims}: 벽 밖 점 {c['points']:,} · {c['frames']}프레임"
              f" → {'유리판 만듦' if c['glass'] else '유리 아님'} ({c['reason']})")
    worst = max(frames, key=lambda f: f["removed"])
    print(f"  depth_clean/ {len(frames)}장 (평균 {100 * np.mean([f['removed'] for f in frames]):.1f}% · "
          f"최대 {100 * worst['removed']:.0f}% 지움, {worst['frameId']:06d})"
          + ("" if n_points is None else f" · points_clean.ply ({n_points:,}점)"))
    for o in objs:
        print(f"    유리 물체 {o['name']}: {o['width']:.2f} × {o['height']:.2f} × {o['depth']:.3f} m, "
              f"중심 ({o['center'][0]:.2f}, {o['center'][1]:.2f}, {o['center'][2]:.2f}), yaw {math.degrees(o['yaw']):.1f}°")
    print(f"  glass.glb (유리 물체 {len(objs)}개) · glass_panes.obj/.mtl/.ply" + ("" if args.no_masks else " · glass_mask/") + " · glass.json")
    for m in meshes:
        print(f"  {m['mesh']}: " + (f"오류 — {m['error']}" if "error" in m else
                                    f"면 {m['faces']:,}개 중 {m['droppedFaces']:,}개 지움 → {m['out']}"))


if __name__ == "__main__":
    main()
