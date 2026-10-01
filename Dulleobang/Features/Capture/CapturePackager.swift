import Foundation

/// 촬영 폴더 → capture.zip. 외부 라이브러리 없이 NSFileCoordinator(.forUploading) 의 내장 zip 기능을 쓴다.
/// zip 안의 구조:  capture/poses.json, capture/meta.json, capture/frames/000000.jpg, capture/depth/…, capture/confidence/…
///                 (LiDAR + RoomPlan 시) capture/roomplan.json, capture/roomplan_structure.json, capture/roomplan.usdz
enum CapturePackager {
    static func zip(_ captureDir: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let dest = captureDir.deletingLastPathComponent().appendingPathComponent("capture.zip")
            try? FileManager.default.removeItem(at: dest)
            var coordError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: captureDir, options: [.forUploading], error: &coordError) { tmpZip in
                do { try FileManager.default.copyItem(at: tmpZip, to: dest) } catch { copyError = error }
            }
            if let e = coordError ?? copyError { throw e }
            return dest
        }.value
    }

    static func sizeMB(_ url: URL) -> Double {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        return bytes / 1_048_576
    }

    /// 업로드가 끝난 촬영 폴더(+zip) 삭제. captureDir = …/<id>/capture
    static func cleanup(_ captureDir: URL) {
        try? FileManager.default.removeItem(at: captureDir.deletingLastPathComponent())
    }
}
