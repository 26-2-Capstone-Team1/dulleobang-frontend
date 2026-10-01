import Foundation
import UniformTypeIdentifiers
import WebKit

/// dulleobang://app/… 요청을 처리한다.
///  - /index.html, /viewer.js, /vendor/…  → 번들의 Viewer 폴더
///  - /assets/<name>                      → AssetCache 에 내려받아 둔 PLY/GLB
/// file:// 로 로드할 때 생기는 fetch/CORS 제약을 피하고, 수백 MB 파일을 1 MB 청크로 스트리밍한다.
@MainActor
final class ViewerAssetHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "dulleobang"
    nonisolated static let host = "app"
    static let shared = ViewerAssetHandler()

    nonisolated static var indexURL: URL { URL(string: "\(scheme)://\(host)/index.html")! }
    nonisolated static func assetURL(_ name: String) -> String { "\(scheme)://\(host)/assets/\(name)" }

    private let registry = StopRegistry()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let id = ObjectIdentifier(task)
        let registry = self.registry
        registry.clear(id)

        if url.path == "/" || url.path == "/index.html" {
            serveIndex(task, url: url)
            return
        }
        guard let file = Self.resolve(url.path) else {
            Self.respond(task, id, url: url, status: 404, mime: "text/plain", length: 0, registry: registry)
            Self.finish(task, id, registry: registry)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.stream(file, task: task, id: id, url: url, registry: registry)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        registry.stop(ObjectIdentifier(task))
    }

    // MARK: - 경로

    nonisolated static func resolve(_ path: String) -> URL? {
        let rel = String(path.drop(while: { $0 == "/" }))
        guard !rel.isEmpty, !rel.contains("..") else { return nil }
        if rel.hasPrefix("assets/") {
            let f = AssetCache.dir.appendingPathComponent(String(rel.dropFirst("assets/".count)))
            return FileManager.default.fileExists(atPath: f.path) ? f : nil
        }
        // Viewer 폴더 참조(파란 폴더)가 기본. 그룹으로 추가돼 번들 루트에 풀린 경우도 허용.
        let bases = [Bundle.main.url(forResource: "Viewer", withExtension: nil), Bundle.main.resourceURL].compactMap { $0 }
        for base in bases {
            let f = base.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    /// index.html 의 %%IMPORTMAP%% 를 채운다: vendor/ 에 로컬 사본이 있으면 그것(오프라인 시연용), 없으면 CDN.
    private func serveIndex(_ task: any WKURLSchemeTask, url: URL) {
        let id = ObjectIdentifier(task)
        guard let file = Self.resolve("/index.html"), var html = try? String(contentsOf: file, encoding: .utf8) else {
            Self.respond(task, id, url: url, status: 404, mime: "text/plain", length: 0, registry: registry)
            Self.finish(task, id, registry: registry)
            return
        }
        html = html.replacingOccurrences(of: "%%IMPORTMAP%%", with: Self.importMap())
        let data = Data(html.utf8)
        Self.respond(task, id, url: url, status: 200, mime: "text/html", length: data.count, registry: registry)
        Self.send(task, id, data, registry: registry)
        Self.finish(task, id, registry: registry)
    }

    nonisolated static func importMap() -> String {
        let local = resolve("/vendor/three/build/three.module.js") != nil
            && resolve("/vendor/gaussian-splats-3d/gaussian-splats-3d.module.js") != nil
        let cdn = AppConfig.shared.viewerCDN
        let imports: [String: String] = local ? [
            "three": "./vendor/three/build/three.module.js",
            "three/addons/": "./vendor/three/examples/jsm/",
            "@mkkellogg/gaussian-splats-3d": "./vendor/gaussian-splats-3d/gaussian-splats-3d.module.js",
        ] : [
            "three": "\(cdn)/three@0.170.0/build/three.module.js",
            "three/addons/": "\(cdn)/three@0.170.0/examples/jsm/",
            "@mkkellogg/gaussian-splats-3d": "\(cdn)/@mkkellogg/gaussian-splats-3d@0.4/build/gaussian-splats-3d.module.js",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["imports": imports],
                                                options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 스트리밍 (백그라운드에서 읽고, WKURLSchemeTask 호출은 메인 스레드에서)

    nonisolated private static func stream(_ file: URL, task: any WKURLSchemeTask, id: ObjectIdentifier,
                                           url: URL, registry: StopRegistry) {
        guard let h = try? FileHandle(forReadingFrom: file) else {
            respond(task, id, url: url, status: 500, mime: "text/plain", length: 0, registry: registry)
            finish(task, id, registry: registry)
            return
        }
        defer { try? h.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        respond(task, id, url: url, status: 200, mime: mime(file.pathExtension), length: size, registry: registry)
        let window = DispatchSemaphore(value: 4)            // 메인 큐에 최대 4 MB 만 대기
        while !registry.isStopped(id) {
            guard let data = try? h.read(upToCount: 1 << 20), !data.isEmpty else { break }
            window.wait()
            DispatchQueue.main.async {
                defer { window.signal() }
                guard !registry.isStopped(id) else { return }
                MainActor.assumeIsolated { task.didReceive(data) }
            }
        }
        finish(task, id, registry: registry)
    }

    // stop 이후에 task 메서드를 부르면 예외가 나므로 매번 확인한다
    nonisolated private static func respond(_ task: any WKURLSchemeTask, _ id: ObjectIdentifier, url: URL,
                                            status: Int, mime: String, length: Int, registry: StopRegistry) {
        let headers = ["Content-Type": mime, "Content-Length": String(length),
                       "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        DispatchQueue.main.async {
            guard !registry.isStopped(id) else { return }
            MainActor.assumeIsolated { task.didReceive(resp) }
        }
    }

    nonisolated private static func send(_ task: any WKURLSchemeTask, _ id: ObjectIdentifier, _ data: Data,
                                         registry: StopRegistry) {
        DispatchQueue.main.async {
            guard !registry.isStopped(id) else { return }
            MainActor.assumeIsolated { task.didReceive(data) }
        }
    }

    nonisolated private static func finish(_ task: any WKURLSchemeTask, _ id: ObjectIdentifier, registry: StopRegistry) {
        DispatchQueue.main.async {
            if !registry.isStopped(id) { MainActor.assumeIsolated { task.didFinish() } }
            registry.clear(id)
        }
    }

    nonisolated static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "ply", "splat", "ksplat", "spz", "bin": return "application/octet-stream"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

/// 중단된 요청 목록 (스레드 안전)
final class StopRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<ObjectIdentifier>()
    func stop(_ id: ObjectIdentifier) { lock.lock(); ids.insert(id); lock.unlock() }
    func clear(_ id: ObjectIdentifier) { lock.lock(); ids.remove(id); lock.unlock() }
    func isStopped(_ id: ObjectIdentifier) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}
