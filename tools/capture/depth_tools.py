"""capture 폴더의 깊이(depth) · 신뢰도(confidence)를 사람이 볼 수 있는 히트맵과 데이터 파일로 만든다.

사용법 (Mac 터미널):
  python3 tools/capture/depth_tools.py ~/Downloads/capture          # 압축 푼 폴더
  python3 tools/capture/depth_tools.py ~/Downloads/capture.zip      # zip 도 됨 (옆에 풀어서 처리)
  옵션: --npy (프레임별 float32 미터 배열도 저장)  --no-ply (점군 생략)  --near 0.2 --far 5.0 (히트맵 범위 m)

capture 폴더 안에 만드는 것:
  depth_vis/000000.jpg       깊이 히트맵: 가까움 파랑 → 멂 빨강 (0.2–5 m 고정이라 프레임끼리 색 비교 가능), 검정 = 측정 없음
  confidence_vis/000000.png  신뢰도: 빨강 낮음 · 노랑 중간 · 초록 높음
  depth.json                 파일 형식 설명 + 프레임별 요약 (최소 · 중앙 · 최대 거리 m, 측정된 픽셀 비율, 신뢰도 비율)
  points.ply                 모든 프레임의 깊이를 카메라 위치로 합친 컬러 점군 (신뢰도 높음만, 1.5 cm 격자로 정리)
                             → MeshLab · Blender · CloudCompare 로 열 수 있고, 3DGS 초기 점군으로도 쓸 수 있다
  depth_m/000000.npy         (--npy) float32 미터, 0 = 측정 없음

원본 depth/*.png (uint16, 밀리미터) 와 confidence/*.png (0/1/2) 는 그대로 둔다. 히트맵은 색으로 바꾸면서 정확한 값이
사라지므로 보기용이고, AI 는 원본을 쓴다. 원본을 파이썬에서 읽는 법:
  depth_m = np.array(Image.open("depth/000000.png")).astype(np.float32) / 1000   # 미터, 0 = 없음
필요: pip install numpy pillow
"""
import argparse
import json
import os
import sys
import zipfile

import numpy as np
from PIL import Image

CONF_COLORS = np.array([[230, 70, 70], [245, 190, 50], [60, 180, 90]], np.uint8)   # 낮음 · 중간 · 높음


def turbo(x):
    """Google Turbo 컬러맵 (다항식 근사). x: 0…1 → uint8 RGB"""
    x = np.clip(x, 0.0, 1.0)
    r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
    g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
    b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
    return (np.clip(np.stack([r, g, b], -1), 0, 1) * 255 + 0.5).astype(np.uint8)


def find_capture(path):
    """폴더 · zip 어느 쪽이든 poses.json 이 있는 capture 폴더를 찾는다"""
    path = os.path.abspath(os.path.expanduser(path))
    if path.lower().endswith(".zip"):
        out = os.path.splitext(path)[0]
        if not os.path.isdir(out):
            with zipfile.ZipFile(path) as z:
                z.extractall(out)
        path = out
    for cand in (path, os.path.join(path, "capture")):
        if os.path.isfile(os.path.join(cand, "poses.json")):
            return cand
    sys.exit(f"poses.json 이 있는 capture 폴더를 찾지 못했습니다: {path}")


def load_depth_m(p):
    return np.array(Image.open(p)).astype(np.float32) / 1000.0


def write_ply(path, xyz, rgb):
    n = len(xyz)
    vert = np.empty(n, dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("red", "u1"), ("green", "u1"), ("blue", "u1")])
    vert["x"], vert["y"], vert["z"] = xyz[:, 0], xyz[:, 1], xyz[:, 2]
    vert["red"], vert["green"], vert["blue"] = rgb[:, 0], rgb[:, 1], rgb[:, 2]
    header = ("ply\nformat binary_little_endian 1.0\n"
              "comment dulleobang capture: ARKit world, meters, y-up\n"
              f"element vertex {n}\n"
              "property float x\nproperty float y\nproperty float z\n"
              "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n")
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(vert.tobytes())


def main():
    ap = argparse.ArgumentParser(description="capture 깊이/신뢰도 → 히트맵 · depth.json · points.ply")
    ap.add_argument("capture", help="capture 폴더 또는 capture.zip")
    ap.add_argument("--near", type=float, default=0.2, help="히트맵 가까운 끝 (m)")
    ap.add_argument("--far", type=float, default=5.0, help="히트맵 먼 끝 (m)")
    ap.add_argument("--voxel", type=float, default=0.015, help="점군 격자 크기 (m)")
    ap.add_argument("--npy", action="store_true", help="depth_m/*.npy (float32 미터) 도 저장")
    ap.add_argument("--no-ply", action="store_true", help="points.ply 생략")
    args = ap.parse_args()

    cap = find_capture(args.capture)
    poses = json.load(open(os.path.join(cap, "poses.json")))
    meta_path = os.path.join(cap, "meta.json")
    meta = json.load(open(meta_path)) if os.path.isfile(meta_path) else {}
    for sub in ["depth_vis", "confidence_vis"] + (["depth_m"] if args.npy else []):
        os.makedirs(os.path.join(cap, sub), exist_ok=True)

    frames_info, pts, cols = [], [], []
    depth_size = color_size = None
    for p in poses:
        name = f"{p['frameId']:06d}"
        dpath = os.path.join(cap, "depth", name + ".png")
        if not os.path.isfile(dpath):
            continue
        m = load_depth_m(dpath)
        hd, wd = m.shape
        depth_size = [wd, hd]
        color_size = [p["width"], p["height"]]
        valid = m > 0
        info = {"frameId": p["frameId"], "depth": f"depth/{name}.png", "preview": f"depth_vis/{name}.jpg",
                "valid": round(float(valid.mean()), 4)}
        if valid.any():
            v = m[valid]
            info.update(minM=round(float(v.min()), 3), medianM=round(float(np.median(v)), 3), maxM=round(float(v.max()), 3))

        # 깊이 히트맵 (보기용)
        vis = turbo((m - args.near) / (args.far - args.near))
        vis[~valid] = 0
        Image.fromarray(vis).save(os.path.join(cap, "depth_vis", name + ".jpg"), quality=92)
        if args.npy:
            np.save(os.path.join(cap, "depth_m", name + ".npy"), m.astype(np.float32))

        # 신뢰도 (보기용 색 + 비율)
        cpath = os.path.join(cap, "confidence", name + ".png")
        conf = None
        if os.path.isfile(cpath):
            conf = np.clip(np.array(Image.open(cpath)).astype(np.int32), 0, 2)
            Image.fromarray(CONF_COLORS[conf]).save(os.path.join(cap, "confidence_vis", name + ".png"))
            counts = np.bincount(conf.ravel(), minlength=3) / conf.size
            info["confidence"] = {"low": round(float(counts[0]), 4), "medium": round(float(counts[1]), 4),
                                  "high": round(float(counts[2]), 4)}
            info["confidencePreview"] = f"confidence_vis/{name}.png"
        frames_info.append(info)

        # 점군: 깊이 픽셀 → 카메라 좌표 (x 오른쪽, y 위, -z 앞) → 월드 (T_wc)
        if not args.no_ply:
            fpath = os.path.join(cap, "frames", name + ".jpg")
            keep = valid & (m > args.near) & (m < args.far)
            if conf is not None:
                keep &= conf == 2
            if keep.any() and os.path.isfile(fpath):
                sx, sy = p["width"] / wd, p["height"] / hd
                K = p["K"]
                ys, xs = np.nonzero(keep)
                d = m[ys, xs]
                u = (xs + 0.5) * sx - 0.5
                v = (ys + 0.5) * sy - 0.5
                cam = np.stack([(u - K["cx"]) / K["fx"] * d, -(v - K["cy"]) / K["fy"] * d, -d, np.ones_like(d)], 0)
                T = np.array(p["T_wc"], dtype=np.float64)
                pts.append((T @ cam)[:3].T.astype(np.float32))
                rgb = np.array(Image.open(fpath).convert("RGB").resize((wd, hd), Image.BILINEAR))
                cols.append(rgb[ys, xs])

    if not frames_info:
        sys.exit("depth/*.png 가 없습니다 (LiDAR 없는 기기로 촬영했거나 깊이가 저장되지 않음)")

    ref = next(p for p in poses if os.path.isfile(os.path.join(cap, "depth", f"{p['frameId']:06d}.png")))
    scale = [depth_size[0] / color_size[0], depth_size[1] / color_size[1]]
    summary = {
        "captureId": meta.get("captureId"),
        "files": {
            "depth": "depth/NNNNNN.png — uint16 PNG, 밀리미터, 0 = 측정 없음 (AI 가 쓰는 원본). 파이썬: np.array(Image.open(p)) / 1000 → 미터",
            "depthPreview": f"depth_vis/NNNNNN.jpg — Turbo 히트맵, 파랑 {args.near} m → 빨강 {args.far} m, 검정 = 없음 (보기용)",
            "confidence": "confidence/NNNNNN.png — uint8, 0 낮음 · 1 중간 · 2 높음 (원본)",
            "confidencePreview": "confidence_vis/NNNNNN.png — 빨강 낮음 · 노랑 중간 · 초록 높음 (보기용)",
            "points": None if args.no_ply else "points.ply — 신뢰도 높은 깊이를 모두 합친 컬러 점군, ARKit 월드 좌표(m, y-up)",
        },
        "depthSize": depth_size,
        "colorSize": color_size,
        "colorToDepthScale": scale,
        "depthIntrinsicsExample": {k: round(ref["K"][k] * (scale[0] if k in ("fx", "cx") else scale[1]), 4)
                                   for k in ("fx", "fy", "cx", "cy")},
        "note": "프레임마다 K(poses.json, 컬러 해상도 기준)에 colorToDepthScale 을 곱하면 깊이 해상도의 intrinsics. "
                "깊이는 광선 거리가 아니라 카메라 z 축 거리(미터).",
        "previewRangeM": [args.near, args.far],
        "frameCount": len(frames_info),
        "frames": frames_info,
    }

    if pts:
        xyz = np.concatenate(pts)
        rgb = np.concatenate(cols)
        key = np.floor(xyz / args.voxel).astype(np.int64)
        _, idx = np.unique(key, axis=0, return_index=True)
        xyz, rgb = xyz[idx], rgb[idx]
        write_ply(os.path.join(cap, "points.ply"), xyz, rgb)
        lo, hi = xyz.min(0), xyz.max(0)
        summary["pointCloud"] = {"file": "points.ply", "points": int(len(xyz)), "voxelM": args.voxel,
                                 "boundsMinM": [round(float(x), 3) for x in lo], "boundsMaxM": [round(float(x), 3) for x in hi]}

    with open(os.path.join(cap, "depth.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)

    meds = [f["medianM"] for f in frames_info if "medianM" in f]
    highs = [f["confidence"]["high"] for f in frames_info if "confidence" in f]
    print(f"{cap}")
    print(f"  프레임 {len(frames_info)}장 · 깊이 {depth_size[0]}×{depth_size[1]} · 중앙 거리 {np.median(meds):.2f} m"
          + (f" · 신뢰도 높음 평균 {100 * np.mean(highs):.0f}%" if highs else ""))
    print("  depth_vis/ · confidence_vis/ · depth.json" + ("" if args.no_ply else f" · points.ply ({summary.get('pointCloud', {}).get('points', 0):,}점)")
          + (" · depth_m/" if args.npy else ""))


if __name__ == "__main__":
    main()
