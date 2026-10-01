import CryptoKit
import Foundation

/// 서버의 3D 파일(PLY/GLB)을 Caches/viewer-assets 에 내려받고, 뷰어가 읽을 dulleobang://app/assets/… URL 을 돌려준다.
/// 같은 URI 는 한 번만 받는다 (pre-signed URL 처럼 쿼리가 바뀌는 경우를 위해 쿼리는 키에서 제외).
enum AssetCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("viewer-assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let knownExt: Set<String> = ["ply", "splat", "ksplat", "spz", "glb", "gltf"]

    static func viewerURL(for uri: String, defaultExt: String,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        guard let remote = AssetURL.resolve(uri) else { throw URLError(.badURL) }
        var keyComps = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        keyComps?.query = nil
        let key = keyComps?.string ?? remote.absoluteString
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let ext = knownExt.contains(remote.pathExtension.lowercased()) ? remote.pathExtension.lowercased() : defaultExt
        let name = "\(hash).\(ext)"
        let local = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: local.path) {
            try await APIClient.shared.download(remote, to: local, progress: progress)
        }
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
