import Cocoa
import Quartz
import SceneKit

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let sceneView = SCNView()

    override func loadView() {
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.antialiasingMode = .multisampling4X
        sceneView.isPlaying = true // runs skeletal/node animations
        sceneView.loops = true
        sceneView.backgroundColor = .windowBackgroundColor
        view = sceneView
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let scene: SCNScene
        do {
            scene = try await Task.detached(priority: .userInitiated) {
                let scene = try FBXSceneBuilder.makeScene(url: url)
                SceneFraming.addCamera(to: scene)
                return scene
            }.value
        } catch {
            showMessage(error.localizedDescription)
            return
        }
        sceneView.scene = scene
        sceneView.pointOfView = scene.rootNode.childNode(withName: SceneFraming.cameraName, recursively: false)
    }

    private func showMessage(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        sceneView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: sceneView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: sceneView.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: sceneView.widthAnchor, constant: -40),
        ])
    }
}
