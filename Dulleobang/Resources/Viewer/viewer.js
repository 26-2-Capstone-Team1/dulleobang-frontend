// 둘러방 3D 뷰어 — three.js + @mkkellogg/gaussian-splats-3d
// 좌표계: 미터, Y-up, 오른손 (ARKit 월드와 동일). yaw: +Y 축 기준 반시계(위에서 볼 때), 도(°).
// Swift → JS : window.DV.*        JS → Swift : webkit.messageHandlers.dulleobang.postMessage({ type, … })
// 충돌 판정은 Swift(CollisionChecker)가 한다. JS 는 렌더링·입력만 담당하고 결과 색만 받아서 칠한다.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { PLYLoader } from 'three/addons/loaders/PLYLoader.js';
import { CSS2DRenderer, CSS2DObject } from 'three/addons/renderers/CSS2DRenderer.js';

const post = window.__dvPost;
const EYE = 1.5, SNAP_POS = 0.05, D2R = Math.PI / 180;
const GREEN = 0x46d36a, RED = 0xff5a5a, GREY = 0xb0b0b0;
const OWN = { PERSONAL: RED, RENTAL_OPTION: GREEN };
const ownColor = (t) => OWN[t] ?? GREY;
const clamp = (v, a, b) => Math.min(Math.max(v, a), b);
const snap = (v, s) => Math.round(v / s) * s;
const fmtDims = (d) => `${d.width.toFixed(2)}×${d.depth.toFixed(2)}×${d.height.toFixed(2)}`;

// ---------------------------------------------------------------- renderer / scene
const stage = document.getElementById('stage');
const renderer = new THREE.WebGLRenderer({ antialias: false, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setSize(innerWidth, innerHeight);
renderer.outputColorSpace = THREE.SRGBColorSpace;
stage.appendChild(renderer.domElement);
const cvs = renderer.domElement;

const labels = new CSS2DRenderer();
labels.setSize(innerWidth, innerHeight);
Object.assign(labels.domElement.style, { position: 'absolute', top: '0', left: '0', pointerEvents: 'none' });
stage.appendChild(labels.domElement);

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x101214);
scene.add(new THREE.HemisphereLight(0xffffff, 0x444444, 2.2));
const sun = new THREE.DirectionalLight(0xffffff, 1.4);
sun.position.set(2, 6, 3);
scene.add(sun);

const camera = new THREE.PerspectiveCamera(65, innerWidth / innerHeight, 0.05, 100);
camera.position.set(0, EYE, 3);
const controls = new OrbitControls(camera, cvs);
Object.assign(controls, { enableDamping: true, enabled: false, minPolarAngle: 0, maxPolarAngle: 80 * D2R, minDistance: 1, maxDistance: 30 });

const world = new THREE.Group(), overlay = new THREE.Group(), furnGroup = new THREE.Group();
scene.add(world, overlay, furnGroup);

let room = null;            // { floorY, ceilingY, bboxMin, bboxMax, walls, doors, windows }
let mode = 'walk';          // walk (1인칭) | overview (평면뷰: 위에서 내려다봄, 기울이면 입체)
let splat = null;
let overlayOn = true;
const objectViz = new Map(); // objectId → { lines, label }
const objectMeshes = new Map(); // objectId → 블록아웃 모형 (스캔 파일이 없을 때)
const furn = new Map();      // furnitureId → { root, pad, lines, label, dims }
let selected = null;

// ---------------------------------------------------------------- helpers
function lineMat(color, opacity = 0.9) {
  return new THREE.LineBasicMaterial({ color, transparent: true, opacity, depthTest: false });
}
function seg(a, b, color, opacity) {
  const l = new THREE.Line(new THREE.BufferGeometry().setFromPoints([a, b]), lineMat(color, opacity));
  l.renderOrder = 10;
  return l;
}
function box(d, color) {
  const l = new THREE.LineSegments(new THREE.EdgesGeometry(new THREE.BoxGeometry(d.width, d.height, d.depth)), lineMat(color));
  l.renderOrder = 10;
  return l;
}
function label(text, cls = '') {
  const el = document.createElement('div');
  el.className = 'lbl ' + cls;
  el.textContent = text;
  return new CSS2DObject(el);
}
function disposeTree(o) {
  o.traverse((c) => {
    c.geometry?.dispose?.();
    const m = c.material;
    if (Array.isArray(m)) m.forEach((x) => x.dispose()); else m?.dispose?.();
  });
}
function removeLabels(o) {
  o.traverse((c) => { if (c.isCSS2DObject && c.element.parentNode) c.element.parentNode.removeChild(c.element); });
}
function clearGroup(g) {
  removeLabels(g);
  while (g.children.length) {
    const c = g.children[0];
    g.remove(c);
    if (c !== splat) disposeTree(c);
  }
}
function roomCenter() {
  return new THREE.Vector3((room.bboxMin.x + room.bboxMax.x) / 2, room.floorY, (room.bboxMin.z + room.bboxMax.z) / 2);
}

// ---------------------------------------------------------------- scene loading
async function loadScene(p) {
  try {
    clearAll();
    room = p.room;
    if (p.splatUrl) {
      const GS = await import('@mkkellogg/gaussian-splats-3d');
      // WKWebView 는 cross-origin isolation 이 아니므로 SharedArrayBuffer 를 쓰지 않는다
      splat = new GS.DropInViewer({ sharedMemoryForWorkers: false, gpuAcceleratedSort: false, dynamicScene: false });
      await splat.addSplatScene(p.splatUrl, {
        showLoadingUI: false, progressiveLoad: false, splatAlphaRemovalThreshold: 5,
        onProgress: (pct) => post({ type: 'progress', value: (Number(pct) || 0) / 100 }),
      });
      world.add(splat);
    } else if (p.pointsUrl) {
      const geo = await new PLYLoader().loadAsync(p.pointsUrl, (ev) => {
        if (ev.total) post({ type: 'progress', value: ev.loaded / ev.total });
      });
      const mat = new THREE.PointsMaterial({ size: 0.012, sizeAttenuation: true, vertexColors: geo.hasAttribute('color') });
      world.add(new THREE.Points(geo, mat));
    } else {
      // 스캔 파일 없이 벽·문·창·가구 정보만 있을 때 (데모 데이터 · RoomPlan 구조만 올라온 매물)
      buildBlockout(p.objects || [], new Set(p.removed || []), p.glass || []);
    }
    buildGlass(p.glass || []);
    buildOverlay(p.objects || [], new Set(p.removed || []), p.glass || []);
    setOverlay(overlayOn);
    setMode(mode);
    post({ type: 'loaded' });
  } catch (e) {
    post({ type: 'error', message: '3D 장면 로딩 실패: ' + (e?.message || e) });
  }
}

function clearAll() {
  for (const id of [...furn.keys()]) removeFurniture(id);
  clearGroup(overlay);
  clearGroup(world);
  objectViz.clear();
  objectMeshes.clear();
  if (splat) { try { splat.dispose?.(); } catch (_) {} splat = null; }
}

// ---------------------------------------------------------------- glass (서버가 LiDAR 로 찾은 투명 유리)
// LiDAR 레이저는 맑은 유리를 통과해서 스캔(3DGS · 점 · 메시)에는 유리 자리가 비어 있다. 서버(tools/capture/glass_tools.py)가
// 그 자리를 찾아 SpaceResponse.glass 로 보내 준다: position = 중심, rotation.yaw, dimensions(width · height · depth).
const GLASS_KO = { window: '유리창', door: '유리문', wall: '유리벽', gap: '유리벽' };

// RoomPlan 창 · 문과 같은 자리에 서버가 찾은 유리가 있는가 (있으면 RoomPlan 상자 대신 실제 크기의 유리를 그린다)
function nearGlass(o, glassList) {
  return glassList.some((g) =>
    Math.hypot(g.position.x - o.position.x, g.position.z - o.position.z) < Math.max(0.5, o.dimensions.width / 2) &&
    Math.abs(g.position.y - o.position.y) < Math.max(0.5, o.dimensions.height / 2));
}

function buildGlass(glassList) {
  for (const g of glassList) {
    const dm = g.dimensions;
    const geo = new THREE.BoxGeometry(Math.max(dm.width, 0.01), Math.max(dm.height, 0.01), Math.max(dm.depth || 0.01, 0.01));
    const pane = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({
      color: 0xcfe7ff, emissive: 0x86b9e6, emissiveIntensity: 0.3, roughness: 0.1, metalness: 0,
      transparent: true, opacity: 0.35, depthWrite: false, side: THREE.DoubleSide,
    }));
    pane.renderOrder = 5;                       // 스캔 · 벽 다음에 겹쳐 그린다 (뒤가 비쳐 보이게)
    const rim = new THREE.LineSegments(new THREE.EdgesGeometry(geo),
      new THREE.LineBasicMaterial({ color: 0xe6f4ff, transparent: true, opacity: 0.85 }));
    const grp = new THREE.Group();
    grp.add(pane, rim);
    grp.position.set(g.position.x, g.position.y, g.position.z);
    grp.rotation.y = (g.rotation?.yaw ?? 0) * D2R;
    world.add(grp);
  }
}

function buildOverlay(objects, removed, glassList = []) {
  const r = room, h = r.ceilingY - r.floorY;
  for (const w of r.walls || []) {
    const a = new THREE.Vector3(w.from[0], r.floorY, w.from[1]);
    const b = new THREE.Vector3(w.to[0], r.floorY, w.to[1]);
    const up = new THREE.Vector3(0, w.height ?? h, 0);
    overlay.add(seg(a, b, 0xffffff, 0.9), seg(a.clone().add(up), b.clone().add(up), 0xffffff, 0.35));
    const l = label(`${a.distanceTo(b).toFixed(2)} m`);
    l.position.copy(a).lerp(b, 0.5).setY(r.floorY + 0.05);
    overlay.add(l);
  }
  const addOpening = (o, color, text, cls) => {
    const lines = box(o.dimensions, color);
    lines.position.set(o.position.x, o.position.y, o.position.z);
    lines.rotation.y = (o.rotation?.yaw ?? 0) * D2R;
    const l = label(`${text} ${o.dimensions.width.toFixed(2)} m`, cls);
    l.position.set(o.position.x, o.position.y + o.dimensions.height / 2 + 0.05, o.position.z);
    overlay.add(lines, l);
  };
  for (const o of r.doors || []) if (!nearGlass(o, glassList)) addOpening(o, 0xff9933, '문', 'door');
  for (const o of r.windows || []) if (!nearGlass(o, glassList)) addOpening(o, 0x66ccff, '창문', 'window');
  for (const g of glassList) addOpening(g, 0x9fe3ff, GLASS_KO[g.glassKind] ?? '유리', 'window');

  const c = roomCenter();
  const top = label(`층고 ${h.toFixed(2)} m`);
  top.position.set(c.x, r.ceilingY, c.z);
  overlay.add(top);

  for (const o of objects) {
    const lines = box(o.dimensions, ownColor(o.ownershipType));
    lines.position.set(o.position.x, o.position.y, o.position.z);
    lines.rotation.y = (o.rotation?.yaw ?? 0) * D2R;
    const lb = label(`${koName(o.category)}\n${fmtDims(o.dimensions)}`, 'obj');
    lb.position.set(o.position.x, o.position.y + o.dimensions.height / 2 + 0.08, o.position.z);
    overlay.add(lines, lb);
    objectViz.set(o.objectId, { lines, label: lb });
    if (removed.has(o.objectId)) { lines.visible = false; lb.visible = false; }
  }
}

// ---------------------------------------------------------------- blockout (단순 3D 모형)
// 스캔(3DGS·포인트) 없이 roomGeometry(벽·문·창) + objects(가구 상자)만으로 방을 그린다.
const KO = {
  bed: '침대', table: '책상', desk: '책상', chair: '의자', sofa: '소파', storage: '수납장', closet: '옷장', wardrobe: '옷장',
  refrigerator: '냉장고', washerDryer: '세탁기', sink: '싱크대', stove: '가스레인지', oven: '오븐', dishwasher: '식기세척기',
  toilet: '변기', bathtub: '욕조', television: 'TV', fireplace: '벽난로', stairs: '계단', other: '가구',
};
const koName = (c) => KO[c] ?? c ?? '가구';

function stdMat(color, extra = {}) {
  return new THREE.MeshStandardMaterial({ color, roughness: 0.85, metalness: 0, ...extra });
}

// 바닥 나무결 (캔버스로 그린 반복 텍스처)
function woodTexture() {
  const c = document.createElement('canvas');
  c.width = 256; c.height = 256;
  const g = c.getContext('2d');
  const tones = ['#d9c09d', '#d0b48e', '#ddc6a6', '#cdb08a'];
  for (let i = 0; i < 4; i++) {
    const x0 = i * 64;
    g.fillStyle = tones[i];
    g.fillRect(x0, 0, 64, 256);
    g.fillStyle = 'rgba(120,85,50,0.10)';
    for (let k = 0; k < 16; k++) g.fillRect(x0 + ((k * 37 + i * 11) % 64), 0, 1, 256);   // 나뭇결
    g.fillStyle = 'rgba(90,60,35,0.35)';
    g.fillRect(x0, 0, 1.5, 256);                                                     // 판자 이음새
    g.fillRect(x0, (i * 97) % 256, 64, 1.5);
  }
  const t = new THREE.CanvasTexture(c);
  t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.colorSpace = THREE.SRGBColorSpace;
  t.anisotropy = 4;
  return t;
}

function buildBlockout(objects, removed, glassList = []) {
  const r = room, h = r.ceilingY - r.floorY;
  const w = r.bboxMax.x - r.bboxMin.x, d = r.bboxMax.z - r.bboxMin.z;
  const c = roomCenter();

  const tex = woodTexture();
  tex.repeat.set(w / 0.72, d / 1.2);
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(w, d), stdMat(0xffffff, { map: tex, roughness: 0.75 }));
  floor.rotation.x = -Math.PI / 2;
  floor.position.set(c.x, r.floorY, c.z);
  world.add(floor);

  const ceiling = new THREE.Mesh(new THREE.PlaneGeometry(w, d), stdMat(0xfbfbfa));
  ceiling.rotation.x = Math.PI / 2;            // 아래를 향한 면만 보인다 (위에서 볼 때는 안 보임)
  ceiling.position.set(c.x, r.ceilingY, c.z);
  world.add(ceiling);

  const wallMat = stdMat(0xf1eee8, { roughness: 0.95 });
  const T = 0.1;
  for (const wl of r.walls || []) {
    const ax = wl.from[0], az = wl.from[1], bx = wl.to[0], bz = wl.to[1];
    const len = Math.hypot(bx - ax, bz - az);
    if (len < 1e-3) continue;
    const dx = (bx - ax) / len, dz = (bz - az) / len;
    const mx = (ax + bx) / 2, mz = (az + bz) / 2;
    let nx = -dz, nz = dx;                                   // from→to 는 실내면 → 두께는 바깥쪽으로
    if (nx * (mx - c.x) + nz * (mz - c.z) < 0) { nx = -nx; nz = -nz; }
    const wh = wl.height ?? h;
    const m = new THREE.Mesh(new THREE.BoxGeometry(len + T, wh, T), wallMat);
    m.position.set(mx + nx * T / 2, r.floorY + wh / 2, mz + nz * T / 2);
    m.rotation.y = Math.atan2(-dz, dx);                      // 로컬 x 축을 벽 방향으로 (yaw 규약과 동일)
    world.add(m);
    // 걸레받이
    const base = new THREE.Mesh(new THREE.BoxGeometry(len, 0.07, 0.012), stdMat(0xe2ddd4));
    base.position.set(mx - nx * 0.006, r.floorY + 0.035, mz - nz * 0.006);
    base.rotation.y = m.rotation.y;
    world.add(base);
  }

  const opening = (o, mat, extraDepth) => {
    const dm = o.dimensions;
    const m = new THREE.Mesh(new THREE.BoxGeometry(dm.width, dm.height, Math.max(dm.depth ?? 0.1, 0.1) + extraDepth), mat);
    m.position.set(o.position.x, o.position.y, o.position.z);
    m.rotation.y = (o.rotation?.yaw ?? 0) * D2R;
    world.add(m);
    return m;
  };
  const doorMat = stdMat(0xc49b72, { roughness: 0.7 });
  for (const o of r.doors || []) {
    if (nearGlass(o, glassList)) continue;      // 서버가 유리문으로 찾은 문은 buildGlass 가 유리로 그린다
    const door = opening(o, doorMat, 0.04);
    const knob = new THREE.Mesh(new THREE.SphereGeometry(0.03, 12, 8), stdMat(0xd8d8dc, { metalness: 0.6, roughness: 0.3 }));
    knob.position.set(o.dimensions.width / 2 - 0.1, 0.0, 0);
    knob.scale.set(1, 1, 3.2);
    door.add(knob);
  }
  const glass = stdMat(0xcfe7ff, { emissive: 0x86b9e6, emissiveIntensity: 0.55, roughness: 0.15, transparent: true, opacity: 0.9 });
  for (const o of r.windows || []) {
    if (nearGlass(o, glassList)) continue;      // 서버가 찾은 유리(실제 유리 크기)가 있으면 buildGlass 가 그린다
    opening(o, glass, 0.03);
    const frame = new THREE.LineSegments(
      new THREE.EdgesGeometry(new THREE.BoxGeometry(o.dimensions.width, o.dimensions.height, 0.16)),
      new THREE.LineBasicMaterial({ color: 0xffffff }));
    frame.position.set(o.position.x, o.position.y, o.position.z);
    frame.rotation.y = (o.rotation?.yaw ?? 0) * D2R;
    world.add(frame);
  }

  for (const o of objects) {
    const g = furnitureModel(o.category, o.dimensions, false);
    g.position.set(o.position.x, o.position.y - o.dimensions.height / 2, o.position.z);   // 상자 중심 → 바닥 중심
    g.rotation.y = (o.rotation?.yaw ?? 0) * D2R;
    g.visible = !removed.has(o.objectId);
    world.add(g);
    objectMeshes.set(o.objectId, g);
  }
}

// 가구 종류 → 단순 모형. 원점 = 바닥 중심, 가로(width)=x, 깊이(depth)=z, 등받이·머리판은 -z 쪽.
function normKind(k) {
  k = String(k || '').toLowerCase();
  if (k.includes('bed')) return 'bed';
  if (k.includes('sofa') || k.includes('couch')) return 'sofa';
  if (k === 'table' || k.includes('desk')) return 'table';
  if (k.includes('chair')) return 'chair';
  if (k.includes('storage') || k.includes('closet') || k.includes('wardrobe') || k.includes('cabinet') || k.includes('shelf')) return 'storage';
  if (k.includes('refrigerator') || k.includes('fridge')) return 'fridge';
  if (k.includes('dishwasher') || k.includes('sink') || k.includes('stove') || k.includes('oven')) return 'counter';
  if (k.includes('washer') || k.includes('dryer')) return 'washer';
  if (k.includes('toilet')) return 'toilet';
  if (k.includes('bathtub')) return 'bathtub';
  if (k.includes('television') || k === 'tv') return 'tv';
  return 'box';
}

function furnitureModel(kind, dm, mine) {
  const g = new THREE.Group();
  const W = Math.max(dm.width, 0.05), H = Math.max(dm.height, 0.05), D = Math.max(dm.depth, 0.05);
  const C = mine
    ? { wood: 0xa8c89d, woodDark: 0x82a978, fabric: 0x96c08a, fabricDark: 0x7fae73, sheet: 0xf4f9f1, blanket: 0x6a9a5e, light: 0xe1eed9, dark: 0x4c7343, metal: 0xd3e4cc }
    : { wood: 0xc8a27c, woodDark: 0x9c7552, fabric: 0x97a3ae, fabricDark: 0x86919c, sheet: 0xf6f5f1, blanket: 0x7f9cc4, light: 0xebe7df, dark: 0x3d4046, metal: 0xd7dade };
  const part = (w, h, d, x, y, z, color, extra) => {   // (x, y, z) = 바닥 중심
    const m = new THREE.Mesh(new THREE.BoxGeometry(Math.max(w, 0.01), Math.max(h, 0.01), Math.max(d, 0.01)), stdMat(color, extra));
    m.position.set(x, y + Math.max(h, 0.01) / 2, z);
    g.add(m);
    return m;
  };
  switch (normKind(kind)) {
    case 'bed': {
      const top = Math.min(0.55, H), frameH = Math.min(0.3, top * 0.55);
      part(W, frameH, D, 0, 0, 0, C.wood);
      part(W - 0.04, top - frameH, D - 0.1, 0, frameH, 0.03, C.sheet);
      part(W + 0.01, 0.06, D * 0.58, 0, top - 0.035, D / 2 - D * 0.29, C.blanket);
      const pillows = W > 1.25 ? 2 : 1, pw = (W - 0.2) / pillows - 0.05;
      for (let i = 0; i < pillows; i++) part(pw, 0.1, 0.34, -W / 2 + 0.1 + pw / 2 + i * (pw + 0.1), top, -D / 2 + 0.3, 0xffffff);
      if (H > top + 0.12) part(W, H, 0.06, 0, 0, -D / 2 + 0.03, C.woodDark);
      break;
    }
    case 'sofa': {
      const seat = Math.min(0.42, H * 0.55), arm = Math.min(0.18, W * 0.12), back = Math.min(0.22, D * 0.3);
      part(W, seat, D, 0, 0, 0, C.fabric);
      part(W, H - seat, back, 0, seat, -D / 2 + back / 2, C.fabricDark);
      const armH = Math.min(H, seat + 0.2);
      part(arm, armH, D, -W / 2 + arm / 2, 0, 0, C.fabricDark);
      part(arm, armH, D, W / 2 - arm / 2, 0, 0, C.fabricDark);
      part(Math.min(0.4, W * 0.25), 0.3, 0.12, -W / 4, seat, -D / 2 + back + 0.07, 0xe8c996);
      break;
    }
    case 'table': {
      const t = 0.035, leg = 0.045;
      part(W, t, D, 0, H - t, 0, C.wood);
      for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
        part(leg, H - t, leg, sx * (W / 2 - 0.04), 0, sz * (D / 2 - 0.04), C.dark);
      }
      break;
    }
    case 'chair': {
      const seatY = Math.min(0.46, H * 0.5), leg = 0.03;
      part(W, 0.05, D, 0, seatY - 0.05, 0, C.dark);
      for (const sx of [-1, 1]) for (const sz of [-1, 1]) {
        part(leg, seatY - 0.05, leg, sx * (W / 2 - 0.04), 0, sz * (D / 2 - 0.04), C.dark);
      }
      part(W, H - seatY, 0.05, 0, seatY, -D / 2 + 0.025, C.dark);
      break;
    }
    case 'storage': {
      part(W, H, D, 0, 0, 0, C.light);
      const front = D / 2 + 0.004;
      if (H < 0.75) {
        part(W - 0.04, 0.008, 0.006, 0, H * 0.5, front, 0xb9b3a8);
        part(0.12, 0.02, 0.02, 0, H * 0.72, front + 0.01, 0xa8a8ae);
      } else {
        if (W > 0.55) part(0.008, H - 0.06, 0.006, 0, 0.03, front, 0xb9b3a8);
        const hx = W > 0.55 ? 0.05 : W / 2 - 0.08;
        part(0.02, 0.2, 0.02, -hx, H * 0.48, front + 0.01, 0xa8a8ae);
        if (W > 0.55) part(0.02, 0.2, 0.02, hx, H * 0.48, front + 0.01, 0xa8a8ae);
      }
      break;
    }
    case 'fridge': {
      part(W, H, D, 0, 0, 0, C.metal);
      part(W, 0.012, 0.006, 0, H * 0.62, D / 2 + 0.004, 0x9ea3a8);
      part(0.025, 0.32, 0.03, W / 2 - 0.07, H * 0.68, D / 2 + 0.016, 0x9ea3a8);
      part(0.025, 0.28, 0.03, W / 2 - 0.07, H * 0.25, D / 2 + 0.016, 0x9ea3a8);
      break;
    }
    case 'washer': {
      part(W, H, D, 0, 0, 0, 0xf3f4f5);
      const r0 = Math.min(W, H) * 0.3;
      const door = new THREE.Mesh(new THREE.CylinderGeometry(r0, r0, 0.03, 32), stdMat(0x4b5763, { roughness: 0.3 }));
      door.rotation.x = Math.PI / 2;
      door.position.set(0, H * 0.45, D / 2 + 0.015);
      g.add(door);
      part(W - 0.06, 0.08, 0.01, 0, H - 0.12, D / 2 + 0.005, 0xc9ced3);
      break;
    }
    case 'counter': {
      part(W, H - 0.04, D, 0, 0, 0, 0xf1f0ec);
      part(W + 0.02, 0.04, D + 0.02, 0, H - 0.04, 0, 0xcbc4ba);
      part(Math.min(0.5, W * 0.4), 0.012, D * 0.5, -W * 0.18, H, 0, 0x9aa3ab);
      const n = Math.max(1, Math.round(W / 0.5));
      for (let i = 1; i < n; i++) part(0.006, H - 0.12, 0.006, -W / 2 + (W / n) * i, 0.06, D / 2 + 0.004, 0xc3bdb2);
      break;
    }
    case 'toilet': {
      part(W * 0.8, H * 0.5, D * 0.75, 0, 0, D * 0.1, 0xfafafa);
      part(W, H, D * 0.25, 0, 0, -D / 2 + D * 0.125, 0xf2f2f2);
      break;
    }
    case 'bathtub': {
      part(W, H, D, 0, 0, 0, 0xf6f7f8);
      part(W - 0.12, 0.01, D - 0.12, 0, H, 0, 0xcfe3ef);
      break;
    }
    case 'tv': {
      part(W, H, Math.min(D, 0.06), 0, 0, 0, 0x202226);
      break;
    }
    default:
      part(W, H, D, 0, 0, 0, mine ? 0xb2d0a8 : 0xd4d0c8);
  }
  return g;
}

// ---------------------------------------------------------------- camera modes
const walk = { yaw: 0, pitch: -0.15, pos: new THREE.Vector3(0, EYE, 3) };
// 화각(세로 FOV, 도): 1인칭은 조금 넓게 시작하고, 두 손가락으로 오므리면 더 넓게(축소) · 벌리면 좁게(확대)
const FOV_WALK = 72, FOV_OVERVIEW = 65, FOV_MIN = 30, FOV_MAX = 100;

function clampWalk() {
  const m = 0.25;
  walk.pos.x = clamp(walk.pos.x, room.bboxMin.x + m, room.bboxMax.x - m);
  walk.pos.z = clamp(walk.pos.z, room.bboxMin.z + m, room.bboxMax.z - m);
  walk.pos.y = room.floorY + EYE;
}

function setMode(m) {
  mode = m === 'walk' ? 'walk' : 'overview';   // 'dollhouse' 는 이전 이름 (overview 로 취급)
  if (!room) return;
  const c = roomCenter();
  if (mode === 'walk') {
    controls.enabled = false;
    walk.pos.set(c.x, 0, room.bboxMax.z - 0.4);   // +z 벽 쪽에서 방 중앙(-z 방향)을 바라보며 시작
    walk.yaw = 0;
    walk.pitch = -0.15;
    clampWalk();
    camera.fov = FOV_WALK;                         // 확대 · 축소했던 것도 처음으로
    camera.near = 0.05; camera.far = 100; camera.updateProjectionMatrix();
  } else {
    controls.enabled = true;
    camera.fov = FOV_OVERVIEW;
    camera.updateProjectionMatrix();
    controls.target.copy(c);
    const span = Math.max(room.bboxMax.x - room.bboxMin.x, room.bboxMax.z - room.bboxMin.z, 2);
    // 평면뷰: 방 중심 바로 위에서 내려다보며 시작 (한 손가락으로 돌리고 기울이면 입체로 볼 수 있다)
    camera.position.set(c.x, room.ceilingY + span * 1.25 + 1, c.z + 0.001);
    controls.update();
  }
}

// "초기화": 현재 모드의 처음 시점으로
function resetView() { setMode(mode); }

// 평면뷰(조감) 모드: 천장을 걷어낸 것처럼 보이도록 near plane 을 천장 너머로 민다 (스플랫·포인트·메시 공통).
const _dir = new THREE.Vector3();
function updateCutaway() {
  let near = 0.05;
  camera.getWorldDirection(_dir);
  if (_dir.y < -0.05 && camera.position.y > room.ceilingY) {
    near = Math.max(0.05, (camera.position.y - room.ceilingY) / -_dir.y + 0.05);
  }
  if (Math.abs(camera.near - near) > 1e-3) { camera.near = near; camera.far = near + 60; camera.updateProjectionMatrix(); }
}

// 1인칭: 한 손가락 = 둘러보기, 두 손가락 = 끌면 이동(위=앞, 오른쪽=오른쪽) · 오므리면 넓게 · 벌리면 가깝게.
// 확대 · 축소는 화각으로 하고, 가장 넓게 본 상태에서 더 오므리면 바라보는 반대쪽으로 물러난다 (방 밖으로는 안 나감)
const touches = new Map();
let lastMid = null, lastSpread = null, twoMode = null, twoAcc = { move: 0, zoom: 0 };
function resetTwo() { lastMid = null; lastSpread = null; twoMode = null; twoAcc = { move: 0, zoom: 0 }; }

function zoomWalk(ratio) {            // ratio > 1 = 오므림(넓게), < 1 = 벌림(가깝게)
  const want = camera.fov * ratio;
  if (want > FOV_MAX && room) {       // 이미 가장 넓으면 한 걸음씩 뒤로
    walk.pos.addScaledVector(new THREE.Vector3(Math.sin(walk.yaw), 0, Math.cos(walk.yaw)), (want - FOV_MAX) / FOV_MAX * 1.5);
    clampWalk();
  }
  const fov = clamp(want, FOV_MIN, FOV_MAX);
  if (Math.abs(fov - camera.fov) > 1e-3) { camera.fov = fov; camera.updateProjectionMatrix(); }
}

cvs.addEventListener('pointerdown', (e) => {
  if (mode !== 'walk' || drag) return;
  touches.set(e.pointerId, { x: e.clientX, y: e.clientY });
  resetTwo();
});
cvs.addEventListener('pointermove', (e) => {
  if (mode !== 'walk' || drag || !room || !touches.has(e.pointerId)) return;
  const t = touches.get(e.pointerId);
  const dx = e.clientX - t.x, dy = e.clientY - t.y;
  t.x = e.clientX; t.y = e.clientY;
  if (touches.size === 1) {
    const k = 0.005 * camera.fov / FOV_WALK;          // 확대했을 때는 천천히 돈다
    walk.yaw += dx * k;
    walk.pitch = clamp(walk.pitch + dy * k, -1.3, 1.3);
  } else {
    const [a, b] = [...touches.values()];
    const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    const spread = Math.hypot(a.x - b.x, a.y - b.y);
    if (lastMid && lastSpread) {
      const mx = mid.x - lastMid.x, my = mid.y - lastMid.y, ds = spread - lastSpread;
      if (!twoMode) {                  // 처음 몇 픽셀로 '이동' 인지 '확대 · 축소' 인지 정한다 (섞이면 걸으면서 화면이 출렁인다)
        twoAcc.move += Math.hypot(mx, my);
        twoAcc.zoom += Math.abs(ds);
        if (twoAcc.move + twoAcc.zoom > 12) twoMode = twoAcc.zoom > twoAcc.move ? 'zoom' : 'move';
      }
      if (twoMode === 'move') {
        const f = new THREE.Vector3(-Math.sin(walk.yaw), 0, -Math.cos(walk.yaw));
        const r = new THREE.Vector3(Math.cos(walk.yaw), 0, -Math.sin(walk.yaw));
        walk.pos.addScaledVector(f, -my * 0.01).addScaledVector(r, mx * 0.01);
        clampWalk();
      } else if (twoMode === 'zoom' && spread > 10) {
        zoomWalk(lastSpread / spread);
      }
    }
    lastMid = mid;
    lastSpread = spread;
  }
});
const endTouch = (e) => { touches.delete(e.pointerId); resetTwo(); };
cvs.addEventListener('pointerup', endTouch);
cvs.addEventListener('pointercancel', endTouch);
// 트랙패드 · 마우스 휠 (시뮬레이터 · Mac 디버깅): 아래로 굴리면 넓게
cvs.addEventListener('wheel', (e) => {
  if (mode !== 'walk' || !room) return;
  e.preventDefault();
  zoomWalk(Math.exp(e.deltaY * 0.002));
}, { passive: false });


// ---------------------------------------------------------------- furniture
const gltfLoader = new GLTFLoader();
const ray = new THREE.Raycaster(), ndc = new THREE.Vector2();
ray.params.Line.threshold = 0.01;     // 기본값 1 m 이면 가구 근처 터치가 모두 드래그로 잡힌다
const floorPlane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
let drag = null, down = null, lastSent = 0;

function setRay(e) {
  const r = cvs.getBoundingClientRect();
  ndc.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
  ray.setFromCamera(ndc, camera);
}
function pickFurniture(e) {
  setRay(e);
  for (const h of ray.intersectObjects(furnGroup.children, true)) {
    let o = h.object;
    while (o && !o.userData.fid) o = o.parent;
    if (o) return o.userData.fid;
  }
  return null;
}
function floorHit(e) {
  setRay(e);
  floorPlane.constant = -room.floorY;
  const p = new THREE.Vector3();
  return ray.ray.intersectPlane(floorPlane, p) ? p : null;
}
function sendTransform(id, final) {
  const f = furn.get(id);
  if (!f) return;
  post({ type: 'transform', id, x: f.root.position.x, z: f.root.position.z, yaw: f.root.rotation.y / D2R, final });
}

// document 캡처 단계에서 먼저 받는다. 이미 고른 내 가구 위에서 시작한 한 손가락만 '끌어서 옮기기',
// 그 밖(고르지 않은 가구 포함)은 카메라 조작으로 넘긴다 → 가구가 화면을 덮어도 둘러보기 · 확대 · 축소가 막히지 않는다.
// 짧게 탭하면 그 가구를 고르고(새로 놓은 가구는 이미 골라져 있다), 빈 곳을 탭하면 선택을 푼다
const fingers = new Set();
document.addEventListener('pointerdown', (e) => {
  if (!room || e.target !== cvs) return;
  fingers.add(e.pointerId);
  const id = pickFurniture(e);
  if (id && id === selected && fingers.size === 1) {
    const f = furn.get(id), p = floorHit(e);
    drag = { id, pid: e.pointerId, off: p ? f.root.position.clone().sub(p) : new THREE.Vector3() };
    controls.enabled = false;
    e.stopPropagation();
  } else {
    down = fingers.size === 1 ? { x: e.clientX, y: e.clientY, t: performance.now(), id } : null;
  }
}, true);


document.addEventListener('pointermove', (e) => {
  if (!drag || e.pointerId !== drag.pid) return;
  const p = floorHit(e);
  if (p) {
    const f = furn.get(drag.id);
    p.add(drag.off);
    f.root.position.set(snap(p.x, SNAP_POS), room.floorY, snap(p.z, SNAP_POS));
    const now = performance.now();
    if (now - lastSent > 50) { lastSent = now; sendTransform(drag.id, false); }
  }
  e.stopPropagation();
}, true);

document.addEventListener('pointerup', (e) => {
  fingers.delete(e.pointerId);
  if (drag && e.pointerId === drag.pid) {
    sendTransform(drag.id, true);
    drag = null;
    controls.enabled = mode !== 'walk';
    e.stopPropagation();
    return;
  }
  if (down && Math.hypot(e.clientX - down.x, e.clientY - down.y) < 8 && performance.now() - down.t < 300) select(down.id);
  down = null;
}, true);
document.addEventListener('pointercancel', (e) => {
  fingers.delete(e.pointerId);
  down = null;
  if (drag && e.pointerId === drag.pid) {
    sendTransform(drag.id, true);
    drag = null;
    controls.enabled = mode !== 'walk';
  }
}, true);

function fitToDims(model, d) {
  // AI 가 준 실제 치수(dims)에 모델 크기를 정확히 맞춘다 → 보이는 크기 = 충돌 판정 크기
  const s = new THREE.Box3().setFromObject(model).getSize(new THREE.Vector3());
  if (s.x > 1e-6 && s.y > 1e-6 && s.z > 1e-6) model.scale.multiply(new THREE.Vector3(d.width / s.x, d.height / s.y, d.depth / s.z));
  const b = new THREE.Box3().setFromObject(model), c = b.getCenter(new THREE.Vector3());
  model.position.sub(new THREE.Vector3(c.x, b.min.y, c.z));   // 바닥 중심을 원점으로
}

async function addFurniture(f) {
  try {
    removeFurniture(f.id);
    const root = new THREE.Group();
    root.userData.fid = f.id;
    let model;
    if (f.url === 'box') {
      model = furnitureModel(f.kind, f.dims, true);      // GLB 없이 치수대로 (데모 가구)
    } else {
      const gltf = await gltfLoader.loadAsync(f.url);
      model = gltf.scene;
      fitToDims(model, f.dims);
    }
    root.add(model);
    const pad = new THREE.Mesh(
      new THREE.PlaneGeometry(f.dims.width, f.dims.depth),
      new THREE.MeshBasicMaterial({ color: GREEN, transparent: true, opacity: 0.3, depthWrite: false, side: THREE.DoubleSide }),
    );
    pad.rotation.x = -Math.PI / 2;
    pad.position.y = 0.01;
    const lines = box(f.dims, GREEN);
    lines.position.y = f.dims.height / 2;
    const lb = label(f.label || '가구', 'furn');
    lb.position.y = f.dims.height + 0.1;
    root.add(pad, lines, lb);
    root.position.set(f.x, room ? room.floorY : 0, f.z);
    root.rotation.y = (f.yaw || 0) * D2R;
    furnGroup.add(root);
    furn.set(f.id, { root, pad, lines, label: lb, dims: f.dims });
    select(f.id);
    post({ type: 'furnitureLoaded', id: f.id });
  } catch (e) {
    post({ type: 'error', message: '가구 모델 로딩 실패: ' + (e?.message || e) });
  }
}

function setFurnitureState(id, ok) {
  const f = furn.get(id);
  if (!f) return;
  const c = ok ? GREEN : RED;
  f.pad.material.color.setHex(c);
  f.lines.material.color.setHex(c);
  f.label.element.classList.toggle('bad', !ok);
}

function setFurnitureTransform(id, x, z, yaw) {
  const f = furn.get(id);
  if (!f) return;
  f.root.position.set(x, room ? room.floorY : 0, z);
  f.root.rotation.y = yaw * D2R;
}

function removeFurniture(id) {
  const f = furn.get(id);
  if (!f) return;
  removeLabels(f.root);
  furnGroup.remove(f.root);
  disposeTree(f.root);
  furn.delete(id);
  if (selected === id) select(null);
}

function select(id) {
  selected = id && furn.has(id) ? id : null;
  for (const [fid, f] of furn) f.pad.material.opacity = fid === selected ? 0.5 : 0.25;
  post({ type: 'select', id: selected });
}

// ---------------------------------------------------------------- object / overlay state
function setObjectOwnership(id, type) {
  objectViz.get(id)?.lines.material.color.setHex(ownColor(type));
}

function setRemovedObjects(ids) {
  const s = new Set(ids || []);
  for (const [id, v] of objectViz) { v.lines.visible = !s.has(id); v.label.visible = !s.has(id); }
  for (const [id, m] of objectMeshes) m.visible = !s.has(id);
}

function setOverlay(on) {
  overlayOn = !!on;
  overlay.visible = overlayOn;
  // CSS 라벨은 부모 visible 을 따르지 않는 버전이 있어 직접 숨긴다
  overlay.traverse((o) => { if (o.isCSS2DObject) o.element.style.visibility = overlayOn ? '' : 'hidden'; });
}

// ---------------------------------------------------------------- loop / resize
window.addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
  labels.setSize(innerWidth, innerHeight);
});

renderer.setAnimationLoop(() => {
  if (room) {
    if (mode !== 'walk') { controls.update(); updateCutaway(); }
    else { camera.position.copy(walk.pos); camera.rotation.set(walk.pitch, walk.yaw, 0, 'YXZ'); }
  }
  renderer.render(scene, camera);
  labels.render(scene, camera);
});

window.DV = {
  loadScene, setMode, resetView, setOverlay, setObjectOwnership, setRemovedObjects,
  addFurniture, setFurnitureState, setFurnitureTransform, removeFurniture, select,
};
post({ type: 'ready' });
