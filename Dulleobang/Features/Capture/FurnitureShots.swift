import Foundation
import simd

// MARK: - 가구 '전체 사진' 점검 (방 촬영 · LiDAR + RoomPlan)
//
// 가구마다 "전체가 한 화면에, 가려지지 않고, 충분히 크게" 찍힌 저장 프레임이 있는지 본다.
// RoomPlan 이 촬영 중에 계속 고쳐 주는 가구 상자(위치 · 방향 · 크기)와 프레임마다의 카메라 포즈 · LiDAR 깊이만 쓰고
// ARKit 에 의존하지 않아 테스트할 수 있다. CaptureRecorder 가 10 Hz 폴링마다 메인 스레드에서 부른다.
//  1. 화면 안: 상자 꼭짓점 8개가 모두 화면 안 (가장자리 2% 여유)
//  2. 안 가려짐: 카메라 쪽을 향한 옆면 · 윗면에 면마다 5 × 5 점을 찍어 LiDAR 깊이와 비교한다. 상자 면보다 확실히
//     (10 cm + 거리의 3%) 앞에 무언가 있으면 그 점은 가려진 것 — 단 앞을 가린 것이 가구 자신 · 위에 놓인 물건(컵 · 책 · TV) ·
//     바닥 · 이 가구에 붙은 더 작은 가구(식탁에 넣은 의자)면 치지 않는다. 전체 85% 이상, 면마다 60% 이상 보여야 통과
//  3. 충분히 크게: 화면 가로나 세로의 30% 이상
//  4. 선명: 저장 순간 예상 흔들림 6 px 이하
// 통과한 '저장된' 프레임이 생기면 그 가구는 ✓. 같은 종류 · 같은 크기(±6 cm) 가구(식탁 의자 6개 등)는 하나만 찍혀도 함께 ✓.
// 촬영을 마치면 RoomPlan 최종 상자로 저장한 프레임을 모두 다시 점검해 furniture_shots.json 을 쓴다
// (가구별 대표 사진 최대 3장 + 화면 속 상자 위치 → SAM 3 상자 프롬프트, SAM 3D 단일 사진 입력, 재질 다시 입히기 등).
// 방이 좁아 다 안 들어오면: 폰을 돌리면 되는 경우(센서 긴 쪽 약 65° · 짧은 쪽 약 51°) 가로/세로로 돌리라고 안내하고,
// 그래도 안 되면 촬영을 마친 뒤 0.5× 광각으로 찍게 한다 (WideShotTarget · UltraWideShots.swift).

/// RoomPlan 가구 상자 (CapturedRoom.Object 를 ARKit 없이 쓰는 사본)
struct FurnitureBox {
    var id: String                       // CapturedRoom.Object.identifier
    var category: String                 // "table", "chair" … (CapturedRoom.Object.Category)
    var transform: simd_float4x4         // 상자 중심 · 방향 (ARKit 월드, y 위)
    var dimensions: SIMD3<Float>         // 가로(x) · 높이(y) · 깊이(z), m

    var center: SIMD3<Float> { transform.columns.3.xyz }
    var half: SIMD3<Float> { dimensions / 2 }
    var volume: Float { dimensions.x * dimensions.y * dimensions.z }

    /// 상자의 단위 축 (가로 · 높이 · 깊이 방향)
    var axes: (x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) {
        (simd_normalize(transform.columns.0.xyz), simd_normalize(transform.columns.1.xyz),
         simd_normalize(transform.columns.2.xyz))
    }

    /// 월드 점 → 상자 좌표 (중심이 원점, 상자 축 기준)
    func local(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let a = axes, d = p - center
        return SIMD3(simd_dot(d, a.x), simd_dot(d, a.y), simd_dot(d, a.z))
    }

    func contains(_ p: SIMD3<Float>, margin: Float = 0) -> Bool {
        let q = local(p), h = half
        return abs(q.x) <= h.x + margin && abs(q.y) <= h.y + margin && abs(q.z) <= h.z + margin
    }
}

/// LiDAR 깊이를 화면 전체에 고르게 뽑은 격자 (보통 64 × 48, 칸 가운데 값, 카메라 z 축 거리 m).
/// 0 = 측정 없음 · 신뢰도 낮음 · 0.2 ~ 5 m 밖 (FrameProbe.depthGrid)
struct DepthGrid {
    let cols: Int
    let rows: Int
    var meters: [Float]                  // 행 우선 (rows × cols)

    /// 컬러 픽셀 (u, v) 가 속한 칸의 깊이. 화면 밖이거나 측정이 없으면 nil
    func depth(u: Float, v: Float, width: Int, height: Int) -> Float? {
        guard u >= 0, v >= 0, width > 0, height > 0 else { return nil }
        let c = Int(u / Float(width) * Float(cols)), r = Int(v / Float(height) * Float(rows))
        guard c < cols, r < rows, r * cols + c < meters.count else { return nil }
        let d = meters[r * cols + c]
        return d > 0 ? d : nil
    }
}

/// 점검할 한 프레임 (라이브 프레임 또는 저장한 프레임)
struct ShotView {
    var frameId: Int?                    // 저장한 프레임이면 poses.json 의 frameId
    var time: Double
    var transform: simd_float4x4         // 카메라 → 월드 (ARKit: x 오른쪽, y 위, -z 정면, 센서 원래 방향 = 가로)
    var fx: Float, fy: Float, cx: Float, cy: Float   // 컬러 해상도 기준 (ARCamera.intrinsics)
    var width: Int, height: Int          // 컬러 해상도 (보통 1920 × 1440)
    var depth: DepthGrid
    var blurPx: Double = 0               // 예상 흔들림 (px, CaptureCoach.frameBlurPx)
}

/// 가구 하나 × 프레임 하나 점검 결과
struct ShotCheck {
    enum Problem: String, Codable { case notInView, notWhole, blocked, tooFar, blurry }
    var problem: Problem?                // nil = 전체 사진으로 통과
    var inView = false                   // 가구가 화면에 걸려 있는지 (안내용)
    var visible: Double?                 // 카메라 쪽 면 중 안 가려진 비율 (LiDAR 점이 모자라면 nil = 모름)
    var fill = 0.0                       // 화면 가로 · 세로 대비 차지하는 비율 중 큰 값
    var blockerId: String?               // 가장 많이 가린 다른 가구 (가구가 아닌 것 · 사람이 가리면 nil)
    var score = 0.0                      // 대표 사진 고르기용 (높을수록 좋음)
    var bbox: SIMD4<Float>?              // 화면 속 상자 범위 (u0, v0, u1, v1 · 컬러 픽셀, 화면 밖은 잘라 냄)
    var viewYawDeg: Float = 0            // 가구 중심에서 본 카메라의 수평 방향 (도) → 서로 다른 방향의 사진 고르기
    var distanceM: Float = 0
    var cutU = false                     // 꼭짓점이 센서 긴 축(u, 1920 쪽 · 약 65°)으로 화면을 벗어남 (카메라 바로 앞 · 뒤 포함)
    var cutV = false                     // 센서 짧은 축(v, 1440 쪽 · 약 51°)으로 벗어남 → 폰을 돌리면 긴 축이 그쪽으로 간다
    var passed: Bool { problem == nil }
}

/// 기준값. 실제 촬영본의 furniture_shots.json 을 보며 조정한다
struct FurnitureShotConfig {
    var marginFrac: Float = 0.02          // 꼭짓점이 화면 가장자리에서 이만큼(비율) 안쪽
    var minFill = 0.30                    // 화면 가로나 세로의 이만큼 이상 차지
    var minVisible = 0.85                 // 카메라 쪽 면 전체 중 안 가려진 비율
    var minFaceVisible = 0.60             // 면 하나라도 이보다 많이 가려지면 '가려짐'
    var minFaceSamples = 8                // 면별 판정에 필요한 LiDAR 점 수
    var maxBlurPx = 6.0                   // 저장 순간 예상 흔들림 (px)
    var minDepthSamples = 12              // 이보다 적게 재지면 가려짐을 모른다고 본다 (먼 가구 · 깊이 없음)
    var faceGrid = 5                      // 면마다 5 × 5 점
    var faceInset: Float = 0.12           // 면 가장자리에서 이만큼(비율) 안쪽에만 점을 찍는다
    var facingCos: Float = 0.25           // 면이 카메라 쪽을 향했다고 볼 최소 cos (비스듬히 스치는 면은 뺀다)
    var occlusionTolM: Float = 0.10       // LiDAR 가 상자 면보다 이만큼 + 거리 × occlusionTolPerM 넘게 가까우면 '앞에 무언가 있음'
    var occlusionTolPerM: Float = 0.03
    var selfMarginM: Float = 0.05         // 앞을 가린 점이 상자 ± 이만큼 안이면 가구 자신
    var onTopM: Float = 0.6               // 윗면 위로 이만큼까지는 위에 놓인 물건(컵 · 책 · TV)으로 본다
    var floorBandM: Float = 0.05          // 상자 바닥 + 이만큼 아래는 바닥
    var attachMarginM: Float = 0.10       // 이만큼 안으로 붙은 더 작은 가구(식탁 의자)는 가린 것으로 치지 않는다
    var minNearM: Float = 0.25            // 카메라 앞 이만큼보다 가까운 꼭짓점은 화면 밖으로 본다
    var twinTolM: Float = 0.06            // 같은 종류 · 크기 차가 이 이하 = 같은 모양 가구
    var shotsPerObject = 3                // furniture_shots.json 에 가구마다 넣는 대표 사진 수
    var minShotYawGapDeg: Float = 40      // 대표 사진끼리 바라보는 방향이 이만큼 달라야 한다
    var keepCandidates = 40               // 가구마다 보관하는 통과 프레임 수
    var recheckMoveM: Float = 0.08        // RoomPlan 상자가 이만큼 움직이거나 크기가 바뀌면 저장한 프레임으로 다시 점검
    var recheckYawDeg: Float = 8
    var tuckedShare = 0.15                // 부피의 이 비율 이상이 다른 가구 상자 안 = 그 가구 밑에 넣은 것 (식탁 의자)
    var liveStaleS = 0.5                  // 라이브 점검이 이보다 오래됐으면 화면 밖으로 본다
    var reasonHoldS = 0.6                 // 안내 이유가 바뀌려면 이만큼 이어져야 한다 (깜빡임 방지)
    var guideAfterS = 60.0                // 첫 바퀴를 못 끝내도 이 시간이 지나면 안내를 띄운다
    var wideHintAfterS = 8.0              // 같은 가구가 이만큼 '다 안 들어와요' 면 "촬영을 마칠 때 0.5× 광각으로" 를 안내
    var wideCameraAvailable = false       // 0.5× 광각 카메라가 있는 기기 (CaptureRecorder 가 UltraWideCamera.isAvailable 로 채움)
    var excludedCategories: Set<String> = ["stairs"]   // 전체 사진을 요구하지 않는 종류
}

/// 가구 하나의 전체 사진 상태 (JSON 값: full · shared · missing)
enum FurnitureShotState: String, Codable {
    case done = "full"                    // 전체 사진 있음
    case shared                           // 같은 모양 가구의 전체 사진으로 대신 (식탁 의자 등)
    case pending = "missing"              // 아직 없음
}

/// 화면 위 가구 목록의 한 칸
struct FurnitureChip: Identifiable, Equatable {
    let id: String
    let label: String                     // "의자 2"
    let symbol: String                    // SF Symbol
    let state: FurnitureShotState
}

/// 첫 바퀴 뒤 화면 아래에 띄우는 안내 (아직 전체 사진이 없는 가구 하나)
struct FurnitureTip: Equatable {
    enum Turn: Equatable { case left, right, behind }
    let objectId: String
    let label: String                     // "소파", "의자 2"
    let name: String                      // 번호 없는 종류 이름 ("의자")
    let problem: ShotCheck.Problem
    let blockerLabel: String?             // 가린 가구 ("테이블")
    let turn: Turn?                       // 화면 밖이면 어느 쪽으로 돌아야 하는지
    let hasTwins: Bool                    // 같은 모양 가구가 또 있음 → 하나만 다 보이면 된다고 알려 준다
    var suggestion: Suggestion? = nil     // 다 안 들어올 때 덧붙이는 방법

    enum Suggestion: Equatable {
        case rotateToLandscape            // 세로로 든 폰에서 좌우로 넘침 → 가로로 들면 좌우가 넓은 쪽(약 65°)이 된다
        case rotateToPortrait             // 가로로 든 폰에서 위아래로 넘침 → 세로로 들기
        case wideAfterScan                // 물러설 곳이 없음 → 촬영을 마칠 때 0.5× 광각으로
    }

    var title: String {
        switch problem {
        case .notInView: return "\(label) 전체 사진이 아직 없어요"
        case .notWhole: return "\(Josa.iGa(label)) 화면에 다 안 들어와요"
        case .blocked:
            if let b = blockerLabel { return "\(Josa.iGa(label)) \(b)에 가려져 있어요" }
            return "\(Josa.iGa(label)) 가려져 있어요"
        case .tooFar: return "\(Josa.iGa(label)) 너무 작게 보여요"
        case .blurry: return "\(label) 사진이 흔들렸어요"
        }
    }

    var detail: String {
        switch problem {
        case .notInView:
            switch turn {
            case .left?: return "왼쪽으로 돌아 \(label) 전체가 한 화면에 들어오게 찍어 주세요"
            case .right?: return "오른쪽으로 돌아 \(label) 전체가 한 화면에 들어오게 찍어 주세요"
            case .behind?: return "뒤로 돌아 \(label) 전체가 한 화면에 들어오게 찍어 주세요"
            case nil: return "\(label) 전체가 한 화면에 들어오게 찍어 주세요"
            }
        case .notWhole:
            switch suggestion {
            case .rotateToLandscape?: return "폰을 가로로 돌려 찍으면 옆으로 더 넓게 들어와요 (또는 한두 걸음 물러나기)"
            case .rotateToPortrait?: return "폰을 세로로 돌려 찍으면 위아래로 더 넓게 들어와요 (또는 한두 걸음 물러나기)"
            case .wideAfterScan?: return "물러설 공간이 없으면 그대로 두세요. 촬영을 마칠 때 0.5× 광각으로 한 장 찍을 수 있어요"
            case nil: return "한두 걸음 물러나 \(label) 전체가 한 화면에 들어오게 해 주세요"
            }
        case .blocked:
            if hasTwins { return "같은 모양 \(name) 중 하나만 다 보이면 돼요. 가리는 것이 없는 쪽에서 찍어 주세요" }
            return "가리는 것이 없는 쪽으로 옮겨 가서 찍어 주세요"
        case .tooFar: return "조금 더 가까이 가서 찍어 주세요 (전체가 화면에 다 들어오는 데까지)"
        case .blurry: return "잠깐 멈춰서 찍어 주세요"
        }
    }

    var icon: String {
        switch problem {
        case .notInView:
            switch turn {
            case .left?: return "arrow.turn.up.left"
            case .right?: return "arrow.turn.up.right"
            case .behind?: return "arrow.uturn.down"
            case nil: return "viewfinder"
            }
        case .notWhole:
            switch suggestion {
            case .rotateToLandscape?, .rotateToPortrait?: return "rotate.right"
            case .wideAfterScan?: return "camera.aperture"
            case nil: return "arrow.up.left.and.arrow.down.right"
            }
        case .blocked: return "eye.slash.fill"
        case .tooFar: return "plus.magnifyingglass"
        case .blurry: return "hand.raised.fill"
        }
    }
}

/// 받침에 맞는 조사 (소파가 · 테이블이 · 의자 1이 · 의자 2가 · TV가)
enum Josa {
    static func hasBatchim(_ word: String) -> Bool {
        guard let last = word.unicodeScalars.last(where: { $0 != " " }) else { return false }
        let v = last.value
        if v >= 0xAC00, v <= 0xD7A3 { return (v - 0xAC00) % 28 != 0 }
        return "013678".unicodeScalars.contains(last)        // 숫자는 읽는 소리로 (영 · 일 · 삼 · 육 · 칠 · 팔)
    }

    static func iGa(_ word: String) -> String { word + (hasBatchim(word) ? "이" : "가") }
    static func eulReul(_ word: String) -> String { word + (hasBatchim(word) ? "을" : "를") }
}

/// RoomPlan 가구 종류 → 화면에 쓰는 이름 · 아이콘
enum FurnitureNames {
    static func name(_ category: String) -> String {
        switch category {
        case "storage": return "수납장"
        case "refrigerator": return "냉장고"
        case "stove": return "레인지"
        case "bed": return "침대"
        case "sink": return "싱크대"
        case "washerDryer": return "세탁기"
        case "toilet": return "변기"
        case "bathtub": return "욕조"
        case "oven": return "오븐"
        case "dishwasher": return "식기세척기"
        case "table": return "테이블"
        case "sofa": return "소파"
        case "chair": return "의자"
        case "fireplace": return "벽난로"
        case "television": return "TV"
        case "stairs": return "계단"
        default: return "가구"
        }
    }

    static func symbol(_ category: String) -> String {
        switch category {
        case "storage": return "cabinet"
        case "refrigerator": return "refrigerator"
        case "stove": return "stove"
        case "bed": return "bed.double"
        case "sink": return "sink"
        case "washerDryer": return "washer"
        case "toilet": return "toilet"
        case "bathtub": return "bathtub"
        case "oven": return "oven"
        case "dishwasher": return "dishwasher"
        case "table": return "table.furniture"
        case "sofa": return "sofa"
        case "chair": return "chair"
        case "fireplace": return "fireplace"
        case "television": return "tv"
        default: return "shippingbox"
        }
    }
}

// MARK: - 한 프레임 점검 (순수 계산)

enum FurnitureShotMath {
    /// 앞을 가린 점이 무엇인지
    enum Occluder: Equatable { case ignored, furniture(String), unknown }

    /// box 가 view 에서 '전체 사진' 인지 본다. others = 지금 RoomPlan 이 아는 가구 상자 전부 (box 포함 가능)
    static func check(_ box: FurnitureBox, in view: ShotView, others: [FurnitureBox],
                      config c: FurnitureShotConfig = FurnitureShotConfig()) -> ShotCheck {
        let T = view.transform
        let R = simd_float3x3(T.columns.0.xyz, T.columns.1.xyz, T.columns.2.xyz)
        let Rt = R.transpose
        let cam = T.columns.3.xyz
        let W = Float(view.width), H = Float(view.height)
        func toCam(_ p: SIMD3<Float>) -> SIMD3<Float> { Rt * (p - cam) }
        // 카메라 좌표(x 오른쪽, y 위, -z 정면) → 컬러 픽셀. 카메라 앞 minNearM 보다 가까우면 nil
        func project(_ pc: SIMD3<Float>) -> SIMD2<Float>? {
            let z = -pc.z
            guard z > c.minNearM else { return nil }
            return SIMD2(view.fx * pc.x / z + view.cx, view.fy * -pc.y / z + view.cy)
        }
        func onScreen(_ p: SIMD2<Float>) -> Bool { p.x >= 0 && p.x < W && p.y >= 0 && p.y < H }

        var out = ShotCheck()
        let center = box.center, h = box.half, a = box.axes
        out.distanceM = simd_distance(cam, center)
        out.viewYawDeg = atan2(cam.x - center.x, cam.z - center.z) * 180 / .pi

        // 1. 꼭짓점 8개가 모두 화면 안인지
        var corners: [SIMD2<Float>] = []
        var allIn = true
        var onScreenCount = 0
        let mW = c.marginFrac * W, mH = c.marginFrac * H
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    let p = center + a.x * (h.x * sx) + a.y * (h.y * sy) + a.z * (h.z * sz)
                    guard let uv = project(toCam(p)) else {          // 카메라 바로 앞 · 뒤 = 너무 가까움 (돌려도 안 됨)
                        allIn = false; out.cutU = true; out.cutV = true
                        continue
                    }
                    corners.append(uv)
                    if onScreen(uv) { onScreenCount += 1 }
                    if uv.x < mW || uv.x > W - mW { allIn = false; out.cutU = true }
                    if uv.y < mH || uv.y > H - mH { allIn = false; out.cutV = true }
                }
            }
        }
        let centerOnScreen = project(toCam(center)).map(onScreen) ?? false
        out.inView = centerOnScreen || onScreenCount >= 4
        if !corners.isEmpty {
            let us = corners.map { min(max($0.x, 0), W) }, vs = corners.map { min(max($0.y, 0), H) }
            let b = SIMD4(us.min() ?? 0, vs.min() ?? 0, us.max() ?? 0, vs.max() ?? 0)
            out.bbox = b
            out.fill = Double(max((b.z - b.x) / W, (b.w - b.y) / H))
        }

        // 2. 카메라 쪽 면(옆면 4 · 윗면)에 점을 찍어 LiDAR 깊이와 비교
        struct Face { var n, u, v: SIMD3<Float>; var hn, hu, hv: Float; var isTop: Bool }
        let faces = [Face(n: a.x, u: a.y, v: a.z, hn: h.x, hu: h.y, hv: h.z, isTop: false),
                     Face(n: -a.x, u: a.y, v: a.z, hn: h.x, hu: h.y, hv: h.z, isTop: false),
                     Face(n: a.z, u: a.x, v: a.y, hn: h.z, hu: h.x, hv: h.y, isTop: false),
                     Face(n: -a.z, u: a.x, v: a.y, hn: h.z, hu: h.x, hv: h.y, isTop: false),
                     Face(n: a.y, u: a.x, v: a.z, hn: h.y, hu: h.x, hv: h.z, isTop: true)]
        var valid = 0, visible = 0, sideFacing = 0
        var topFacing = false, faceBlocked = false
        var blockers: [String: Int] = [:]                    // "" = 가구가 아닌 것
        let n = max(c.faceGrid, 2), span = 1 - 2 * c.faceInset
        for f in faces {
            let fc = center + f.n * f.hn
            let cosA = simd_dot(f.n, simd_normalize(cam - fc))
            guard cosA > c.facingCos else { continue }
            if f.isTop { topFacing = true } else if cosA > 0.3 { sideFacing += 1 }
            var fValid = 0, fVisible = 0
            for i in 0..<n {
                for j in 0..<n {
                    let s = (Float(i) / Float(n - 1) * 2 - 1) * span
                    let t = (Float(j) / Float(n - 1) * 2 - 1) * span
                    let pc = toCam(fc + f.u * (s * f.hu) + f.v * (t * f.hv))
                    guard let uv = project(pc), onScreen(uv),
                          let D = view.depth.depth(u: uv.x, v: uv.y, width: view.width, height: view.height) else { continue }
                    let d = -pc.z
                    fValid += 1
                    if D >= d - (c.occlusionTolM + c.occlusionTolPerM * d) { fVisible += 1; continue }
                    // 상자 면보다 앞에 무언가 있다 → 같은 광선 위 깊이 D 인 점이 무엇인지 본다
                    let q = R * (pc * (D / d)) + cam
                    switch occluder(q, of: box, others: others, config: c) {
                    case .ignored: fVisible += 1
                    case .furniture(let id): blockers[id, default: 0] += 1
                    case .unknown: blockers["", default: 0] += 1
                    }
                }
            }
            valid += fValid
            visible += fVisible
            if fValid >= c.minFaceSamples, Double(fVisible) / Double(fValid) < c.minFaceVisible { faceBlocked = true }
        }
        if valid >= c.minDepthSamples { out.visible = Double(visible) / Double(valid) }
        if let top = blockers.max(by: { $0.value < $1.value }), !top.key.isEmpty { out.blockerId = top.key }

        // 3. 판정 (안내에 쓰는 순서: 안 보임 → 다 안 들어옴 → 가려짐 → 작음 → 흔들림)
        if !out.inView {
            out.problem = .notInView
        } else if !allIn {
            out.problem = .notWhole
        } else if let v = out.visible, v < c.minVisible || faceBlocked {
            out.problem = .blocked
        } else if out.fill < c.minFill {
            out.problem = .tooFar
        } else if view.blurPx > c.maxBlurPx {
            out.problem = .blurry
        }
        // 대표 사진 점수: 잘 보일수록 · 클수록(화면의 55%까지) · 두 옆면과 윗면이 함께 보일수록(3/4 각도) · 선명할수록
        let v = out.visible ?? 0.8
        let size = min(1, out.fill / 0.55)
        let angle = (sideFacing >= 2 ? 1.0 : 0.75) * (topFacing ? 1.0 : 0.85)
        out.score = v * v * size * angle * max(0.5, 1 - view.blurPx / 16)
        return out
    }

    /// 상자 면보다 앞에 있는 점 q 가 무엇인지. 바닥 · 위에 놓인 물건 · 붙어 있는 더 작은 가구 · 가구 자신 = ignored
    static func occluder(_ q: SIMD3<Float>, of box: FurnitureBox, others: [FurnitureBox],
                         config c: FurnitureShotConfig) -> Occluder {
        let ql = box.local(q), h = box.half
        if ql.y < -h.y + c.floorBandM { return .ignored }                                        // 바닥
        let inFootprint = abs(ql.x) <= h.x + c.selfMarginM && abs(ql.z) <= h.z + c.selfMarginM
        if inFootprint, ql.y > h.y + c.selfMarginM, ql.y <= h.y + c.onTopM { return .ignored }    // 위에 놓인 물건
        if let o = others.first(where: { $0.id != box.id && $0.contains(q, margin: 0.02) }) {
            if o.volume < box.volume, touches(o, box, margin: c.attachMarginM) { return .ignored } // 붙어 있는 더 작은 가구
            return .furniture(o.id)
        }
        if inFootprint, ql.y <= h.y + c.selfMarginM { return .ignored }                           // 가구 자신
        return .unknown
    }

    /// 두 상자(세로로 선 상자)가 margin 안으로 닿거나 겹치는지: 높이 범위 + 바닥 사각형 분리축 검사
    static func touches(_ a: FurnitureBox, _ b: FurnitureBox, margin m: Float) -> Bool {
        let ca = a.center, cb = b.center, ha = a.half, hb = b.half
        guard abs(ca.y - cb.y) <= ha.y + hb.y + m else { return false }
        func flat(_ v: SIMD4<Float>) -> SIMD2<Float> {
            let f = SIMD2(v.x, v.z), l = simd_length(f)
            return l > 1e-6 ? f / l : SIMD2(1, 0)
        }
        let ax = flat(a.transform.columns.0), az = flat(a.transform.columns.2)
        let bx = flat(b.transform.columns.0), bz = flat(b.transform.columns.2)
        let d = SIMD2(cb.x - ca.x, cb.z - ca.z)
        for axis in [ax, az, bx, bz] {
            let ra = ha.x * abs(simd_dot(ax, axis)) + ha.z * abs(simd_dot(az, axis))
            let rb = hb.x * abs(simd_dot(bx, axis)) + hb.z * abs(simd_dot(bz, axis))
            if abs(simd_dot(d, axis)) > ra + rb + m { return false }
        }
        return true
    }

    /// 상자 부피 중 다른 가구 상자 안에 들어간 비율이 minShare 이상이면 그 가구 (식탁 밑에 넣은 의자 → 식탁)
    static func tucked(_ box: FurnitureBox, others: [FurnitureBox], minShare: Double) -> String? {
        let a = box.axes, h = box.half, n = 5
        let f = { (i: Int) -> Float in (Float(i) + 0.5) / Float(n) * 2 - 1 }
        var counts: [String: Int] = [:]
        for i in 0..<n {
            for j in 0..<n {
                for k in 0..<n {
                    let p = box.center + a.x * (h.x * f(i)) + a.y * (h.y * f(j)) + a.z * (h.z * f(k))
                    if let o = others.first(where: { $0.id != box.id && $0.contains(p) }) { counts[o.id, default: 0] += 1 }
                }
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value }),
              Double(best.value) / Double(n * n * n) >= minShare else { return nil }
        return best.key
    }

    /// 화면 밖 가구가 어느 쪽에 있는지 (수평면 기준, 20° 안쪽이면 nil = 앞)
    static func turn(from camera: simd_float4x4, to p: SIMD3<Float>) -> FurnitureTip.Turn? {
        let f3 = -camera.columns.2.xyz, o3 = p - camera.columns.3.xyz
        let f = SIMD2(f3.x, f3.z), o = SIMD2(o3.x, o3.z)
        guard simd_length(f) > 0.1, simd_length(o) > 0.1 else { return nil }
        let cross = f.y * o.x - f.x * o.y                       // > 0 이면 왼쪽 (y 위 · 오른손 좌표계)
        let yaw = atan2(-cross, simd_dot(f, o)) * 180 / .pi     // + = 오른쪽
        if abs(yaw) > 120 { return .behind }
        if yaw > 20 { return .right }
        if yaw < -20 { return .left }
        return nil
    }
}

// MARK: - 촬영 중 가구별 상태

/// 촬영 중 가구별 전체 사진 상태. CaptureRecorder 가 메인 스레드에서 쓴다.
///  - updateBoxes: RoomPlan 이 가구 상자를 고칠 때마다 (새 가구 · 많이 움직인 가구는 지금까지 저장한 프레임으로 다시 점검)
///  - evaluateLive: 10 Hz 폴링마다. 아직 전체 사진이 없는 가구가 지금 프레임에서 통과하면 true → 이 프레임을 꼭 저장한다
///  - addSaved: 프레임을 저장했을 때. 통과하면 그 가구의 전체 사진이 된다 (✓)
struct FurnitureShotTracker {
    struct Shot {
        var frameId: Int
        var check: ShotCheck
    }

    struct Track {
        var box: FurnitureBox
        var checkedBox: FurnitureBox                  // 저장 프레임을 점검할 때 쓴 상자 (많이 바뀌면 다시 점검)
        var passing: [Shot] = []                      // 통과한 저장 프레임 (점수 높은 순)
        var bestMiss: Shot?                           // 통과 못 한 저장 프레임 중 가장 나은 것
        var live: ShotCheck?                          // 마지막 라이브 점검
        var liveTime: Double?
    }

    let config: FurnitureShotConfig
    private(set) var ids: [String] = []               // 처음 발견된 순서 (목록 순서 · 번호)
    private(set) var tracks: [String: Track] = [:]
    private var allBoxes: [FurnitureBox] = []         // 가려짐 판정용 (전체 사진을 요구하지 않는 종류 포함)
    private var saved: [ShotView] = []                // 저장한 프레임 (가구가 새로 발견되거나 상자가 바뀌면 다시 점검)
    private var tipTarget: String?
    private var tipProblem: ShotCheck.Problem?
    private var tipCandidate: (problem: ShotCheck.Problem, since: Double)?
    private var tipProblemSince = 0.0                 // 지금 보여 주는 이유가 시작된 시각

    init(config: FurnitureShotConfig = FurnitureShotConfig()) { self.config = config }

    var hasFurniture: Bool { !ids.isEmpty }
    var savedCount: Int { saved.count }
    /// 지금 RoomPlan 이 아는 가구 상자 전부
    var boxes: [FurnitureBox] { allBoxes }

    /// 아직 전체 사진이 없는 가구 중 '다 안 들어옴 · 가려짐' 때문인 것이 있는지 → 끝낼 때 0.5× 광각 사진을 제안한다
    var needsWideShot: Bool {
        ids.contains { id in
            guard state(of: id) == .pending, let p = tracks[id]?.bestMiss?.check.problem else { return false }
            return p == .notWhole || p == .blocked
        }
    }

    mutating func updateBoxes(_ boxes: [FurnitureBox]) {
        allBoxes = boxes
        let usable = boxes.filter {
            !config.excludedCategories.contains($0.category) && min($0.dimensions.x, $0.dimensions.y, $0.dimensions.z) > 0.02
        }
        let incoming = Set(usable.map(\.id))
        ids.removeAll { !incoming.contains($0) }
        tracks = tracks.filter { incoming.contains($0.key) }
        for b in usable {
            if var t = tracks[b.id] {
                t.box = b
                if Self.changed(t.checkedBox, b, config) {
                    t.checkedBox = b
                    (t.passing, t.bestMiss) = shots(for: b)
                }
                tracks[b.id] = t
            } else {
                var t = Track(box: b, checkedBox: b)
                (t.passing, t.bestMiss) = shots(for: b)
                tracks[b.id] = t
                ids.append(b.id)
            }
        }
    }

    @discardableResult
    mutating func evaluateLive(_ view: ShotView) -> Bool {
        var wants = false
        for id in ids {
            guard var t = tracks[id] else { continue }
            let c = FurnitureShotMath.check(t.box, in: view, others: allBoxes, config: config)
            t.live = c
            t.liveTime = view.time
            tracks[id] = t
            if c.passed, state(of: id) == .pending { wants = true }
        }
        return wants
    }

    /// 저장한 프레임 (frameId 필수). 가구가 아직 없어도 보관해 두고, 나중에 발견되면 이 프레임들로 점검한다
    mutating func addSaved(_ view: ShotView) {
        guard let frameId = view.frameId else { return }
        saved.append(view)
        for id in ids {
            guard var t = tracks[id] else { continue }
            let c = FurnitureShotMath.check(t.box, in: view, others: allBoxes, config: config)
            Self.record(Shot(frameId: frameId, check: c), passing: &t.passing, miss: &t.bestMiss, keep: config.keepCandidates)
            tracks[id] = t
        }
    }

    func state(of id: String) -> FurnitureShotState? {
        guard let t = tracks[id] else { return nil }
        if !t.passing.isEmpty { return .done }
        return twin(of: t.box) != nil ? .shared : .pending
    }

    /// 전체 사진이 있는 같은 모양 가구의 id
    func twin(of box: FurnitureBox) -> String? {
        ids.first { id in
            guard id != box.id, let t = tracks[id], !t.passing.isEmpty else { return false }
            return Self.sameShape(t.box, box, tol: config.twinTolM)
        }
    }

    /// 같은 종류이고 가로 · 깊이(순서 무관) · 높이 차가 모두 tol 이하
    static func sameShape(_ a: FurnitureBox, _ b: FurnitureBox, tol: Float) -> Bool {
        guard a.category == b.category else { return false }
        let a1 = min(a.dimensions.x, a.dimensions.z), a2 = max(a.dimensions.x, a.dimensions.z)
        let b1 = min(b.dimensions.x, b.dimensions.z), b2 = max(b.dimensions.x, b.dimensions.z)
        return abs(a1 - b1) <= tol && abs(a2 - b2) <= tol && abs(a.dimensions.y - b.dimensions.y) <= tol
    }

    /// 목록 이름: 종류 이름 + (같은 종류가 여럿이면) 발견 순서 번호. 예: 테이블, 의자 1, 의자 2
    func labels() -> [String: String] {
        var total: [String: Int] = [:], seen: [String: Int] = [:], out: [String: String] = [:]
        for id in ids { if let t = tracks[id] { total[t.box.category, default: 0] += 1 } }
        for id in ids {
            guard let t = tracks[id] else { continue }
            let name = FurnitureNames.name(t.box.category)
            if total[t.box.category, default: 0] > 1 {
                seen[t.box.category, default: 0] += 1
                out[id] = "\(name) \(seen[t.box.category, default: 0])"
            } else {
                out[id] = name
            }
        }
        return out
    }

    func chips() -> [FurnitureChip] {
        let names = labels()
        return ids.compactMap { id in
            guard let t = tracks[id], let s = state(of: id) else { return nil }
            return FurnitureChip(id: id, label: names[id] ?? FurnitureNames.name(t.box.category),
                                 symbol: FurnitureNames.symbol(t.box.category), state: s)
        }
    }

    /// 아직 전체 사진이 없는 가구 이름 (같은 모양 가구로 대신할 수 있는 것은 뺀다)
    var missingLabels: [String] {
        let names = labels()
        return ids.filter { state(of: $0) == .pending }.compactMap { names[$0] }
    }

    /// 화면 아래 안내: 지금 화면에 걸린 미완료 가구(가장 크게 보이는 것), 없으면 가장 가까운 미완료 가구 쪽으로.
    /// 같은 가구를 계속 안내하고(다 찍히거나, 화면 밖인데 다른 미완료 가구가 화면에 들어올 때까지), 이유는 reasonHoldS 동안 이어져야 바꾼다
    mutating func tip(now: Double, camera: simd_float4x4) -> FurnitureTip? {
        let pending = ids.compactMap { tracks[$0] }.filter { state(of: $0.box.id) == .pending }
        guard !pending.isEmpty else {
            tipTarget = nil; tipProblem = nil; tipCandidate = nil
            return nil
        }
        let staleS = config.liveStaleS
        func live(_ t: Track) -> ShotCheck? {
            guard let time = t.liveTime, now - time <= staleS else { return nil }
            return t.live
        }
        let onScreen = pending.filter { live($0)?.inView == true }
        var target: Track?
        if let cur = tipTarget, let t = pending.first(where: { $0.box.id == cur }),
           live(t)?.inView == true || onScreen.isEmpty {
            target = t
        }
        if target == nil { target = onScreen.max { (live($0)?.fill ?? 0) < (live($1)?.fill ?? 0) } }
        if target == nil {
            let p = camera.columns.3.xyz
            target = pending.min { simd_distance($0.box.center, p) < simd_distance($1.box.center, p) }
        }
        guard let t = target else { return nil }
        if tipTarget != t.box.id {
            tipTarget = t.box.id; tipProblem = nil; tipCandidate = nil
        }
        let current = live(t)
        let problem: ShotCheck.Problem
        if let c = current, c.inView {
            guard let p = c.problem else { return nil }           // 지금 프레임이 통과 → 곧 저장되어 ✓ 가 된다
            problem = p
        } else {
            problem = .notInView
        }
        if let shown = tipProblem, shown != problem {
            if let cand = tipCandidate, cand.problem == problem {
                if now - cand.since >= config.reasonHoldS {
                    tipProblem = problem; tipProblemSince = cand.since; tipCandidate = nil
                }
            } else {
                tipCandidate = (problem: problem, since: now)
            }
        } else {
            if tipProblem == nil { tipProblemSince = now }
            tipProblem = problem
            tipCandidate = nil
        }
        let shown = tipProblem ?? problem
        // 다 안 들어올 때: 센서 짧은 축(v) 쪽으로만 넘치면 폰을 돌려 긴 축을 그쪽으로. 오래 못 찍으면 촬영을 마칠 때 0.5× 광각
        var suggestion: FurnitureTip.Suggestion?
        if shown == .notWhole, let c = current, c.inView {
            let up = SIMD3<Float>(0, 1, 0)
            let portrait = abs(simd_dot(simd_normalize(camera.columns.0.xyz), up)) > 0.7   // 센서 긴 축이 세로 = 폰을 세로로 듦
            let landscape = abs(simd_dot(simd_normalize(camera.columns.1.xyz), up)) > 0.7
            if c.cutV, !c.cutU { suggestion = portrait ? .rotateToLandscape : (landscape ? .rotateToPortrait : nil) }
            let waited = now - tipProblemSince
            if config.wideCameraAvailable, waited >= config.wideHintAfterS,
               suggestion == nil || waited >= 2 * config.wideHintAfterS {
                suggestion = .wideAfterScan
            }
        }
        let names = labels()
        let name = FurnitureNames.name(t.box.category)
        let hasTwins = ids.contains { id in
            id != t.box.id && (tracks[id].map { Self.sameShape($0.box, t.box, tol: config.twinTolM) } ?? false)
        }
        return FurnitureTip(objectId: t.box.id, label: names[t.box.id] ?? name, name: name, problem: shown,
                            blockerLabel: shown == .blocked ? current?.blockerId.flatMap { names[$0] } : nil,
                            turn: shown == .notInView ? FurnitureShotMath.turn(from: camera, to: t.box.center) : nil,
                            hasTwins: hasTwins, suggestion: suggestion)
    }

    /// 촬영을 마칠 때: 최종 가구 상자(nil 이면 마지막 라이브 상자)로 저장한 프레임을 모두 다시 점검해 furniture_shots.json 을 만든다
    func report(finalBoxes: [FurnitureBox]?) -> FurnitureShotsFile {
        var fresh = FurnitureShotTracker(config: config)
        fresh.saved = saved
        fresh.updateBoxes(finalBoxes ?? allBoxes)
        let names = fresh.labels()
        let entries: [FurnitureShotsFile.Entry] = fresh.ids.compactMap { id in
            guard let t = fresh.tracks[id], let st = fresh.state(of: id) else { return nil }
            var e = FurnitureShotsFile.Entry(objectId: id, category: t.box.category,
                                             label: names[id] ?? t.box.category, status: st.rawValue)
            if st == .done {
                e.shots = Self.diverse(t.passing, count: config.shotsPerObject, gapDeg: config.minShotYawGapDeg)
                    .map { FurnitureShotsFile.Shot($0) }
            } else {
                e.sharedWith = st == .shared ? fresh.twin(of: t.box) : nil
                if let m = t.bestMiss {
                    e.shots = [FurnitureShotsFile.Shot(m)]
                    e.problem = m.check.problem?.rawValue
                    e.blockedBy = m.check.blockerId
                }
            }
            e.tuckedInto = FurnitureShotMath.tucked(t.box, others: fresh.allBoxes, minShare: config.tuckedShare)
            return e
        }
        let rule = FurnitureShotsFile.Rule(minVisible: config.minVisible, minFaceVisible: config.minFaceVisible,
                                           minFill: config.minFill, maxBlurPx: config.maxBlurPx,
                                           marginFrac: Double(config.marginFrac), twinTolM: Double(config.twinTolM))
        return FurnitureShotsFile(rule: rule, frameCount: saved.count, objects: entries)
    }

    // MARK: 내부

    /// 저장한 모든 프레임으로 이 상자를 점검 → (통과한 프레임들, 통과 못 한 것 중 가장 나은 것)
    private func shots(for box: FurnitureBox) -> ([Shot], Shot?) {
        var passing: [Shot] = []
        var miss: Shot?
        for v in saved {
            guard let id = v.frameId else { continue }
            let c = FurnitureShotMath.check(box, in: v, others: allBoxes, config: config)
            Self.record(Shot(frameId: id, check: c), passing: &passing, miss: &miss, keep: config.keepCandidates)
        }
        return (passing, miss)
    }

    private static func record(_ s: Shot, passing: inout [Shot], miss: inout Shot?, keep: Int) {
        if s.check.passed {
            let i = passing.firstIndex { $0.check.score < s.check.score } ?? passing.endIndex
            passing.insert(s, at: i)
            if passing.count > keep { passing.removeLast() }
        } else if miss.map({ missRank(s.check) > missRank($0.check) }) ?? true {
            miss = s
        }
    }

    /// 통과 못 한 프레임끼리 비교: 전체가 화면 안(가려짐 · 작음 · 흔들림) > 일부만 > 안 보임, 같으면 점수
    private static func missRank(_ c: ShotCheck) -> Double {
        let base: Double
        switch c.problem {
        case .notInView?: base = 0
        case .notWhole?: base = 1
        default: base = 2
        }
        return base + min(c.score, 0.999)
    }

    /// 점수 순으로, 바라보는 방향이 서로 gapDeg 이상 다른 사진을 count 장까지
    static func diverse(_ shots: [Shot], count: Int, gapDeg: Float) -> [Shot] {
        var out: [Shot] = []
        for s in shots where out.count < count {
            let farEnough = out.allSatisfy { o in
                var d = abs(o.check.viewYawDeg - s.check.viewYawDeg).truncatingRemainder(dividingBy: 360)
                if d > 180 { d = 360 - d }
                return d >= gapDeg
            }
            if farEnough { out.append(s) }
        }
        return out
    }

    static func changed(_ a: FurnitureBox, _ b: FurnitureBox, _ c: FurnitureShotConfig) -> Bool {
        if simd_distance(a.center, b.center) > c.recheckMoveM { return true }
        let dw = abs(a.dimensions.x - b.dimensions.x), dh = abs(a.dimensions.y - b.dimensions.y)
        let dd = abs(a.dimensions.z - b.dimensions.z)
        if max(dw, dh, dd) > c.recheckMoveM { return true }
        let ya = atan2(a.transform.columns.0.z, a.transform.columns.0.x)
        let yb = atan2(b.transform.columns.0.z, b.transform.columns.0.x)
        var dy = abs(ya - yb) * 180 / .pi
        if dy > 180 { dy = 360 - dy }
        return dy > c.recheckYawDeg
    }
}

// MARK: - 촬영 뒤 0.5× 광각 사진 대상

/// 촬영을 마친 뒤 0.5× 광각으로 찍을 가구 하나 (같은 모양 가구는 한 장으로 함께)
struct WideShotTarget: Equatable {
    let objectId: String
    let category: String
    let label: String
    let problem: String                   // 1× 로 전체 사진을 못 찍은 이유 (notWhole · blocked)
    var alsoFor: [String] = []            // 같은 모양이라 이 사진을 함께 쓰는 가구 objectId

    /// furniture_shots.json 결과에서: 전체 사진이 없고(missing) 이유가 '다 안 들어옴' · '가려짐' 인 가구.
    /// 같은 모양(같은 종류 · 크기 ±tol)은 하나로 묶고, '다 안 들어옴' 을 먼저 찍는다. 작음 · 흔들림 · 안 찍힘은 1× 로 다시 찍으면 되므로 뺀다
    static func plan(report: FurnitureShotsFile, boxes: [FurnitureBox], tol: Float) -> [WideShotTarget] {
        let byId = Dictionary(boxes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func rank(_ e: FurnitureShotsFile.Entry) -> Int { e.problem == ShotCheck.Problem.notWhole.rawValue ? 0 : 1 }
        let wanted = [ShotCheck.Problem.notWhole.rawValue, ShotCheck.Problem.blocked.rawValue]
        let candidates = report.objects.enumerated()
            .filter { $0.element.status == FurnitureShotState.pending.rawValue && wanted.contains($0.element.problem ?? "") }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element }
        var out: [WideShotTarget] = []
        for e in candidates {
            if let b = byId[e.objectId],
               let i = out.firstIndex(where: { t in byId[t.objectId].map { FurnitureShotTracker.sameShape($0, b, tol: tol) } ?? false }) {
                out[i].alsoFor.append(e.objectId)
            } else {
                out.append(WideShotTarget(objectId: e.objectId, category: e.category, label: e.label, problem: e.problem ?? ""))
            }
        }
        return out
    }
}

// MARK: - furniture_shots.json

/// 가구별 '전체 사진' (frames/NNNNNN.jpg 의 frameId) + 그 사진 속 상자 위치. 촬영을 마칠 때 RoomPlan 최종 상자로 다시 점검한 결과
struct FurnitureShotsFile: Codable {
    struct Rule: Codable {
        var minVisible: Double
        var minFaceVisible: Double
        var minFill: Double
        var maxBlurPx: Double
        var marginFrac: Double
        var twinTolM: Double
    }

    struct Shot: Codable {
        var frameId: Int
        var score: Double
        var visible: Double?             // 카메라 쪽 면 중 안 가려진 비율 (nil = LiDAR 로 못 잼)
        var fill: Double                 // 화면 가로 · 세로 대비 차지 비율 중 큰 값
        var viewYawDeg: Double           // 가구 중심에서 본 카메라의 수평 방향 (ARKit 월드, atan2(dx, dz), 도)
        var distanceM: Double
        var bbox: [Double]?              // [u0, v0, u1, v1] JPG 픽셀 (센서 원래 방향, K 와 같은 좌표)

        init(_ s: FurnitureShotTracker.Shot) {
            func r(_ x: Double, _ p: Double = 1000) -> Double { (x * p).rounded() / p }
            frameId = s.frameId
            score = r(s.check.score)
            visible = s.check.visible.map { r($0) }
            fill = r(s.check.fill)
            viewYawDeg = r(Double(s.check.viewYawDeg), 10)
            distanceM = r(Double(s.check.distanceM), 100)
            bbox = s.check.bbox.map { b in [b.x, b.y, b.z, b.w].map { r(Double($0), 10) } }
        }
    }

    struct Entry: Codable {
        var objectId: String             // roomplan_structure.json 의 objectId
        var category: String
        var label: String                // 앱 화면에 쓴 이름 ("의자 2")
        var status: String               // full = 전체 사진 있음 · shared = 같은 모양 가구의 사진으로 대신 · missing = 없음
        var sharedWith: String? = nil    // shared: 사진을 대신 쓸 가구의 objectId
        var problem: String? = nil       // shared · missing: 가장 나았던 프레임이 통과 못 한 이유 (notWhole · blocked · tooFar · blurry · notInView)
        var blockedBy: String? = nil     // problem == blocked 일 때 가린 가구의 objectId
        var tuckedInto: String? = nil    // 부피의 15% 이상이 이 가구 상자 안 (식탁 밑에 넣은 의자 → 식탁). 어느 방향에서도 일부는 안 보인다
        var shots: [Shot] = []           // full: 점수 순 · 서로 다른 방향 최대 3장 / 그 외: 가장 나았던 프레임 1장
    }

    var version = 1
    var note = "가구마다 전체가 한 화면에(꼭짓점 8개 모두 화면 안) 가려지지 않고(LiDAR) 충분히 크게 찍힌 프레임. "
        + "frameId = frames/NNNNNN.jpg, bbox = 그 사진 속 RoomPlan 상자 범위(px). SAM 3 상자 프롬프트 · 단일 사진 3D(SAM 3D) 입력 · 품질 확인용"
    var rule: Rule
    var frameCount: Int
    var objects: [Entry]
}
