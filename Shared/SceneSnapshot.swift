import AppKit
import SceneKit

enum SceneSnapshot {
    /// Renders the scene (camera must already be added via `SceneFraming`) to an image offscreen.
    static func render(_ scene: SCNScene, size: CGSize, atTime time: TimeInterval = 0) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true
        renderer.pointOfView = scene.rootNode.childNode(withName: SceneFraming.cameraName, recursively: false)
        return renderer.snapshot(atTime: time, with: size, antialiasingMode: .multisampling4X)
    }
}
