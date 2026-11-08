import ARKit
import Combine
import RoomPlan
import SwiftUI

/// LiDAR 기기 전용: RoomPlan 을 "우리 ARSession" 위에서 돌린다 (iOS 17 custom ARSession).
/// → RoomPlan 결과(벽·문·창·가구 + 치수)와 CaptureRecorder 의 프레임/포즈가 같은 월드 좌표계를 공유한다.
///   AI 팀원은 roomplan_structure.json 을 구조 추출의 정답(ground truth)이나 대체값으로 쓸 수 있다.
final class RoomPlanController: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    @Published private(set) var result: CapturedRoom?
    @Published private(set) var errorMessage: String?
    weak var view: RoomCaptureView?
    /// 스캔 중 RoomPlan 이 가구 상자를 고칠 때마다 (메인 스레드) → 가구 전체 사진 점검 (CaptureRecorder.updateFurniture)
    var onFurniture: (([FurnitureBox]) -> Void)?
    var onWalls: (([CoverageWall]) -> Void)?                     // 스캔 중 벽 갱신 (벽 · 바닥 커버리지)

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    override init() { super.init() }

    // RoomCaptureViewDelegate 는 NSCoding 을 상속하므로 형식상 구현한다
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func start() {
        result = nil
        errorMessage = nil
        var config = RoomCaptureSession.Configuration()
        config.isCoachingEnabled = true
        view?.captureSession.run(configuration: config)
    }

    /// ARSession 은 멈추지 않고 스캔만 끝낸다 → 후처리 결과는 delegate 로 도착
    func stop() { view?.captureSession.stop(pauseARSession: false) }

    /// 후처리된 CapturedRoom 을 최대 timeout 초 기다린다
    @MainActor func waitForResult(timeout: Double = 45) async -> CapturedRoom? {
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil && errorMessage == nil && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return result
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error { errorMessage = error.localizedDescription }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error { errorMessage = error.localizedDescription }
        result = processedResult
    }

    // RoomCaptureSessionDelegate — RoomCaptureView 의 화면 안내는 그대로 두고 스캔 중 결과만 받는다 (Apple 예제와 같은 방식)
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let boxes = RoomPlanExport.furniture(from: room)
        let walls = RoomPlanExport.coverageWalls(from: room)
        DispatchQueue.main.async { [weak self] in
            self?.onFurniture?(boxes)
            self?.onWalls?(walls)
        }
    }
}

struct RoomPlanCaptureView: UIViewRepresentable {
    let session: ARSession
    let controller: RoomPlanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let v = RoomCaptureView(frame: .zero, arSession: session)
        v.delegate = controller
        v.captureSession.delegate = controller          // 스캔 중 가구 상자 갱신 (가구 전체 사진 점검)
        controller.view = v
        return v
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

/// CapturedRoom → zip 에 넣을 파일들
enum RoomPlanExport {
    static func files(from room: CapturedRoom) -> [String: Data] {
        var files: [String: Data] = [:]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let raw = try? JSONEncoder().encode(room) { files["roomplan.json"] = raw }            // Apple 원본 형식
        if let s = try? enc.encode(structure(from: room)) { files["roomplan_structure.json"] = s } // 우리 API 형식
        let usdz = FileManager.default.temporaryDirectory.appendingPathComponent("roomplan-\(UUID().uuidString).usdz")
        if (try? room.export(to: usdz)) != nil, let d = try? Data(contentsOf: usdz) {
            files["roomplan.usdz"] = d
            try? FileManager.default.removeItem(at: usdz)
        }
        return files
    }

    /// 가구 상자 (가구 전체 사진 점검용). 스캔 중 결과 · 최종 결과 모두 같은 변환
    static func furniture(from room: CapturedRoom) -> [FurnitureBox] {
        room.objects.map { o in
            FurnitureBox(id: o.identifier.uuidString, category: String(describing: o.category),
                         transform: o.transform, dimensions: o.dimensions)
        }
    }

    /// 벽 · 바닥 커버리지용 벽 (스캔 중 결과 · 최종 결과 같은 변환)
    static func coverageWalls(from room: CapturedRoom) -> [CoverageWall] {
        room.walls.map { s in
            CoverageWall(id: s.identifier.uuidString, transform: s.transform, width: s.dimensions.x, height: s.dimensions.y)
        }
    }

    /// GET /listings/{id}/space 의 roomGeometry + objects 와 같은 스키마로 변환
    struct Structure: Codable {
        var roomGeometry: RoomGeometry
        var roomDimensions: RoomDimensions
        var objects: [SceneObject]
    }

    static func structure(from room: CapturedRoom) -> Structure {
        let walls: [Wall] = room.walls.map { s in
            let c = s.transform.columns.3.xyz, ux = s.transform.columns.0.xyz, half = s.dimensions.x / 2
            return Wall(id: s.identifier.uuidString,
                        from: [Double(c.x - ux.x * half), Double(c.z - ux.z * half)],
                        to: [Double(c.x + ux.x * half), Double(c.z + ux.z * half)],
                        height: Double(s.dimensions.y))
        }
        func opening(_ s: CapturedRoom.Surface, _ type: String) -> Opening {
            Opening(id: s.identifier.uuidString, type: type, position: vec(s.transform.columns.3.xyz),
                    rotation: Rotation(yaw: yawDeg(s.transform)),
                    dimensions: Dimensions(width: Double(s.dimensions.x), height: Double(s.dimensions.y),
                                           depth: max(Double(s.dimensions.z), 0.1)))
        }
        let floorY = room.walls.map { Double($0.transform.columns.3.y - $0.dimensions.y / 2) }.min() ?? 0
        let ceilingH = room.walls.map { Double($0.dimensions.y) }.max() ?? 2.4
        let xs = walls.flatMap { [$0.from[0], $0.to[0]] }, zs = walls.flatMap { [$0.from[1], $0.to[1]] }
        let minX = xs.min() ?? -2, maxX = xs.max() ?? 2, minZ = zs.min() ?? -2, maxZ = zs.max() ?? 2
        let geometry = RoomGeometry(floorHeight: floorY, ceilingHeight: ceilingH, walls: walls,
                                    doors: room.doors.map { opening($0, "door") },
                                    windows: room.windows.map { opening($0, "window") },
                                    boundingBox: BoundingBox(min: Vec3(x: minX, y: floorY, z: minZ),
                                                             max: Vec3(x: maxX, y: floorY + ceilingH, z: maxZ)))
        let objects: [SceneObject] = room.objects.map { o in
            SceneObject(objectId: o.identifier.uuidString, category: String(describing: o.category),
                        position: vec(o.transform.columns.3.xyz), rotation: Rotation(yaw: yawDeg(o.transform)),
                        dimensions: Dimensions(width: Double(o.dimensions.x), height: Double(o.dimensions.y),
                                               depth: Double(o.dimensions.z)),
                        ownershipType: nil)
        }
        return Structure(roomGeometry: geometry,
                         roomDimensions: RoomDimensions(width: maxX - minX, depth: maxZ - minZ, height: ceilingH,
                                                        area: (maxX - minX) * (maxZ - minZ)),
                         objects: objects)
    }

    private static func vec(_ v: SIMD3<Float>) -> Vec3 { Vec3(x: Double(v.x), y: Double(v.y), z: Double(v.z)) }

    /// 로컬 x 축 = (cos yaw, -sin yaw) 규약 (CollisionChecker 와 동일)
    private static func yawDeg(_ t: simd_float4x4) -> Double {
        let ux = t.columns.0
        return Double(atan2(-ux.z, ux.x)) * 180 / .pi
    }
}
