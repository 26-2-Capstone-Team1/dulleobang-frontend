import CryptoKit
import Foundation

/// 서버의 3D 파일(방 메시 GLB · 가구 GLB · PLY)을 Caches/viewer-assets 에 내려받고, 뷰어가 읽을 dulleobang://app/assets/… URL 을 돌려준다.
/// 같은 URI 는 한 번만 받는다 (pre-signed URL 처럼 쿼리가 바뀌는 경우를 위해 쿼리는 키에서 제외).
/// 기기 안의 파일(데모 데이터 · 불러온 AI 결과)은 내려받지 않고 캐시 폴더에 이어 붙이기만 한다.
enum AssetCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("viewer-assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let knownExt: Set<String> = ["ply", "splat", "ksplat", "spz", "glb", "gltf", "obj"]

    static func viewerURL(for uri: String, defaultExt: String,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        guard let remote = AssetURL.resolve(uri) else { throw URLError(.badURL) }
        var keyComps = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        keyComps?.query = nil
        var key = keyComps?.string ?? remote.absoluteString
        let fm = FileManager.default
        if remote.isFileURL {                               // 같은 경로의 파일이 바뀌면 새로 잇도록 크기 · 수정 시각을 키에 넣는다
            let attrs = try fm.attributesOfItem(atPath: remote.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            key += "|\(size)|\(Int(modified))"
        }
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = knownExt.contains(remote.pathExtension.lowercased()) ? remote.pathExtension.lowercased() : defaultExt
        let name = "\(hash).\(ext)"
        let local = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: local.path) {
            if remote.isFileURL {
                do { try fm.linkItem(at: remote, to: local) }           // 같은 저장소면 복사 없이 이어 붙인다
                catch { try fm.copyItem(at: remote, to: local) }
                progress?(1)
            } else {
                try await APIClient.shared.download(remote, to: local, progress: progress)
            }
        }
        return ViewerAssetHandler.assetURL(name)
    }

    /// 기기 안의 3D 파일(파일 앱 · AirDrop 으로 받은 room.glb 등)을 캐시에 복사하고 뷰어 URL 을 돌려준다.
    /// 같은 이름 · 같은 크기의 파일은 다시 복사하지 않는다
    static func importLocal(_ file: URL) throws -> String {
        let fm = FileManager.default
        let size = ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let key = "local|\(file.lastPathComponent)|\(size)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = knownExt.contains(file.pathExtension.lowercased()) ? file.pathExtension.lowercased() : "glb"
        let name = "\(hash).\(ext)"
        let local = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: local.path) { try fm.copyItem(at: file, to: local) }
        return ViewerAssetHandler.assetURL(name)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static var sizeMB: Double {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return Double(bytes) / 1_048_576
    }
}
