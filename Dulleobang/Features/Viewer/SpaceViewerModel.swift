import Combine
import Foundation
import UIKit

/// walk = 1인칭(방 안에서 둘러보기), overview = 평면뷰(위에서 내려다보기, 기울여 입체로도 볼 수 있음)
enum ViewMode: String { case walk, overview }

/// 매물 3D 공간에 배치한 내 가구 하나
struct PlacedItem: Identifiable {
    let furniture: Furniture
    var x: Double
    var z: Double
    var yaw: Double
    var collisions: [CollisionInfo] = []

    var id: String { furniture.furnitureId }
    var ok: Bool { collisions.isEmpty }
    var dims: Dimensions { furniture.dimensions ?? Dimensions(width: 1, height: 1, depth: 1) }
    var rect: Rect2D { .furniture(x: x, z: z, yaw: yaw, dims: dims) }
}

// JS 로 넘기는 페이로드 (viewer.js 의 DV.loadScene / DV.addFurniture 인자)
struct RoomPayload: Encodable {
    let floorY: Double, ceilingY: Double
    let bboxMin: Vec3, bboxMax: Vec3
    let walls: [Wall], doors: [Opening], windows: [Opening]
    let hasGeometry: Bool                       // false 면 뷰어가 방 메시 크기에서 범위를 잡는다
    init(_ r: Room) {
        floorY = r.floorY; ceilingY = r.ceilingY; bboxMin = r.bboxMin; bboxMax = r.bboxMax
        walls = r.walls; doors = r.doors; windows = r.windows
        hasGeometry = r.hasGeometry
    }
}

struct ScenePayload: Encodable {
    let meshUrl: String?                        // 방 메시 (room.glb · 면이 있는 PLY · OBJ). 있으면 이것을 그린다
    let objectModels: [String: String]          // objectId → 방과 따로 온 가구 GLB 주소 (‘가구 빼 보기’는 이 모델만 숨긴다)
    let splatUrl: String?
    let pointsUrl: String?
    let room: RoomPayload
    let objects: [SceneObject]
    let removed: [String]
    let sceneRemoved: [String]                  // 장면 파일에서 이미 빠져 있는 가구 (서버가 가구를 빼고 만든 입주 예상 PLY) → 뷰어가 다시 가리지 않는다
    let glass: [GlassPane]                      // 서버가 찾은 투명 유리 → 뷰어가 반투명 유리 상자로 그린다
}

struct FurniturePayload: Encodable {
    let id: String, url: String                 // url == "box" 이면 GLB 없이 종류(kind)에 맞는 단순 모형을 그린다
    let dims: Dimensions
    let x: Double, z: Double, yaw: Double
    let label: String
    let kind: String?
}

/// 가구마다 방 안에서 그 가구를 비춘 작은 그림 (objectId → 그림, 노란 상자가 그 가구).
/// 같은 종류가 둘 이상이면(수납장 2개) 가구 구분 · 가구 빼기 목록에서 이름만으로는 어느 것인지 몰라서 붙인다 (11.19).
/// 뷰어(DV.objectShots)가 장면을 연 뒤 찍어 보내고, 장면을 다시 열면 지운다
@MainActor
final class ObjectShots: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    private var takingSince: Date?

    /// 찍어 달라고 한 뒤 아직 안 왔다 (8초가 지나면 다시 부탁할 수 있다)
    var isTaking: Bool {
        get { takingSince.map { Date().timeIntervalSince($0) < 8 } ?? false }
        set { takingSince = newValue ? Date() : nil }
    }

    func reset() {
        images = [:]
        takingSince = nil
    }

    /// data:image/jpeg;base64,… → 그림
    func set(_ urls: [String: String]) {
        var out: [String: UIImage] = [:]
        for (id, url) in urls {
            guard let comma = url.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                  let image = UIImage(data: data) else { continue }
            out[id] = image
        }
        images = out
        takingSince = nil
    }
}

/// 3D 탐색 + 입주 상태 + 가구 배치 화면의 상태와 규칙. 충돌 판정은 여기서(CollisionChecker) 하고 JS 는 색만 칠한다.
@MainActor
final class SpaceViewerModel: ObservableObject {
    enum RoomStateKind: Equatable { case current, movein(String) }     // movein(roomStateId)

    let listingId: String
    @Published private(set) var stateKind: RoomStateKind
    @Published var mode: ViewMode = .walk { didSet { viewer.call("setMode", mode.rawValue) } }
    @Published var overlay = true { didSet { viewer.call("setOverlay", overlay) } }
    @Published private(set) var loading: String? = "불러오는 중"
    @Published private(set) var progress: Double?
    @Published var error: String?
    @Published var toast: String?
    /// 다른 기기에서 먼저 저장한 배치가 있어 저장이 막힘(412) → "덮어쓰기" 확인을 띄운다
    @Published var confirmOverwrite = false
    @Published private(set) var placed: [PlacedItem] = []
    @Published private(set) var selectedId: String?
    @Published private(set) var objects: [SceneObject] = []
    @Published private(set) var dimensionsText = ""
    /// 입주 상태를 만들 때 서버에 그대로 돌려보내는 기준 버전 (그 사이 바뀌면 409)
    private(set) var spaceVersion: Int?
    private(set) var objectsVersion: Int?
    /// 지금 화면에서 빠져 있는 가구 (입주 예상 상태일 때)
    private var removedIds: [String] = []
    /// 열려다 실패한 입주 상태 (만들기 실패 · 삭제됨 · 내 것이 아님). 화면이 "입주 예상 보기" 대상을 다시 찾는 신호
    @Published private(set) var unavailableRoomStateId: String?
    private var loadGeneration = 0
    /// 이 기기에서 못 연 방 메시 (읽기 실패 · 뷰어가 죽음). 이 화면에서는 다음 판 → 점구름(3DGS) 순서로 연다
    private var failedMeshes: Set<String> = []
    /// 지금 연 방 메시 (메시가 아니면 nil) · 그것을 못 열면 다음에 열 방 메시 · 메시 대신 열 점구름(3DGS)이 있는가
    private var openedMesh: String?
    private var nextMesh: String?
    private var hasPointsFallback = false
    /// 뷰어가 죽은 횟수 (점구름으로도 계속 죽으면 다시 열지 않고 알린다)
    private var crashCount = 0
    /// 불러오는 중에 또 불려도 옮겨 갈 가구 배치를 잃지 않게 잠시 보관
    private var pendingCarry: [PlacedItem]?

    let viewer = ViewerController()
    /// 가구 사진 (가구 구분 · 가구 빼기 목록)
    let shots = ObjectShots()
    private var shotsWanted = false
    private(set) var room: Room?
    private var names: [String: String] = [:]
    /// 가구 이름. 같은 이름이 둘 이상이면 번호를 붙인다 (수납장 1 · 수납장 2, 3D 라벨과 같음)
    var objectNames: [String: String] { Fmt.objectNames(objects) }
    private var initialPlacements: [Placement]?

    init(listingId: String, state: RoomStateKind = .current, initialPlacements: [Placement]? = nil) {
        self.listingId = listingId
        self.stateKind = state
        self.initialPlacements = initialPlacements
        viewer.onEvent = { [weak self] ev in self?.handle(ev) }
    }

    var selected: PlacedItem? { placed.first { $0.id == selectedId } }
    var isMovein: Bool { if case .movein = stateKind { return true } else { return false } }
    func describe(_ item: PlacedItem) -> String { CollisionChecker.describe(item.collisions, names: names) }

    /// 현재 시점의 처음 카메라 위치로 되돌린다 ("초기화")
    func resetView() { viewer.call("resetView") }

    // MARK: - 로딩

    /// keepPlaced: 입주 예상 ↔ 현재 모습을 오갈 때 저장 안 한 가구 배치를 그대로 가져간다.
    /// 불러오는 도중 다시 불리면(버튼을 연달아 누름) 나중 것만 반영한다
    func load(keepPlaced: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        func isStale() -> Bool { generation != loadGeneration }

        loading = "공간 정보 불러오는 중"
        progress = nil
        let carried: [PlacedItem]? = keepPlaced ? (placed.isEmpty ? (pendingCarry ?? []) : placed) : nil
        pendingCarry = carried
        placed = []
        selectedId = nil
        do {
            let space = try await ListingAPI.space(listingId)
            if isStale() { return }
            spaceVersion = space.spaceVersion
            objectsVersion = space.objectsVersion
            var room = Room(space: space)
            // 방 메시는 폰용 KTX2 판 → 대체판(48 MB) 순서로 열어 본다 (AI 팀 11.20). 모두 못 열면 점구름
            var meshes = space.phoneMeshCandidates, splat = space.threeDgsUri, points = space.pointsUri
            var removed: [String] = []
            var roomStateFiles: Set<String> = []     // 서버가 이 입주 상태를 위해 가구를 빼고 새로 만든 장면 · 점 파일
            if case .movein(let rsId) = stateKind {
                let rs = await readyRoomState(rsId, currentSpaceVersion: space.spaceVersion)
                if isStale() { return }
                if let rs {
                    room = room.applying(rs)
                    removed = rs.removedObjectIds
                    if let scene = rs.sceneUri {            // 서버가 가구를 뺀 장면을 따로 만들어 준 경우 (메시일 수도, 3DGS 일 수도)
                        if SceneAsset.isMesh(scene) { meshes = [scene] + meshes.filter { $0 != scene } } else { splat = scene; meshes = [] }
                        roomStateFiles.insert(scene)
                    }
                    if let p = rs.pointsUri {               // 백엔드: 입주 예상 = 고른 가구를 빼고 새로 만든 PLY (11.19)
                        points = p
                        roomStateFiles.insert(p)
                    }
                } else {
                    stateKind = .current            // 못 만들었거나 볼 수 없는 입주 상태 → 현재 모습으로 연다
                    unavailableRoomStateId = rsId
                }
            }
            hasPointsFallback = splat != nil || points != nil
            let (mesh, next) = Self.pickMesh(meshes, failed: failedMeshes, hasPoints: hasPointsFallback)
            let meshDropped = mesh == nil && !meshes.isEmpty      // 이 기기에서 메시가 모두 안 열렸다 → 점구름(가구도 점 안에 있다)으로
            openedMesh = mesh
            nextMesh = next
            self.room = room
            removedIds = removed
            objects = space.objects
            names = Fmt.objectNames(space.objects)
            shots.reset()                               // 장면을 새로 여니 가구 사진도 새로 찍는다
            dimensionsText = Self.dimensionsText(space.roomDimensions, room)

            let prog: @Sendable (Double) -> Void = { [weak self] p in Task { @MainActor in self?.progress = p } }
            var meshURL: String?, splatURL: String?, pointsURL: String?
            // 실제로 여는 파일이 서버가 가구를 빼고 만든 것이면, 뺀 가구 자리를 뷰어가 다시 가리지 않게 알려 준다
            let sceneRemoved = (mesh ?? splat ?? points).map { roomStateFiles.contains($0) } == true ? removed : []
            if let m = mesh {
                loading = "3D 데이터 내려받는 중"
                meshURL = try await AssetCache.viewerURL(for: m, defaultExt: "glb", progress: prog)
            } else if let s = splat {
                loading = "3D 데이터 내려받는 중"
                splatURL = try await AssetCache.viewerURL(for: s, defaultExt: "ply", progress: prog)
            } else if let p = points {
                loading = "3D 데이터 내려받는 중"
                pointsURL = try await AssetCache.viewerURL(for: p, defaultExt: "ply", progress: prog)
            } else if room.walls.isEmpty {
                throw ViewerError("이 매물은 아직 3D 데이터가 없습니다")
            }
            if isStale() { return }
            // 방 메시도 스캔 파일도 없으면 뷰어가 벽 · 문 · 창 · 가구 정보로 단순한 3D 모형을 그린다
            // (데모 데이터 · RoomPlan 구조만 있는 매물)

            // 방과 따로 온 가구 GLB. 하나를 못 받아도 방은 연다 (그 가구만 안 보인다).
            // 메시를 못 열어 점구름으로 여는 중이면 받지 않는다 (가구가 점 안에 들어 있고, 메모리를 아낀다)
            var objectModels: [String: String] = [:]
            let modeled = meshDropped ? [SceneObject]() : space.objects.filter { $0.modelUri != nil }
            for (i, o) in modeled.enumerated() {
                guard let uri = o.modelUri else { continue }
                loading = "가구 모델 내려받는 중 (\(i + 1)/\(modeled.count))"
                progress = nil
                if let url = try? await AssetCache.viewerURL(for: uri, defaultExt: "glb") { objectModels[o.objectId] = url }
                if isStale() { return }
            }

            loading = "3D 뷰어 준비 중"
            progress = nil
            let ready = await viewer.waitUntilReady()
            if isStale() { return }
            guard ready else { throw ViewerError("3D 뷰어를 시작하지 못했습니다 (인터넷 연결 확인)") }
            viewer.call("loadScene", ScenePayload(meshUrl: meshURL, objectModels: objectModels,
                                                  splatUrl: splatURL, pointsUrl: pointsURL, room: RoomPayload(room),
                                                  objects: space.objects, removed: removed, sceneRemoved: sceneRemoved,
                                                  glass: room.glass))
            viewer.call("setMode", mode.rawValue)
            viewer.call("setOverlay", overlay)
            pendingCarry = nil
            if let carried {
                for p in carried { await add(p.furniture, x: p.x, z: p.z, yaw: p.yaw) }
            } else {
                await restorePlacements()
            }
        } catch {
            if isStale() { return }
            pendingCarry = nil
            if let carried { placed = carried }     // 씬을 못 바꿨으니 화면에 남은 가구를 계속 다룰 수 있게
            self.error = error.userMessage
            loading = nil
        }
    }

    /// 열 방 메시 고르기: 이 기기에서 안 열린 판은 건너뛴다. 모두 안 열렸으면 nil(점구름으로),
    /// 점구름도 없으면 마지막 판을 다시 열어 본다. next = 이것을 못 열면 다음에 열 판
    nonisolated static func pickMesh(_ candidates: [String], failed: Set<String>, hasPoints: Bool) -> (mesh: String?, next: String?) {
        let usable = candidates.filter { !failed.contains($0) }
        return (usable.first ?? (hasPoints ? nil : candidates.last), usable.count > 1 ? usable[1] : nil)
    }

    private func restorePlacements() async {
        let list: [Placement]
        if let initialPlacements {
            list = initialPlacements
            self.initialPlacements = nil
        } else {
            list = (try? await ListingAPI.placements(listingId)) ?? []
        }
        for p in list {
            guard let f = try? await FurnitureAPI.get(p.furnitureId) else { continue }
            await add(f, x: p.position.x, z: p.position.z, yaw: p.rotation.yaw)
        }
    }

    private static func dimensionsText(_ d: RoomDimensions?, _ r: Room) -> String {
        let f = r.footprint                                     // 벽으로 잰 크기가 있으면 그것 (서버 값은 축에 맞춘 범위일 수 있다)
        let w = f?.width ?? d?.width ?? r.width, dp = f?.depth ?? d?.depth ?? r.depth, h = d?.height ?? (r.ceilingY - r.floorY)
        let area = f?.area ?? d?.area ?? w * dp
        return String(format: "%.2f × %.2f m · 층고 %.2f m · ", w, dp, h) + Fmt.area(area)
    }

    // MARK: - 이벤트

    private func handle(_ ev: ViewerEvent) {
        switch ev {
        case .ready: break
        case .loaded:
            loading = nil
            progress = nil
            if shotsWanted {
                shotsWanted = false
                requestShots()
            }
        case .objectShots(let urls): shots.set(urls)
        case .progress(let v): progress = v
        case .error(let m): error = m; loading = nil
        case .meshFailed(let m):
            if let cur = openedMesh, nextMesh != nil || hasPointsFallback {
                failedMeshes.insert(cur)
                toast = nextMesh != nil ? "방 메시를 열지 못해 다른 파일로 다시 엽니다" : "방 메시를 열지 못해 점구름으로 엽니다"
                Task { await load(keepPlaced: !placed.isEmpty) }
            } else {
                error = "방 메시를 열지 못했습니다" + (m.isEmpty ? "" : ": \(m)")
                loading = nil
            }
        case .crashed:
            // 뷰어가 메모리 부족 등으로 죽었다가 다시 떴다 (화면은 비어 있음).
            // 메시였으면 다음 판(폰용 KTX2 → 48 MB 대체판) → 점구름 순서로, 아니면 같은 장면으로 한 번 더 연다
            crashCount += 1
            if let cur = openedMesh, nextMesh != nil || hasPointsFallback {
                failedMeshes.insert(cur)
                toast = nextMesh != nil ? "방 메시가 이 기기에서 너무 커서 다른 파일로 다시 엽니다"
                                        : "방 메시가 이 기기에서 너무 커서 점구름으로 다시 엽니다"
            } else if crashCount >= 2 {
                error = "3D 뷰어가 계속 멈춥니다. 이 기기에서 열기에는 3D 파일이 너무 큰 것 같아요."
                loading = nil
                return
            } else {
                toast = "3D 뷰어가 멈춰서 다시 엽니다"
            }
            Task { await load(keepPlaced: !placed.isEmpty) }      // 놓아 둔 가구가 있으면 그대로, 없으면 저장된 배치를 다시 받는다
        case .select(let id): selectedId = id
        case .furnitureLoaded: pushStates()
        case .bounds(let lo, let hi):
            // 서버가 방 구조를 안 준 방: 뷰어가 방 메시 크기에서 잡은 범위로 바닥 · 천장 · 가구를 놓을 수 있는 범위를 정한다
            guard var r = room, !r.hasGeometry else { return }
            r.bboxMin = lo
            r.bboxMax = hi
            r.floorY = lo.y
            r.ceilingY = hi.y
            room = r
            dimensionsText = Self.dimensionsText(nil, r)
            recheckAll()
        case .transform(let id, let x, let z, let yaw, _):
            guard let i = placed.firstIndex(where: { $0.id == id }) else { return }
            placed[i].x = x
            placed[i].z = z
            placed[i].yaw = Self.normalize(yaw)
            recheckAll()
        }
    }

    // MARK: - 가구 배치

    func addFurniture(_ f: Furniture) async {
        while room == nil && error == nil { try? await Task.sleep(for: .milliseconds(200)) }   // 공간 로딩 대기
        guard let room else { return }
        guard let dims = f.dimensions, f.modelUri != nil else { error = "\(f.label) 의 3D 모델이 아직 준비되지 않았습니다"; return }
        guard !placed.contains(where: { $0.id == f.id }) else { toast = "이미 배치한 가구입니다"; return }
        if mode == .walk { mode = .overview }       // 가구는 위에서 보며 옮기는 게 편하다
        let others = placed.map { (id: $0.id, rect: $0.rect) }
        if let fit = CollisionChecker.autoFit(dims, room: room, others: others) {
            await add(f, x: fit.x, z: fit.z, yaw: fit.yaw)
        } else {
            toast = "들어갈 빈자리를 찾지 못해 방 가운데에 놓았습니다"
            await add(f, x: room.center.x, z: room.center.z, yaw: 0)
        }
    }

    private func add(_ f: Furniture, x: Double, z: Double, yaw: Double) async {
        guard let uri = f.modelUri, let dims = f.dimensions else { return }
        do {
            let url: String
            if uri == MockBackend.boxModel {
                url = uri                                   // GLB 없이 치수대로 그린다 (데모 가구)
            } else {
                url = try await AssetCache.viewerURL(for: uri, defaultExt: "glb")
            }
            names[f.id] = f.label
            placed.append(PlacedItem(furniture: f, x: x, z: z, yaw: yaw))
            viewer.call("addFurniture", FurniturePayload(id: f.id, url: url, dims: dims, x: x, z: z, yaw: yaw,
                                                         label: f.label, kind: f.category))
            recheckAll()
        } catch {
            self.error = "가구 모델을 내려받지 못했습니다: \(error.userMessage)"
        }
    }

    func rotateSelected(by delta: Double) {
        guard let id = selectedId, let i = placed.firstIndex(where: { $0.id == id }) else { return }
        let step = AppConfig.shared.snapYawDeg
        placed[i].yaw = Self.normalize(((placed[i].yaw + delta) / step).rounded() * step)
        viewer.call("setFurnitureTransform", id, placed[i].x, placed[i].z, placed[i].yaw)
        recheckAll()
    }

    func removeSelected() {
        guard let id = selectedId else { return }
        placed.removeAll { $0.id == id }
        viewer.call("removeFurniture", id)
        selectedId = nil
        recheckAll()
    }

    func save(overwrite: Bool = false) async {
        let y = room?.floorY ?? 0
        let list = placed.map {
            Placement(furnitureId: $0.id, position: Vec3(x: $0.x, y: y, z: $0.z), rotation: Rotation(yaw: $0.yaw),
                      isPlaceable: $0.ok, collisions: $0.collisions)
        }
        do {
            _ = try await ListingAPI.savePlacements(listingId, list, overwrite: overwrite)
            toast = "배치를 저장했습니다"
        } catch let e as APIError where e.status == 412 {
            // 다른 기기에서 먼저 저장함 (버전이 달라짐): 조용히 덮어쓰지 않고 물어본다
            confirmOverwrite = true
        } catch {
            self.error = error.userMessage
        }
    }

    private func recheckAll() {
        guard let room else { return }
        for i in placed.indices {
            let others = placed.indices.filter { $0 != i }.map { (id: placed[$0].id, rect: placed[$0].rect) }
            placed[i].collisions = CollisionChecker.check(placed[i].rect, topY: room.floorY + placed[i].dims.height,
                                                          room: room, others: others)
        }
        pushStates()
    }

    private func pushStates() {
        for p in placed { viewer.call("setFurnitureState", p.id, p.ok) }
    }

    private static func normalize(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    // MARK: - 가구 사진

    /// 가구 구분 · 가구 빼기를 열 때 부른다. 이 장면에서 아직 안 찍었으면 뷰어에 찍어 달라고 한다 (장면을 여는 중이면 다 연 뒤에)
    func requestShots() {
        guard !objects.isEmpty, shots.images.isEmpty, !shots.isTaking else { return }
        guard loading == nil else {
            shotsWanted = true
            return
        }
        shots.isTaking = true
        viewer.call("objectShots", [String](), 480, 360)
    }

    // MARK: - 가구 구분 (중개사) · 가구 빼 보기 (모두)

    /// 가구 구분 화면에서 고르는 대로 3D 테두리 색만 바꿔 보여 준다 (저장 전)
    func previewOwnership(_ objectId: String, _ type: String?) {
        viewer.call("setObjectOwnership", objectId, type ?? "")
    }

    /// 저장하지 않고 닫았을 때 색을 원래 구분으로 되돌린다
    func restoreOwnershipColors() {
        for o in objects { viewer.call("setObjectOwnership", o.objectId, o.ownershipType ?? "") }
    }

    /// 가구 빼 보기에서 고른 가구를 3D 에서 미리 숨긴다. nil 이면 지금 상태대로 되돌린다
    func previewRemoval(_ ids: [String]?) {
        viewer.call("setRemovedObjects", ids ?? removedIds)
    }

    /// 가구 구분 · 버전만 다시 받는다 (씬과 배치한 가구는 그대로 둔다)
    func refreshSpaceInfo() async {
        do {
            let space = try await ListingAPI.space(listingId)
            if let old = spaceVersion, let new = space.spaceVersion, old != new {
                // 그 사이 다시 촬영됨: 벽 · 씬부터 바뀌었으니 현재 모습으로 전부 다시 연다
                stateKind = .current
                await load()
                return
            }
            spaceVersion = space.spaceVersion
            objectsVersion = space.objectsVersion
            objects = space.objects
            names.merge(Fmt.objectNames(space.objects)) { _, new in new }
            for o in space.objects {
                viewer.call("setObjectOwnership", o.objectId, o.ownershipType ?? "")
            }
            if var r = room {
                r.objects = space.objects.filter { !removedIds.contains($0.objectId) }
                room = r
                recheckAll()
            }
        } catch {
            if !error.isCancellation { self.error = error.userMessage }
        }
    }

    /// 입주 상태를 받아 완성될 때까지 기다린다. 실패했거나 내 것이 아니면(404) 알리고 nil
    private func readyRoomState(_ rsId: String, currentSpaceVersion: Int?) async -> RoomState? {
        do {
            var rs = try await RoomStateAPI.get(rsId)
            if rs.isProcessing, rs.jobId == nil {
                // 작업 번호를 안 주는 서버: 입주 상태 자체를 몇 번 다시 확인한다 (최대 약 2분)
                loading = "입주 예상 공간 만드는 중"
                for _ in 0..<40 where rs.isProcessing {
                    try await Task.sleep(for: .seconds(3))
                    rs = try await RoomStateAPI.get(rsId)
                }
            }
            if rs.isProcessing, let jobId = rs.jobId {
                loading = "입주 예상 공간 만드는 중"
                let job = try await JobAPI.wait(jobId) { [weak self] j in
                    self?.progress = j.progress.map { $0 / 100 }
                }
                progress = nil
                guard job.isDone else { throw ViewerError(job.failureMessage ?? "입주 예상 공간을 만들지 못했습니다") }
                rs = try await RoomStateAPI.get(rsId)
            }
            guard rs.isReady else { throw ViewerError("입주 예상 공간을 만들지 못했습니다. ‘가구 빼 보기’로 다시 만들어 주세요") }
            if let made = rs.sourceSpaceVersion, let current = currentSpaceVersion, made != current {
                throw ViewerError("공간을 다시 촬영해서 예전 입주 예상 공간은 쓸 수 없어요. ‘가구 빼 보기’로 다시 만들어 주세요")
            }
            return rs
        } catch {
            if !error.isCancellation { toast = error.userMessage }
            return nil
        }
    }

    func showRoomState(_ roomStateId: String) async {
        stateKind = .movein(roomStateId)
        await load(keepPlaced: true)
    }

    func showCurrent() async {
        stateKind = .current
        await load(keepPlaced: true)
    }
}

struct ViewerError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
