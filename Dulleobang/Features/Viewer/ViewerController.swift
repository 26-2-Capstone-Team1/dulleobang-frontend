import Combine
import SwiftUI
import WebKit

/// 뷰어(JS) → 앱 이벤트
enum ViewerEvent {
    case ready
    case loaded
    case progress(Double)
    case error(String)
    case select(String?)
    case transform(id: String, x: Double, z: Double, yaw: Double, final: Bool)
    case furnitureLoaded(String)

    init?(_ body: Any) {
        guard let d = body as? [String: Any], let type = d["type"] as? String else { return nil }
        func num(_ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        switch type {
        case "ready": self = .ready
        case "loaded": self = .loaded
        case "progress": self = .progress(num("value"))
        case "error": self = .error(d["message"] as? String ?? "알 수 없는 오류")
        case "select": self = .select(d["id"] as? String)
        case "transform":
            guard let id = d["id"] as? String else { return nil }
            self = .transform(id: id, x: num("x"), z: num("z"), yaw: num("yaw"), final: (d["final"] as? Bool) ?? false)
        case "furnitureLoaded": self = .furnitureLoaded(d["id"] as? String ?? "")
        default: return nil
        }
    }
}

/// WKWebView(three.js 뷰어)를 소유하고 Swift ↔ JS 호출을 중개한다.
/// JS 쪽 API 는 window.DV (Resources/Viewer/viewer.js 참고).
@MainActor
final class ViewerController: ObservableObject {
    let webView: WKWebView
    @Published private(set) var isReady = false
    var onEvent: (@MainActor (ViewerEvent) -> Void)?

    private var pending: [String] = []
    private let proxy = ScriptMessageProxy()
    private let encoder = JSONEncoder()

    init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ViewerAssetHandler.shared, forURLScheme: ViewerAssetHandler.scheme)
        config.userContentController.add(proxy, name: "dulleobang")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isInspectable = true                                  // Mac Safari › 개발자 메뉴에서 JS 디버깅
        proxy.onMessage = { [weak self] body in self?.receive(body) }
        webView.load(URLRequest(url: ViewerAssetHandler.indexURL))
    }

    /// DV.<fn>(args…) 호출. 뷰어 준비 전이면 큐에 쌓았다가 ready 이벤트 때 보낸다.
    func call(_ fn: String, _ args: any Encodable...) {
        let json = args.map { arg -> String in
            (try? encoder.encode(arg)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
        let script = "window.DV && DV.\(fn)(\(json.joined(separator: ","))); 0"
        if isReady { run(script) } else { pending.append(script) }
    }

    private func run(_ script: String) {
        webView.evaluateJavaScript(script) { _, error in
            if let error { print("[viewer] JS error: \(error.localizedDescription)\n\(script.prefix(200))") }
        }
    }

    private func receive(_ body: Any) {
        guard let ev = ViewerEvent(body) else { return }
        if case .ready = ev {
            isReady = true
            pending.forEach { run($0) }
            pending.removeAll()
        }
        onEvent?(ev)
    }

    func reload() {
        isReady = false
        webView.reload()
    }

    /// 뷰어가 준비될 때까지 대기 (최대 timeout 초). CDN 로딩 실패 시 false.
    func waitUntilReady(timeout: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return isReady
    }
}

/// WKUserContentController 가 핸들러를 강하게 잡으므로 순환 참조를 피하는 얇은 프록시
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: (@MainActor (Any) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body                                     // WebKit 은 메인 스레드에서 호출한다
        MainActor.assumeIsolated { onMessage?(body) }
    }
}

struct ViewerWebView: UIViewRepresentable {
    let controller: ViewerController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
