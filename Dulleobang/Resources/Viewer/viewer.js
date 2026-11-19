// 둘러방 3D 뷰어 — three.js (+ 3DGS 를 받을 때만 @mkkellogg/gaussian-splats-3d)
// 방은 넷 중 하나로 그린다: ① 메시(room.glb · PLY · OBJ, AI 팀 export_space.py 결과) ② 3DGS ③ 점 ④ 벽 · 가구 치수로 만든 상자 모형.
// 좌표계: 미터, Y-up, 오른손 (ARKit 월드와 동일, glTF 와도 같음). yaw: +Y 축 기준 반시계(위에서 볼 때), 도(°).
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
const scanGroup = new THREE.Group();   // 방 메시 + 방과 따로 온 가구 GLB (같은 방을 다시 열 때는 그대로 둔다)
scene.add(world, scanGroup, overlay, furnGroup);

let room = null;            // { floorY, ceilingY, bboxMin, bboxMax, walls, doors, windows }
let mode = 'walk';          // walk (1인칭) | overview (평면뷰: 위에서 내려다봄, 기울이면 입체)
let splat = null;
let overlayOn = true;
const objectViz = new Map(); // objectId → { lines, label }
const objectMeshes = new Map(); // objectId → 화면에 그린 가구 (상자 모형 또는 가구 GLB). setRemovedObjects 가 숨기고 보인다
const objectModels = new Map(); // objectId → { url, group } 방과 따로 온 가구 GLB (objects[].modelUrl)
let scan = null;                // 지금 떠 있는 방 메시 { url, root }
let sceneRemoved = new Set();   // 장면 파일에서 이미 빠져 있는 가구 (서버가 가구를 빼고 새로 만든 입주 예상 PLY · 장면)
let loadGen = 0;                // loadScene 이 겹쳐 불렸을 때 늦게 끝난 쪽을 버리기 위한 번호
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
const TEX_SLOTS = ['map', 'normalMap', 'roughnessMap', 'metalnessMap', 'aoMap', 'emissiveMap', 'alphaMap'];
function disposeMaterial(m) {
  if (!m) return;
  for (const k of TEX_SLOTS) {
    const t = m[k];
    if (!t) continue;
    try { t.source?.data?.close?.(); } catch (_) {}     // ImageBitmap 은 바로 닫아야 큰 텍스처 메모리가 풀린다
    t.dispose?.();
  }
  m.dispose?.();
}
function disposeTree(o) {
  o.traverse((c) => {
    c.geometry?.dispose?.();
    const m = c.material;
    if (Array.isArray(m)) m.forEach(disposeMaterial); else disposeMaterial(m);
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
  const gen = ++loadGen;
  const stale = () => gen !== loadGen;
  try {
    const want = await sceneSource(p);                  // { kind: 'mesh' | 'splat' | 'points' | 'blockout', url }
    if (stale()) return;
    const keep = (want.kind === 'mesh' || want.kind === 'points') && !!scan && scan.url === want.url;   // 같은 방 메시 · 점구름은 다시 읽지 않는다 (지금 모습 ↔ 입주 예상)
    clearAll(keep);
    room = p.room;
    sceneRemoved = new Set(p.sceneRemoved || []);
    const models = p.objectModels || {};                 // objectId → 방과 따로 온 가구 GLB 주소 (앱이 내려받아 둔 것)
    const objects = (p.objects || []).map((o) => (o.modelUrl || !models[o.objectId] ? o : { ...o, modelUrl: models[o.objectId] }));
    const removed = new Set(p.removed || []), glassList = p.glass || [];
    const progress = (ev) => { if (ev?.total) post({ type: 'progress', value: ev.loaded / ev.total }); };
    if (want.kind === 'splat') {
      const GS = await import('@mkkellogg/gaussian-splats-3d');
      // WKWebView 는 cross-origin isolation 이 아니므로 SharedArrayBuffer 를 쓰지 않는다
      const viewer = new GS.DropInViewer({ sharedMemoryForWorkers: false, gpuAcceleratedSort: false, dynamicScene: false });
      await viewer.addSplatScene(want.url, {
        showLoadingUI: false, progressiveLoad: false, splatAlphaRemovalThreshold: 5,
        onProgress: (pct) => post({ type: 'progress', value: (Number(pct) || 0) / 100 }),
      });
      if (stale()) { try { viewer.dispose?.(); } catch (_) {} return; }
      splat = viewer;
      world.add(splat);
    } else if (want.kind === 'mesh' || want.kind === 'points') {
      if (!keep) {
        let root;
        try {
          root = await loadScan(want.url, progress);
        } catch (e) {
          // 방 메시를 못 읽음 (파일이 깨졌거나 너무 커서 메모리가 모자람) → 앱이 점구름(pointsUri)이 있으면 그것으로 다시 연다
          if (want.kind === 'mesh') { if (!stale()) post({ type: 'meshFailed', message: String(e?.message || e) }); return; }
          throw e;
        }
        if (stale()) { disposeTree(root); return; }
        scanGroup.add(root);
        scan = { url: want.url, root };
      }
    } else {
      // 스캔 파일 없이 벽·문·창·가구 정보만 있을 때 (데모 데이터 · RoomPlan 구조만 올라온 매물)
      buildBlockout(objects, removed, glassList);
    }
    if (!(await loadObjectModels(objects, removed, p.objectFrame, stale))) return;
    if (room.hasGeometry === false) adoptScanBounds();
    prepareScanMask(objects);
    applyScanMask(scanHiddenIds(removed));
    updatePointSize();
    buildGlass(glassList);
    buildOverlay(objects, removed, glassList);
    setOverlay(overlayOn);
    setMode(mode);
    post({ type: 'loaded' });
  } catch (e) {
    if (!stale()) post({ type: 'error', message: '3D 장면 로딩 실패: ' + (e?.message || e) });
  }
}

function clearAll(keepScan = false) {
  for (const id of [...furn.keys()]) removeFurniture(id);
  clearGroup(overlay);
  clearGroup(world);
  objectViz.clear();
  objectMeshes.clear();
  if (splat) { try { splat.dispose?.(); } catch (_) {} splat = null; }
  if (!keepScan) {
    clearGroup(scanGroup);
    objectModels.clear();
    scan = null;
  }
}

// ---------------------------------------------------------------- scan mesh (방 메시 · 가구 GLB)
// AI 팀 파이프라인(메시 전용)의 앱용 결과: ARKit 좌표의 room.glb + 가구별 GLB + 유리 + space.json.
// 서버가 예전 자리(3dgsUri · pointsUri)에 메시를 넣어 줘도 열리게, 파일 종류는 확장자와 PLY 머리말로 정한다.
function urlExt(url) {
  const name = String(url).split(/[?#]/)[0].split('/').pop() || '';
  const i = name.lastIndexOf('.');
  return i < 0 ? '' : name.slice(i + 1).toLowerCase();
}
const MESH_EXT = new Set(['glb', 'gltf', 'obj']), SPLAT_EXT = new Set(['splat', 'ksplat', 'spz']);

// PLY 는 셋 다 될 수 있다: 면이 있으면 메시, 가우시안 속성이 있으면 3DGS, 아니면 점. 머리말만 읽고 끊는다
async function plyKind(url) {
  const res = await fetch(url);
  if (!res.body?.getReader) return null;
  const reader = res.body.getReader(), dec = new TextDecoder('latin1');
  let head = '';
  while (head.length < 65536) {
    const { done, value } = await reader.read();
    if (done) break;
    head += dec.decode(value, { stream: true });
    if (head.includes('end_header')) break;
  }
  try { await reader.cancel(); } catch (_) {}
  const faces = /element\s+face\s+(\d+)/.exec(head);
  if (faces && Number(faces[1]) > 0) return 'mesh';
  if (/property\s+\w+\s+(f_dc_0|scale_0|rot_0)\b/.test(head)) return 'splat';
  return 'points';
}

async function sceneSource(p) {
  if (p.meshUrl) return { kind: 'mesh', url: p.meshUrl };
  for (const [url, hint] of [[p.splatUrl, 'splat'], [p.pointsUrl, 'points']]) {
    if (!url) continue;
    const ext = urlExt(url);
    if (MESH_EXT.has(ext)) return { kind: 'mesh', url };
    if (SPLAT_EXT.has(ext)) return { kind: 'splat', url };
    if (ext === 'ply' && hint === 'splat') {
      let kind = null;
      try { kind = await plyKind(url); } catch (_) {}
      return { kind: kind ?? hint, url };
    }
    return { kind: hint, url };          // 점 PLY 에 면이 있으면 loadScan 이 메시로 그린다
  }
  return { kind: 'blockout', url: null };
}

let sceneGltf = null;
// 압축된 GLB(EXT_meshopt_compression · KHR_draco_mesh_compression)도 열 수 있게 디코더를 붙인 로더 (처음 쓸 때 한 번 만든다)
async function gltfLoaderWithDecoders() {
  if (sceneGltf) return sceneGltf;
  const loader = new GLTFLoader();
  try {
    const { MeshoptDecoder } = await import('three/addons/libs/meshopt_decoder.module.js');
    loader.setMeshoptDecoder(MeshoptDecoder);
  } catch (_) {}
  try {
    const { DRACOLoader } = await import('three/addons/loaders/DRACOLoader.js');
    const draco = new DRACOLoader();
    draco.setDecoderPath(new URL('../libs/draco/gltf/', import.meta.resolve('three/addons/loaders/DRACOLoader.js')).href);
    loader.setDRACOLoader(draco);
  } catch (_) {}
  sceneGltf = loader;
  return loader;
}

// 스캔으로 만든 메시(방 · 가구)는 사진 색에 그 방의 빛이 이미 들어 있어서 조명을 다시 입히지 않는다(unlit).
// 색 정보(텍스처 · 꼭짓점 색)가 없는 메시만 조명을 받게 둔다. 실내에서 보므로 면의 앞뒤를 모두 그린다
function prepareScan(root) {
  root.traverse((c) => {
    if (!c.isMesh) return;
    const g = c.geometry, hasColor = g.hasAttribute('color');
    const convert = (m) => {
      if (m.map || hasColor) {
        const b = new THREE.MeshBasicMaterial({
          map: m.map ?? null, color: m.color ? m.color.clone() : new THREE.Color(0xffffff), vertexColors: hasColor,
          side: THREE.DoubleSide, transparent: !!m.transparent, opacity: m.opacity ?? 1, alphaTest: m.alphaTest ?? 0,
        });
        b.name = m.name;
        m.dispose?.();                               // 텍스처는 새 재질이 이어 쓴다
        return b;
      }
      if (!g.hasAttribute('normal')) g.computeVertexNormals();
      m.side = THREE.DoubleSide;
      return m;
    };
    c.material = Array.isArray(c.material) ? c.material.map(convert) : convert(c.material);
  });
  return root;
}

async function loadScan(url, onProgress) {
  const ext = urlExt(url);
  if (ext === 'glb' || ext === 'gltf') {
    const gltf = await (await gltfLoaderWithDecoders()).loadAsync(url, onProgress);
    return prepareScan(gltf.scene);
  }
  if (ext === 'obj') {
    const { OBJLoader } = await import('three/addons/loaders/OBJLoader.js');
    return prepareScan(await new OBJLoader().loadAsync(url, onProgress));
  }
  const geo = await new PLYLoader().loadAsync(url, onProgress);
  if (geo.index && geo.index.count >= 3) {             // 면이 있는 PLY = 메시 (TSDF · Poisson 결과)
    return prepareScan(new THREE.Mesh(geo, stdMat(0xd9d6d0)));
  }
  const pts = new THREE.Points(geo, new THREE.PointsMaterial({ size: 0.012, sizeAttenuation: true, vertexColors: geo.hasAttribute('color') }));
  pts.userData.footprint = pointFootprint(geo);
  return pts;
}

// 점 하나가 덮을 실제 지름(m). 점구름 껍데기 넓이 ÷ 점 수로 평균 간격을 잡고 그 2.6배로 한다 (점이 무작위로 뿌려져 있어도 빈틈이 거의 안 보이는 크기. 1.8배는 벽에 검은 점이 보였고, 2.2배 0.6% · 2.6배 0.16% 가 빈틈).
// 창밖으로 튄 점 때문에 범위가 부풀지 않게 2~98% 범위로 잰다
function pointFootprint(geo) {
  const pos = geo.getAttribute('position'), n = pos.count;
  if (n < 10) return 0.012;
  const step = Math.max(1, Math.floor(n / 20000)), xs = [], ys = [], zs = [];
  for (let i = 0; i < n; i += step) { xs.push(pos.getX(i)); ys.push(pos.getY(i)); zs.push(pos.getZ(i)); }
  const span = (a) => { a.sort((u, v) => u - v); return a[Math.floor(a.length * 0.98)] - a[Math.floor(a.length * 0.02)]; };
  const w = span(xs), h = span(ys), d = span(zs);
  const area = 2 * (w * d + w * h + d * h);
  return clamp(2.6 * Math.sqrt(area / n), 0.006, 0.05);
}

// three.js 의 점 크기는 화면 각도(fov)를 모르므로 지금 fov 에 맞춰 실제 지름이 되게 고친다 (확대해도 빈틈이 안 생기게)
function updatePointSize() {
  const pts = scan?.root;
  if (!pts?.isPoints || !pts.userData.footprint) return;
  pts.material.size = pts.userData.footprint / Math.tan((camera.fov * D2R) / 2);
}

// ---------------------------------------------------------------- 스캔 속 가구 가리기 (점구름 · 방 메시 공통)
// 백엔드는 AI 의 방 GLB 를 색 점구름(PLY)으로 바꿔 pointsUri 로 보내고(2026.11.18 문서), 원본 room.glb 와 가구별 GLB 도
// meshUri · objects[].modelUri 로 붙이기로 했다(11.19 답변). 점구름에는 가구가 들어 있고, room.glb 에도 가구가 남아 있을 수 있다. 그래서 스캔(점 · 삼각형) 중
//   ① 따로 온 가구 GLB 가 떠 있는 가구의 상자 안 → 늘 숨긴다 (가구 GLB 와 겹쳐 두 겹으로 보이지 않게)
//   ② ‘가구 빼 보기’ 미리보기 · 입주 예상에서 뺀 가구의 상자 안 → 숨긴다
// 상자는 4 cm 넉넉히 잡고, 바닥 · 천장 · 벽에 붙은 3 cm 띠는 남겨 구멍이 덜 나게 한다. 여러 상자에 들면 가장 작은 상자(책상 밑 의자)의 것으로 본다.
// 빈자리를 채우지는 않는다 (가구 밑은 비어 보인다). 삼각형은 무게중심이 상자 안이면 그 가구 것으로 본다.
const MASK_MARGIN = 0.04, SURFACE_KEEP = 0.03;

function maskKey(objects) {
  const r = room || {};
  return JSON.stringify([r.floorY, r.ceilingY, r.walls, objects.map((o) => [o.objectId, o.position, o.rotation?.yaw, o.dimensions])]);
}

function distToWalls(x, z, walls) {
  let best = Infinity;
  for (const w of walls) {
    const ax = w.from[0], az = w.from[1], bx = w.to[0], bz = w.to[1], dx = bx - ax, dz = bz - az;
    const len2 = dx * dx + dz * dz;
    const t = len2 > 1e-9 ? clamp(((x - ax) * dx + (z - az) * dz) / len2, 0, 1) : 0;
    best = Math.min(best, Math.hypot(x - (ax + t * dx), z - (az + t * dz)));
  }
  return best;
}

// 가구 상자들 → test(x, y, z, n) = 그 자리가 드는 상자 번호 (-1 = 가구 아님 · 바닥 · 벽 · 천장 띠).
// n = 면의 법선 [x, y, z](메시만, 점은 없음). 메시는 바닥 띠 안에서 위를 향한 면(바닥)만 남긴다(가구 밑면 · 옆면 아랫단은 가구).
// 벽은 점 · 면 모두 RoomPlan 벽선에서 3 cm 띠를 남긴다. (벽과 나란한 면을 10 cm 까지 남기면 벽에 붙은 침대 머리판 앞면 같은 가구 면이 남아서 쓰지 않음)
function boxTester(objects) {
  const boxes = objects.map((o) => {
    const d = o.dimensions, yaw = (o.rotation?.yaw ?? 0) * D2R;
    return { id: o.objectId, x: o.position.x, z: o.position.z, cos: Math.cos(yaw), sin: Math.sin(yaw),
             hx: d.width / 2 + MASK_MARGIN, hz: d.depth / 2 + MASK_MARGIN,
             y0: o.position.y - d.height / 2 - MASK_MARGIN, y1: o.position.y + d.height / 2 + MASK_MARGIN,
             vol: d.width * d.depth * d.height };
  }).sort((a, b) => a.vol - b.vol);
  const ids = boxes.map((b) => b.id);
  if (!boxes.length || !room) return { ids, test: () => -1, near: () => false };
  const reach = (b) => Math.hypot(b.hx, b.hz);
  const lo = { x: Math.min(...boxes.map((b) => b.x - reach(b))), z: Math.min(...boxes.map((b) => b.z - reach(b))), y: Math.min(...boxes.map((b) => b.y0)) };
  const hi = { x: Math.max(...boxes.map((b) => b.x + reach(b))), z: Math.max(...boxes.map((b) => b.z + reach(b))), y: Math.max(...boxes.map((b) => b.y1)) };
  const yMin = room.floorY + SURFACE_KEEP, yMax = room.ceilingY - SURFACE_KEEP, walls = room.walls || [];
  const test = (x, y, z, n) => {
    if (x < lo.x || x > hi.x || z < lo.z || z > hi.z || y < lo.y || y > hi.y || y > yMax) return -1;
    if (y < yMin && (!n || n[1] > 0.7)) return -1;
    for (let k = 0; k < boxes.length; k++) {
      const b = boxes[k];
      if (y < b.y0 || y > b.y1) continue;
      const dx = x - b.x, dz = z - b.z;
      if (Math.abs(b.cos * dx - b.sin * dz) > b.hx || Math.abs(b.sin * dx + b.cos * dz) > b.hz) continue;
      if (walls.length && distToWalls(x, z, walls) < SURFACE_KEEP) return -1;      // 벽에 붙은 점 · 면은 벽으로 본다
      return k;
    }
    return -1;
  };
  const near = (x, y, z) => x >= lo.x && x <= hi.x && z >= lo.z && z <= hi.z && y >= lo.y && y <= hi.y;   // 어느 상자 근처도 아니면 바로 건너뛴다
  return { ids, test, near };
}

// 점 · 삼각형마다 어느 가구 상자에 드는지 한 번 계산해 둔다 (50만 점 · 가구 열 개 남짓이면 수십 ms). 가구 정보가 같으면 다시 하지 않는다
function prepareScanMask(objects) {
  const root = scan?.root;
  if (!root || !room) return;
  const key = maskKey(objects);
  if (root.userData.maskKey === key) return;
  const t0 = performance.now();
  const tester = boxTester(objects);
  root.userData.maskKey = key;
  root.userData.maskIds = tester.ids;
  root.userData.hiddenKey = null;
  if (root.isPoints) preparePointsMask(root, tester.test);
  else {
    root.updateWorldMatrix(true, true);
    root.traverse((c) => { if (c.isMesh) prepareMeshMask(c, tester); });
  }
  root.userData.maskMs = Math.round(performance.now() - t0);
}

function preparePointsMask(pts, test) {
  const geo = pts.geometry, pos = geo.getAttribute('position'), nor = geo.getAttribute('normal'), n = pos.count;
  const owner = new Int16Array(n);
  for (let i = 0; i < n; i++) owner[i] = test(pos.getX(i), pos.getY(i), pos.getZ(i), nor ? [nor.getX(i), nor.getY(i), nor.getZ(i)] : null);   // 점에 법선이 있으면 메시처럼 판단
  // 보이는 점만 앞으로 모아 그리게 인덱스를 한 번 만들어 둔다 (다시 만들지 않고 내용만 바꿔 GPU 메모리가 늘지 않게)
  if (!geo.index || geo.index.count !== n) {
    geo.setIndex(new THREE.BufferAttribute(new Uint32Array(n), 1).setUsage(THREE.DynamicDrawUsage));
  }
  pts.userData.mask = { owner, hidden: 0 };
}

// 메시: 가구 상자 안 삼각형을 인덱스 뒤쪽으로 모아 두고(원래 순서는 그림에 상관없다), 숨길 때는 그리는 범위만 줄인다.
// 큰 방 메시(삼각형 190만 개)에서도 인덱스를 통째로 복사하지 않게 상자 안 삼각형만 따로 들고 있는다
function prepareMeshMask(mesh, { test, near }) {
  const geo = mesh.geometry, pos = geo.getAttribute('position');
  if (!pos || geo.groups.length > 1) return;            // 재질이 여러 묶음인 메시는 건너뛴다 (GLB 는 재질마다 메시가 따로 온다)
  if (!geo.index) {
    const n = pos.count, arr = n > 65535 ? new Uint32Array(n) : new Uint16Array(n);
    for (let i = 0; i < n; i++) arr[i] = i;
    geo.setIndex(new THREE.BufferAttribute(arr, 1));
  }
  const idx = geo.index.array, old = mesh.userData.mask;
  if (old) idx.set(old.ownedTris, old.unowned * 3);      // 예전에 나눠 둔 것을 원래 목록으로 되돌린 뒤 다시 나눈다
  const T = Math.floor(idx.length / 3), e = mesh.matrixWorld.elements;
  const owner = new Int16Array(T);
  let O = 0;
  // 큰 방 메시(삼각형 수백만 개)를 빨리 돌게: 위치 배열을 바로 읽고, 무게중심이 어느 가구 상자 근처도 아니면 법선은 계산하지 않는다
  const flat = !pos.isInterleavedBufferAttribute && !pos.normalized && pos.itemSize === 3 ? pos.array : null;
  const gx = flat ? (i) => flat[3 * i] : (i) => pos.getX(i), gy = flat ? (i) => flat[3 * i + 1] : (i) => pos.getY(i), gz = flat ? (i) => flat[3 * i + 2] : (i) => pos.getZ(i);
  for (let t = 0; t < T; t++) {
    const a = idx[3 * t], b = idx[3 * t + 1], c = idx[3 * t + 2];
    const ax = gx(a), ay = gy(a), az = gz(a), bx = gx(b), by = gy(b), bz = gz(b), cx = gx(c), cy = gy(c), cz = gz(c);
    const mx = (ax + bx + cx) / 3, my = (ay + by + cy) / 3, mz = (az + bz + cz) / 3;
    const wx = e[0] * mx + e[4] * my + e[8] * mz + e[12], wy = e[1] * mx + e[5] * my + e[9] * mz + e[13], wz = e[2] * mx + e[6] * my + e[10] * mz + e[14];
    if (!near(wx, wy, wz)) { owner[t] = -1; continue; }
    // 면의 법선(방 좌표의 위쪽 성분). 회전 · 크기 변환은 대개 균일해서 꼭짓점을 옮긴 뒤 외적한 것과 같다
    const ux = bx - ax, uy = by - ay, uz = bz - az, vx = cx - ax, vy = cy - ay, vz = cz - az;
    const lx = uy * vz - uz * vy, ly = uz * vx - ux * vz, lz = ux * vy - uy * vx;
    const nx = e[0] * lx + e[4] * ly + e[8] * lz, ny = e[1] * lx + e[5] * ly + e[9] * lz, nz = e[2] * lx + e[6] * ly + e[10] * lz;
    const nl = Math.hypot(nx, ny, nz);
    const k = test(wx, wy, wz, nl > 1e-12 ? [nx / nl, ny / nl, nz / nl] : [0, 1, 0]);
    owner[t] = k;
    if (k >= 0) O++;
  }
  if (!O) {
    mesh.userData.mask = null;
    geo.setDrawRange(0, Infinity);
    if (old) { geo.index.clearUpdateRanges?.(); geo.index.needsUpdate = true; }
    return;
  }
  const ownedTris = new idx.constructor(O * 3), ownedOwner = new Int16Array(O);
  let o = 0, w = 0;
  for (let t = 0; t < T; t++) {
    if (owner[t] >= 0) {
      ownedTris[3 * o] = idx[3 * t]; ownedTris[3 * o + 1] = idx[3 * t + 1]; ownedTris[3 * o + 2] = idx[3 * t + 2];
      ownedOwner[o++] = owner[t];
    } else {
      if (w !== t) { idx[3 * w] = idx[3 * t]; idx[3 * w + 1] = idx[3 * t + 1]; idx[3 * w + 2] = idx[3 * t + 2]; }
      w++;
    }
  }
  idx.set(ownedTris, w * 3);
  geo.index.clearUpdateRanges?.();
  geo.index.needsUpdate = true;
  // 순서를 통째로 바꿨으니 다음 그리기 전까지는 인덱스 전체를 GPU 로 보내야 한다(synced = false).
  // 방 메시는 가구 GLB 를 받는 동안 이미 한 번 그려져서 GPU 에 원래 순서가 올라가 있다. 이때 뒤쪽만 보내면
  // 앞쪽이 옛 순서로 남아 삼각형 수천 개가 빠지고 배경색 구멍(검은 조각)으로 보인다 (실서버 room.glb + 가구 GLB, 11.19)
  mesh.userData.mask = { unowned: w, ownedTris, ownedOwner, hidden: 0, synced: false };
  if (!mesh.userData.maskSyncHook) {
    mesh.userData.maskSyncHook = true;
    const after = mesh.onAfterRender;                    // 그렸다 = 그 전에 바뀐 인덱스가 GPU 에 올라갔다
    mesh.onAfterRender = function (...args) {
      const mk = this.userData.mask;
      if (mk) mk.synced = true;
      return after.apply(this, args);
    };
  }
}

function applyPointsMask(pts, hide) {
  const m = pts.userData.mask;
  if (!m) return;
  const geo = pts.geometry, idx = geo.index.array, owner = m.owner;
  let c = 0;
  for (let i = 0; i < owner.length; i++) { const k = owner[i]; if (k < 0 || !hide[k]) idx[c++] = i; }
  geo.index.needsUpdate = true;
  geo.setDrawRange(0, c);
  m.hidden = owner.length - c;
}

function applyMeshMask(mesh, hide) {
  const m = mesh.userData.mask;
  if (!m) return;
  const geo = mesh.geometry, idx = geo.index.array, tris = m.ownedTris, own = m.ownedOwner;
  let w = m.unowned;
  for (let o = 0; o < own.length; o++) {
    if (hide[own[o]]) continue;
    idx[3 * w] = tris[3 * o]; idx[3 * w + 1] = tris[3 * o + 1]; idx[3 * w + 2] = tris[3 * o + 2];
    w++;
  }
  if (geo.index.addUpdateRange) {
    geo.index.clearUpdateRanges();
    // 앞쪽(가구 아닌 삼각형)이 이미 GPU 에 올라가 있으면 바뀐 뒤쪽만 보낸다. 아직이면 범위를 두지 않아 전체가 올라간다
    if (m.synced) geo.index.addUpdateRange(m.unowned * 3, own.length * 3);
  }
  geo.index.needsUpdate = true;
  geo.setDrawRange(0, w * 3);
  m.hidden = own.length - (w - m.unowned);
}

// 스캔에서 숨길 가구.
//   점구름: 뺀 가구 + 가구 GLB 가 따로 떠 있는 가구 (점구름은 가구를 모두 담고 있어 GLB 와 두 겹이 된다)
//   방 메시: 뺀 가구 중 가구 GLB 가 없는 것만. 가구 GLB 가 있는 가구는 room.glb 에서 이미 잘려 있다(백엔드 11.19) → 그 자리 벽 · 바닥을 건드리지 않는다
//   단, 장면 파일에서 이미 빠져 있는 가구(서버가 만든 입주 예상 PLY)는 다시 가리지 않는다
function scanHiddenIds(removed) {
  const s = new Set(removed);
  const points = !!scan?.root?.isPoints;
  for (const id of objectModels.keys()) { if (points) s.add(id); else s.delete(id); }
  for (const id of sceneRemoved) s.delete(id);
  return s;
}

function applyScanMask(hiddenIds) {
  const root = scan?.root, ids = root?.userData.maskIds;
  if (!ids) return;
  const flags = ids.map((id) => (hiddenIds.has(id) ? 1 : 0)), key = flags.join('');
  if (root.userData.hiddenKey === key) return;
  root.userData.hiddenKey = key;
  const hide = Uint8Array.from(flags);
  if (root.isPoints) applyPointsMask(root, hide);
  else root.traverse((c) => { if (c.isMesh) applyMeshMask(c, hide); });
}

// 방과 따로 온 가구 GLB (objects[].modelUri). 백엔드 규칙(11.19): 원점 = 가구 바운딩 박스 중심인 로컬 좌표, position = 방 안의 중심,
// rotation.yaw = Y축 회전(도), 미터 → 기본값 'center'. GLB 가 원점에 놓여 있지 않으면(방 좌표로 저장된 경우 등) 범위를 보고 다시 고른다.
// objectFrame = GLB 가 어떤 좌표로 저장됐나:
//   'center' 원점 = 상자 중심, 축은 상자에 맞춤(yaw 0) · 'auto' GLB 범위를 보고 아래 중에서 고른다 · 'floor' 원점 = 상자 바닥 중심
//   · 'world' 이미 방(ARKit) 좌표 · 'center-raw' · 'floor-raw' 원점은 그렇지만 이미 yaw 만큼 돌아가 있음 · 'fit' 치수에 맞춰 늘리고 바닥 중심에
// 가구 하나를 못 읽어도 방은 연다. 늦게 끝난 호출이면 false
async function loadObjectModels(objects, removed, sceneFrame, stale) {
  const wanted = new Map(objects.filter((o) => o.modelUrl).map((o) => [o.objectId, o]));
  for (const [id, m] of [...objectModels]) {              // 이번 장면에 없는 가구 · 주소가 바뀐 가구는 지운다
    if (wanted.get(id)?.modelUrl === m.url) continue;
    scanGroup.remove(m.group);
    disposeTree(m.group);
    objectModels.delete(id);
  }
  for (const [id, o] of wanted) {
    let m = objectModels.get(id);
    if (!m) {
      try {
        const gltf = await (await gltfLoaderWithDecoders()).loadAsync(o.modelUrl);
        if (stale()) { disposeTree(gltf.scene); return false; }
        const b = new THREE.Box3().setFromObject(gltf.scene);       // GLB 자기 좌표에서의 범위 (좌표 기준 판단용)
        const group = new THREE.Group();
        group.add(prepareScan(gltf.scene));
        scanGroup.add(group);
        m = { url: o.modelUrl, group, box: b.isEmpty() ? null : { center: b.getCenter(new THREE.Vector3()), size: b.getSize(new THREE.Vector3()) } };
        objectModels.set(id, m);
      } catch (e) {
        console.warn('가구 모델을 읽지 못했습니다', id, e?.message || e);
        continue;
      }
    }
    placeObjectModel(m, o, o.modelFrame || sceneFrame || 'center');
    m.group.visible = !removed.has(id);
    objectMeshes.set(id, m.group);
  }
  return !stale();
}

function placeObjectModel(m, o, frame) {
  const group = m.group, model = group.children[0], dm = o.dimensions;
  model.position.set(0, 0, 0);
  model.scale.set(1, 1, 1);
  group.rotation.set(0, 0, 0);
  if (frame === 'auto') frame = m.box ? detectFrame(m.box, o) : 'center';
  else if (frame === 'center' && m.box && offCenter(m.box, o)) {
    frame = detectFrame(m.box, o);                     // 규칙과 달리 원점에서 멀리 있는 GLB → 범위로 자리를 다시 고른다
    console.warn('가구 GLB 가 원점(상자 중심)에 있지 않아 범위로 자리를 고름', o.objectId, frame);
  }
  m.frame = frame;
  if (frame === 'world') { group.position.set(0, 0, 0); return; }
  const raw = frame.endsWith('-raw'), base = raw ? frame.slice(0, -4) : frame;
  if (base === 'fit') fitToDims(model, dm);
  const y = base === 'floor' || base === 'fit' ? o.position.y - dm.height / 2 : o.position.y;
  group.position.set(o.position.x, y, o.position.z);
  group.rotation.y = raw ? 0 : (o.rotation?.yaw ?? 0) * D2R;
}

// GLB 범위의 가운데가 원점에서 상자 크기의 1/4 이상(+5 cm) 떨어져 있으면 '상자 중심 원점'이 아니다
function offCenter(box, o) {
  const d = o.dimensions, c = box.center;
  return Math.hypot(c.x, c.y, c.z) > 0.25 * Math.hypot(d.width, d.height, d.depth) + 0.05;
}

// GLB 범위(가운데 · 크기)가 어느 저장 방식과 가장 잘 맞는가. 같으면 앞의 것(상자 중심)을 고른다.
// 크기가 어느 것과도 크게 다르면(단위가 다르거나 크기를 맞추지 않은 모델) 치수에 맞춰 늘린다(fit)
function detectFrame(box, o) {
  const d = o.dimensions, th = (o.rotation?.yaw ?? 0) * D2R, c = Math.abs(Math.cos(th)), s = Math.abs(Math.sin(th));
  const canon = [d.width, d.height, d.depth];
  const turned = [d.width * c + d.depth * s, d.height, d.width * s + d.depth * c];      // yaw 만큼 돈 상자의 축 정렬 범위
  const P = o.position, diag = Math.hypot(d.width, d.height, d.depth) || 1, sum = d.width + d.height + d.depth || 1;
  const cands = [
    ['center', [0, 0, 0], canon], ['floor', [0, d.height / 2, 0], canon], ['world', [P.x, P.y, P.z], turned],
    ['center-raw', [0, 0, 0], turned], ['floor-raw', [0, d.height / 2, 0], turned],
  ];
  const bc = box.center, bs = box.size;
  let best = null;
  for (const [name, ec, es] of cands) {
    const pe = Math.hypot(bc.x - ec[0], bc.y - ec[1], bc.z - ec[2]) / diag;
    const se = (Math.abs(bs.x - es[0]) + Math.abs(bs.y - es[1]) + Math.abs(bs.z - es[2])) / sum;
    if (!best || pe + se < best.score - 1e-6) best = { name, score: pe + se, se };
  }
  return best.se > 0.5 ? 'fit' : best.name;
}

// 서버가 방 구조(roomGeometry)를 안 줬으면 방 메시의 크기에서 바닥 · 천장 · 범위를 잡고 앱에 알린다
function adoptScanBounds() {
  const target = scan?.root || (splat ?? null);
  if (!target) return;
  const b = new THREE.Box3().setFromObject(target);
  if (b.isEmpty() || !Number.isFinite(b.min.x)) return;
  const v = (p) => ({ x: p.x, y: p.y, z: p.z });
  room = { ...room, floorY: b.min.y, ceilingY: b.max.y, bboxMin: v(b.min), bboxMax: v(b.max) };
  post({ type: 'bounds', min: room.bboxMin, max: room.bboxMax });
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
    if (o.modelUrl) continue;                   // 가구 GLB 가 따로 오면 loadObjectModels 가 그린다
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
      const gltf = await (await gltfLoaderWithDecoders()).loadAsync(f.url);
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
  applyScanMask(scanHiddenIds(s));
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

// 라벨 겹침 줄이기: 화면에서 겹치는 라벨은 가까운 것을 그대로 두고, 먼 것을 겹치지 않는 자리까지 아래로 민다.
// 매 프레임 CSS2DRenderer 가 자리를 잡은 뒤에 돈다(그 transform 뒤에 translateY 를 덧붙이고, 다음 프레임에 새로 계산).
// 가구 상자가 붙어 있으면(책상 · 의자) 치수 라벨이 겹쳐 읽을 수 없던 문제 (실서버 시험 매물, 11.19)
const _lv = new THREE.Vector3();
function declutterLabels() {
  if (!overlayOn) return;
  const hw = innerWidth / 2, hh = innerHeight / 2, items = [];
  overlay.traverseVisible((o) => {
    if (!o.isCSS2DObject) return;
    const el = o.element;
    if (el.style.display === 'none' || !el.parentNode) return;
    _lv.setFromMatrixPosition(o.matrixWorld).project(camera);
    if (_lv.z < -1 || _lv.z > 1) return;
    if (!el._lw) { el._lw = el.offsetWidth; el._lh = el.offsetHeight; }   // 글자는 바뀌지 않으므로 한 번만 잰다
    if (!el._lw) return;
    items.push({ el, x: _lv.x * hw + hw, y: -_lv.y * hh + hh, w: el._lw, h: el._lh, z: _lv.z });
  });
  if (items.length < 2) return;
  items.sort((a, b) => a.z - b.z);                    // 가까운 라벨이 제자리
  const placed = [];
  for (const it of items) {
    const left = it.x - it.w / 2, right = it.x + it.w / 2;
    let top = it.y - it.h / 2;
    for (let pass = 0; pass < 8; pass++) {
      const hit = placed.find((p) => left < p.right && right > p.left && top < p.bottom && top + it.h > p.top);
      if (!hit) break;
      top = hit.bottom + 2;
    }
    const dy = top - (it.y - it.h / 2);
    if (dy > 0.5) it.el.style.transform += ` translateY(${dy.toFixed(1)}px)`;
    placed.push({ left, right, top, bottom: top + it.h });
  }
}

renderer.setAnimationLoop(() => {
  updatePointSize();
  if (room) {
    if (mode !== 'walk') { controls.update(); updateCutaway(); }
    else { camera.position.copy(walk.pos); camera.rotation.set(walk.pitch, walk.yaw, 0, 'YXZ'); }
  }
  renderer.render(scene, camera);
  labels.render(scene, camera);
  declutterLabels();
});

window.DV = {
  loadScene, setMode, resetView, setOverlay, setObjectOwnership, setRemovedObjects,
  debugInfo: () => {
    const root = scan?.root;
    const frames = Object.fromEntries([...objectModels].map(([id, m]) => [id, m.frame]));
    if (!root) return { scan: null, frames };
    if (root.isPoints) {
      const m = root.userData.mask;
      return { scan: 'points', points: root.geometry.getAttribute('position').count, drawn: root.geometry.drawRange.count,
               footprint: root.userData.footprint, size: root.material.size, hidden: m?.hidden ?? 0,
               owned: m ? m.owner.reduce((a, v) => a + (v >= 0 ? 1 : 0), 0) : 0, maskMs: root.userData.maskMs, frames };
    }
    let tris = 0, owned = 0, hidden = 0;
    root.traverse((c) => {
      if (!c.isMesh) return;
      const g = c.geometry, mk = c.userData.mask;
      tris += Math.floor((g.index ? g.index.count : g.getAttribute('position').count) / 3);
      if (mk) { owned += mk.ownedOwner.length; hidden += mk.hidden; }
    });
    return { scan: 'mesh', tris, owned, hidden, maskMs: root.userData.maskMs, frames };
  },
  addFurniture, setFurnitureState, setFurnitureTransform, removeFurniture, select,
};
post({ type: 'ready' });
