import SceneKit

enum SceneFraming {
    static let cameraName = "fbx-preview-camera"

    /// Adds a camera that sees the whole scene from a 3/4 front-above angle.
    static func addCamera(to scene: SCNScene) {
        let (minB, maxB) = scene.rootNode.boundingBox
        var center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        var radius = CGFloat(0.5) * hypot(hypot(maxB.x - minB.x, maxB.y - minB.y), maxB.z - minB.z)
        if !(radius.isFinite && radius > 0) { radius = 1; center = SCNVector3Zero }

        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = Double(radius) / 100
        camera.zFar = Double(radius) * 100
        let distance = radius / CGFloat(sin(camera.fieldOfView * .pi / 360)) * 1.1

        let node = SCNNode()
        node.name = cameraName
        node.camera = camera
        let dir = SCNVector3(0.5, 0.35, 1) // normalized below
        let len = sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
        node.position = SCNVector3(center.x + dir.x / len * distance,
                                   center.y + dir.y / len * distance,
                                   center.z + dir.z / len * distance)
        let target = SCNNode()
        target.position = center
        scene.rootNode.addChildNode(target)
        node.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(node)
    }
}
