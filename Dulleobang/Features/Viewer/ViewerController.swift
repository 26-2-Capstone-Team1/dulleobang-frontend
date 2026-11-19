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
    case bounds(min: Vec3, max: Vec3)       // 방 구조 없이 연 방 메시의 범위 (뷰어가 메시 크기에서 잡아 알려 준다)
    case meshFailed(String)                 // 방 메시를 못 읽음 (깨진 파일 · 메모리 부족) → 점구름이 있으면 그것으로 다시 연다
    case crashed                            // 뷰어(웹 프로세스)가 죽었다가 다시 떴다. 큰 메시로 메모리가 모자라면 iOS 가 웹 프로세스를 끝낸다
    case objectShots([String: String])      // 가구마다 방 안에서 비춘 그림 (objectId → data:image/jpeg;base64,…)

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
        case "meshFailed": self = .meshFailed(d["message"] as? String ?? "")
        case "objectShots": self = .objectShots(d["shots"] as? [String: String] ?? [:])
        case "bounds":
            func vec(_ k: String) -> Vec3? {
                guard let v = d[k] as? [String: Any],
                      let x = (v["x"] as? NSNumber)?.doubleValue,
                      let y = (v["y"] as? NSNumber)?.doubleValue,
                      let z = (v["z"] as? NSNumber)?.doubleValue else { return nil }
                return Vec3(x: x, y: y, z: z)
            }
            guard let lo = vec("min"), let hi = vec("max") else { return nil }
            self = .bounds(min: lo, max: hi)
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
    private let navigation = NavigationProxy()               // WKWebView 는 delegate 를 약하게 잡으므로 여기서 들고 있는다
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
        navigation.onTerminate = { [weak self] in self?.webContentDidTerminate() }
        webView.navigationDelegate = navigation
        webView.load(URLRequest(url: ViewerAssetHandler.indexURL))
    }

    /// 웹 프로세스가 죽음 (메모리 부족 등). 화면이 빈 채로 멈추지 않게 뷰어를 새로 띄우고, 장면은 받은 쪽(.crashed)이 다시 연다
    private func webContentDidTerminate() {
        isReady = false
        pending.removeAll()
        webView.load(URLRequest(url: ViewerAssetHandler.indexURL))
        onEvent?(.crashed)
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

/// 웹 프로세스 종료를 알려 주는 얇은 프록시 (WebKit 은 메인 스레드에서 부른다)
final class NavigationProxy: NSObject, WKNavigationDelegate {
    var onTerminate: (@MainActor () -> Void)?
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { onTerminate?() }
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
