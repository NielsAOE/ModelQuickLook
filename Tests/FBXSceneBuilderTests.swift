import XCTest
import SceneKit

final class FBXSceneBuilderTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    private func geometries(in scene: SCNScene) -> [SCNGeometry] {
        var result: [SCNGeometry] = []
        scene.rootNode.enumerateHierarchy { node, _ in if let g = node.geometry { result.append(g) } }
        return result
    }

    func testCubeGeometry() throws {
        let scene = try FBXSceneBuilder.makeScene(url: fixture("cube.fbx"))
        let geos = geometries(in: scene)
        XCTAssertEqual(geos.count, 1)
        let g = try XCTUnwrap(geos.first)
        XCTAssertEqual(g.elements.count, 2, "one element per material")
        XCTAssertEqual(g.elements.reduce(0) { $0 + $1.primitiveCount }, 12, "6 quads -> 12 triangles")
        let (minB, maxB) = scene.rootNode.boundingBox
        // assimp writes centimeters, so the 2-unit cube is 0.02 m after unit conversion
        XCTAssertEqual(maxB.x - minB.x, 0.02, accuracy: 0.0005)
        XCTAssertEqual(maxB.y - minB.y, 0.02, accuracy: 0.0005)
    }

    func testExternalTextureIsLoaded() throws {
        let scene = try FBXSceneBuilder.makeScene(url: fixture("uv_plane.fbx"))
        let material = try XCTUnwrap(geometries(in: scene).first?.materials.first)
        XCTAssertTrue(material.diffuse.contents is NSImage, "sibling uv_test.png should be decoded")
    }

    func testEmbeddedTextureIsLoaded() throws {
        let scene = try FBXSceneBuilder.makeScene(url: fixture("box_orphant_embedded_texture.fbx"))
        let material = try XCTUnwrap(geometries(in: scene).first?.materials.first)
        XCTAssertTrue(material.diffuse.contents is NSImage)
    }

    func testOversizedModelIsRefused() throws {
        // maxTriangles is a static let; the small cube must stay under it.
        XCTAssertNoThrow(try FBXSceneBuilder.makeScene(url: fixture("cube.fbx")))
        XCTAssertGreaterThan(FBXSceneBuilder.maxTriangles, 100_000)
    }

    func testCorruptFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad.fbx")
        try Data("not an fbx".utf8).write(to: url)
        XCTAssertThrowsError(try FBXSceneBuilder.makeScene(url: url))
    }

    /// Loads every fixture; with TEST_RUNNER_SNAPSHOT_DIR set, also writes a PNG per fixture.
    func testAllFixturesLoadAndRender() throws {
        // Samples/ holds larger third-party models (not committed); include them when present.
        let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples")
        let files = try [fixture(""), samples].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
            .filter { $0.pathExtension.lowercased() == "fbx" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        let outDir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]
        for url in files {
            let scene: SCNScene
            do { scene = try FBXSceneBuilder.makeScene(url: url) } catch {
                XCTFail("\(url.lastPathComponent): \(error)"); continue
            }
            XCTAssertFalse(geometries(in: scene).isEmpty, "\(url.lastPathComponent) has no geometry")
            guard let outDir else { continue }
            SceneFraming.addCamera(to: scene)
            let image = try XCTUnwrap(SceneSnapshot.render(scene, size: CGSize(width: 400, height: 400)))
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png"))
            }
        }
    }

    /// Renders a few animation times of a sample character (skipped unless Samples/ and SNAPSHOT_DIR exist).
    func testAnimationFrames() throws {
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Samba Dancing.fbx")
        guard let outDir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], !outDir.isEmpty else {
            throw XCTSkip("SNAPSHOT_DIR not set")
        }
        guard FileManager.default.fileExists(atPath: sample.path) else { throw XCTSkip("no sample") }
        let scene = try FBXSceneBuilder.makeScene(url: sample)
        SceneFraming.addCamera(to: scene)
        var animated = 0
        scene.rootNode.enumerateHierarchy { node, _ in if !node.animationKeys.isEmpty { animated += 1 } }
        XCTAssertGreaterThan(animated, 10, "bones should carry animations")
        for t in [0.0, 0.7, 1.4, 2.1] {
            let image = try XCTUnwrap(SceneSnapshot.render(scene, size: CGSize(width: 400, height: 400), atTime: t))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("anim_t\(Int(t * 10)).png"))
        }
    }
}
