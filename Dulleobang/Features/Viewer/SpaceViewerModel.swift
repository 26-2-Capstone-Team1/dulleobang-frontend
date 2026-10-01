import Combine
import Foundation

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
    init(_ r: Room) {
        floorY = r.floorY; ceilingY = r.ceilingY; bboxMin = r.bboxMin; bboxMax = r.bboxMax
        walls = r.walls; doors = r.doors; windows = r.windows
    }
}

struct ScenePayload: Encodable {
    let splatUrl: String?
    let pointsUrl: String?
    let room: RoomPayload
    let objects: [SceneObject]
    let removed: [String]
}

struct FurniturePayload: Encodable {
    let id: String, url: String                 // url == "box" 이면 GLB 없이 종류(kind)에 맞는 단순 모형을 그린다
    let dims: Dimensions
    let x: Double, z: Double, yaw: Double
    let label: String
    let kind: String?
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
    /// 불러오는 중에 또 불려도 옮겨 갈 가구 배치를 잃지 않게 잠시 보관
    private var pendingCarry: [PlacedItem]?

    let viewer = ViewerController()
    private(set) var room: Room?
    private var names: [String: String] = [:]
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
            var splat = space.threeDgsUri, points = space.pointsUri
            var removed: [String] = []
            if case .movein(let rsId) = stateKind {
                let rs = await readyRoomState(rsId, currentSpaceVersion: space.spaceVersion)
                if isStale() { return }
                if let rs {
                    room = room.applying(rs)
                    removed = rs.removedObjectIds
                    splat = rs.sceneUri ?? splat
                    points = rs.pointsUri ?? points
                } else {
                    stateKind = .current            // 못 만들었거나 볼 수 없는 입주 상태 → 현재 모습으로 연다
                    unavailableRoomStateId = rsId
                }
            }
            self.room = room
            removedIds = removed
            objects = space.objects
            names = Dictionary(space.objects.map { ($0.objectId, Fmt.objectLabel($0.category)) }, uniquingKeysWith: { a, _ in a })
            dimensionsText = Self.dimensionsText(space.roomDimensions, room)

            let prog: @Sendable (Double) -> Void = { [weak self] p in Task { @MainActor in self?.progress = p } }
            var splatURL: String?, pointsURL: String?
            if let s = splat {
                loading = "3D 데이터 내려받는 중"
                splatURL = try await AssetCache.viewerURL(for: s, defaultExt: "ply", progress: prog)
            } else if let p = points {
                loading = "3D 데이터 내려받는 중"
                pointsURL = try await AssetCache.viewerURL(for: p, defaultExt: "ply", progress: prog)
            } else if room.walls.isEmpty {
                throw ViewerError("이 매물은 아직 3D 데이터가 없습니다")
            }
            if isStale() { return }
            // 스캔 파일(PLY)이 없으면 뷰어가 벽 · 문 · 창 · 가구 정보로 단순한 3D 모형을 그린다
            // (데모 데이터 · RoomPlan 구조만 있는 매물)

            loading = "3D 뷰어 준비 중"
            progress = nil
            let ready = await viewer.waitUntilReady()
            if isStale() { return }
            guard ready else { throw ViewerError("3D 뷰어를 시작하지 못했습니다 (인터넷 연결 확인)") }
            viewer.call("loadScene", ScenePayload(splatUrl: splatURL, pointsUrl: pointsURL, room: RoomPayload(room),
                                                  objects: space.objects, removed: removed))
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
        let w = d?.width ?? r.width, dp = d?.depth ?? r.depth, h = d?.height ?? (r.ceilingY - r.floorY)
        let area = d?.area ?? w * dp
        return String(format: "%.2f × %.2f m · 층고 %.2f m · ", w, dp, h) + Fmt.area(area)
    }

    // MARK: - 이벤트

    private func handle(_ ev: ViewerEvent) {
        switch ev {
        case .ready: break
        case .loaded: loading = nil; progress = nil
        case .progress(let v): progress = v
        case .error(let m): error = m; loading = nil
        case .select(let id): selectedId = id
        case .furnitureLoaded: pushStates()
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
            for o in space.objects {
                names[o.objectId] = Fmt.objectLabel(o.category)
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
                guard job.isDone else { throw ViewerError(job.message ?? "입주 예상 공간을 만들지 못했습니다") }
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
