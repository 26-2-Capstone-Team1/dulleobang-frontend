import ARKit
import SwiftUI

/// 일반 촬영(가구, 또는 LiDAR 없는 기기의 방 촬영)용 카메라 미리보기.
/// 특징점을 표시해 사용자가 "추적이 잘 되고 있는지" 볼 수 있게 한다.
struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.automaticallyUpdatesLighting = false
        v.debugOptions = [.showFeaturePoints]
        v.rendersCameraGrain = false
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    /// 일반 촬영 설정: 월드 트래킹 + (가능하면) LiDAR sceneDepth
    static func run(_ session: ARSession) {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = [.horizontal, .vertical]
        config.isAutoFocusEnabled = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
}
