import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// 깊이 · 신뢰도 한 프레임의 요약 (depth.json 의 frames 항목)
struct DepthFrameSummary: Codable {
    var frameId: Int
    var depth: String
    var preview: String
    var valid: Double                   // 깊이가 측정된 픽셀 비율 0…1
    var minM: Double?
    var medianM: Double?
    var maxM: Double?
    var confidence: ConfidenceShare?
    var confidencePreview: String?
}

struct ConfidenceShare: Codable {
    var low: Double, medium: Double, high: Double
}

/// ARFrame 의 픽셀 버퍼들을 파일로 쓴다. 전용 직렬 큐에서만 호출한다.
///  - RGB: capturedImage(YCbCr 420f, 센서 원래 방향 = 가로) → JPEG. 회전하지 않으므로 intrinsics(K) 가 그대로 맞는다.
///  - Depth: sceneDepth.depthMap(Float32, m, 256×192) → 16-bit PNG, 밀리미터 (AI 가 쓰는 원본)
///           + depth_vis/ 히트맵 JPEG (Turbo, 0.2 m 파랑 → 5 m 빨강, 검정 = 측정 없음. 보기용)
///  - Confidence: sceneDepth.confidenceMap(UInt8: 0 low / 1 medium / 2 high) → 8-bit PNG (원본)
///           + confidence_vis/ 색 PNG (빨강 낮음 · 노랑 중간 · 초록 높음. 보기용)
/// 원본 PNG 는 값이 작아(0.25–5 m = 250–5000 / 65535) 일반 뷰어에서 검게 보이는 것이 정상이라 보기용 사본을 따로 만든다.
/// tools/capture/depth_tools.py 가 같은 색으로 예전 촬영본에도 만들어 준다.
final class FrameWriter {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static let previewNear: Float = 0.2
    static let previewFar: Float = 5.0

    /// Google Turbo 컬러맵 (다항식 근사, depth_tools.py 와 같은 식) → 256 단계
    private static let turbo: [(UInt8, UInt8, UInt8)] = (0..<256).map { i in
        let x = Double(i) / 255
        func channel(_ c: [Double]) -> UInt8 {
            var v = 0.0
            for k in c.reversed() { v = v * x + k }
            return UInt8(max(0, min(255, (v * 255).rounded())))
        }
        return (channel([0.13572138, 4.61539260, -42.66032258, 132.13108234, -152.94239396, 59.28637943]),
                channel([0.09140261, 2.19418839, 4.84296658, -14.18503333, 4.27729857, 2.82956604]),
                channel([0.10667330, 12.64194608, -60.58204836, 110.36276771, -89.90310912, 27.34824973]))
    }

    private static let confidenceColors: [(UInt8, UInt8, UInt8)] = [(230, 70, 70), (245, 190, 50), (60, 180, 90)]

    private static func rounded(_ v: Double, places: Int) -> Double {
        var p = 1.0
        for _ in 0..<places { p *= 10 }
        return (v * p).rounded() / p
    }

    func writeJPEG(_ pixelBuffer: CVPixelBuffer, to url: URL, quality: CGFloat) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let data = ciContext.jpegRepresentation(
            of: image, colorSpace: srgb,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { throw WriterError.encode("jpeg") }
        try data.write(to: url, options: .atomic)
    }

    /// 깊이(Float32, m) → 원본 16-bit PNG(mm) + 히트맵 JPEG(보기용). 측정 비율 · 최소 · 중앙 · 최대 거리(m)를 돌려준다.
    func writeDepth(_ depth: CVPixelBuffer, raw: URL, preview: URL?) throws
        -> (valid: Double, minM: Double?, medianM: Double?, maxM: Double?) {
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(depth) else { throw WriterError.format("depth") }
        let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
        let rowBytes = CVPixelBufferGetBytesPerRow(depth)
        var mm = [UInt16](repeating: 0, count: w * h)
        var rgbx = [UInt8](repeating: 0, count: w * h * 4)           // 측정 없음 = 검정
        var histogram = [Int](repeating: 0, count: 1001)              // 1 cm 칸 (0–10 m) → 중앙값
        var count = 0
        var lo = Float.greatestFiniteMagnitude, hi: Float = 0
        let near = Self.previewNear, span = Self.previewFar - Self.previewNear
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                let m = row[x]
                guard m.isFinite, m > 0 else { continue }
                let i = y * w + x
                mm[i] = UInt16(min(m * 1000, 65535).rounded())
                count += 1
                lo = min(lo, m)
                hi = max(hi, m)
                histogram[Int(min(m * 100, 1000))] += 1
                let t = min(max((m - near) / span, 0), 1)
                let c = Self.turbo[Int(t * 255 + 0.5)]
                rgbx[i * 4] = c.0
                rgbx[i * 4 + 1] = c.1
                rgbx[i * 4 + 2] = c.2
            }
        }
        let data = mm.withUnsafeBytes { Data($0) }                   // 호스트(리틀 엔디언) 바이트 순서
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        try writePNG(data: data, width: w, height: h, bitsPerComponent: 16, bitmapInfo: info, to: raw)
        if let preview { try writeColor(rgbx, width: w, height: h, type: .jpeg, to: preview) }

        guard count > 0 else { return (0, nil, nil, nil) }
        var acc = 0, medianBin = 0
        for (bin, n) in histogram.enumerated() {
            acc += n
            if acc * 2 >= count { medianBin = bin; break }
        }
        return (Self.rounded(Double(count) / Double(w * h), places: 4), Self.rounded(Double(lo), places: 3),
                Self.rounded((Double(medianBin) + 0.5) / 100, places: 3), Self.rounded(Double(hi), places: 3))
    }

    /// 신뢰도(UInt8: 0/1/2) → 원본 8-bit PNG + 색 PNG(보기용). 낮음 · 중간 · 높음 비율을 돌려준다.
    func writeConfidence(_ conf: CVPixelBuffer, raw: URL, preview: URL?) throws -> ConfidenceShare {
        CVPixelBufferLockBaseAddress(conf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(conf) else { throw WriterError.format("confidence") }
        let w = CVPixelBufferGetWidth(conf), h = CVPixelBufferGetHeight(conf)
        let rowBytes = CVPixelBufferGetBytesPerRow(conf)
        var out = [UInt8](repeating: 0, count: w * h)
        var rgbx = [UInt8](repeating: 0, count: w * h * 4)
        var counts = [0, 0, 0]
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let value = row[x]
                let level = Int(min(value, 2))
                let i = y * w + x
                out[i] = value
                counts[level] += 1
                let c = Self.confidenceColors[level]
                rgbx[i * 4] = c.0
                rgbx[i * 4 + 1] = c.1
                rgbx[i * 4 + 2] = c.2
            }
        }
        try writePNG(data: Data(out), width: w, height: h, bitsPerComponent: 8,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), to: raw)
        if let preview { try writeColor(rgbx, width: w, height: h, type: .png, to: preview) }
        let total = Double(max(w * h, 1))
        return ConfidenceShare(low: Self.rounded(Double(counts[0]) / total, places: 4),
                               medium: Self.rounded(Double(counts[1]) / total, places: 4),
                               high: Self.rounded(Double(counts[2]) / total, places: 4))
    }

    /// RGBX 8-bit → JPEG/PNG (보기용 사본)
    private func writeColor(_ rgbx: [UInt8], width: Int, height: Int, type: UTType, to url: URL) throws {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let provider = CGDataProvider(data: Data(rgbx) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: srgb, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw WriterError.encode("preview") }
        let props: CFDictionary? = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality as String: 0.9] as CFDictionary
            : nil
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { throw WriterError.encode("preview finalize") }
    }

    private func writePNG(data: Data, width: Int, height: Int, bitsPerComponent: Int,
                          bitmapInfo: CGBitmapInfo, to url: URL) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerComponent,
                                  bytesPerRow: width * bitsPerComponent / 8,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw WriterError.encode("png") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw WriterError.encode("png finalize") }
    }

    enum WriterError: Error { case encode(String), format(String) }
}
