import Foundation
import AppKit
import SceneKit

enum FBXError: LocalizedError {
    case load(String)
    case tooLarge(triangles: Int)

    var errorDescription: String? {
        switch self {
        case .load(let message): return "Could not read FBX file: \(message)"
        case .tooLarge(let triangles):
            return "This model has \(triangles.formatted()) triangles, which is too large to preview."
        }
    }
}

/// Converts an FBX file (parsed by ufbx) into a SceneKit scene, Y-up and in meters.
enum FBXSceneBuilder {
    /// Models above this (counting instances) are refused so Quick Look doesn't kill the extension.
    static let maxTriangles = 5_000_000

    static func makeScene(url: URL) throws -> SCNScene {
        var opts = ufbx_load_opts()
        opts.target_axes = ufbx_axes_right_handed_y_up
        opts.target_unit_meters = 1
        opts.generate_missing_normals = true

        var error = ufbx_error()
        let path = url.path
        guard let loaded = ufbx_load_file_len(path, path.utf8.count, &opts, &error) else {
            throw FBXError.load(errorString(&error))
        }
        defer { ufbx_free_scene(loaded) }

        var triangles = 0
        for i in 0..<loaded.pointee.meshes.count {
            guard let mesh = loaded.pointee.meshes.data[i]?.pointee else { continue }
            triangles += Int(mesh.num_triangles) * max(1, mesh.instances.count)
        }
        if triangles > maxTriangles { throw FBXError.tooLarge(triangles: triangles) }

        let scene = SCNScene()
        let sceneRoot = scene.rootNode
        let context = BuildContext(cache: MaterialCache(baseDirectory: url.deletingLastPathComponent()))
        sceneRoot.addChildNode(buildNode(loaded.pointee.root_node, context: context))
        attachSkins(context)
        addAnimation(from: loaded, context: context)
        return scene
    }

    /// State shared while walking the ufbx node tree.
    private final class BuildContext {
        let cache: MaterialCache
        var nodes: [UInt32: SCNNode] = [:]   // ufbx node typed_id -> SCNNode
        var skins: [PendingSkin] = []
        init(cache: MaterialCache) { self.cache = cache }
    }

    /// A skinned mesh waits until every bone node exists before getting its SCNSkinner.
    private struct PendingSkin {
        let meshNode: SCNNode
        let geometry: SCNGeometry
        let boneIDs: [UInt32]
        let inverseBinds: [SCNMatrix4]
        let weights: SCNGeometrySource
        let indices: SCNGeometrySource
    }

    // MARK: - Nodes

    private static func buildNode(_ ufbxNode: UnsafeMutablePointer<ufbx_node>?, context: BuildContext) -> SCNNode {
        let node = SCNNode()
        guard let n = ufbxNode?.pointee else { return node }
        node.name = string(n.name)
        node.transform = scnMatrix(n.node_to_parent)
        node.isHidden = !n.visible
        context.nodes[n.typed_id] = node

        if let mesh = n.mesh, let (geometry, skin) = buildGeometry(mesh, cache: context.cache) {
            let meshNode = SCNNode(geometry: geometry)
            meshNode.transform = scnMatrix(n.geometry_to_node)
            node.addChildNode(meshNode)
            if let skin {
                context.skins.append(PendingSkin(meshNode: meshNode, geometry: geometry, boneIDs: skin.boneIDs,
                                                 inverseBinds: skin.inverseBinds, weights: skin.weights, indices: skin.indices))
            }
        }
        for i in 0..<n.children.count {
            node.addChildNode(buildNode(n.children.data[i], context: context))
        }
        return node
    }

    // MARK: - Geometry

    private struct SkinSources {
        let boneIDs: [UInt32]
        let inverseBinds: [SCNMatrix4]
        let weights: SCNGeometrySource
        let indices: SCNGeometrySource
    }

    private static func buildGeometry(_ meshPtr: UnsafeMutablePointer<ufbx_mesh>, cache: MaterialCache) -> (SCNGeometry, SkinSources?)? {
        let mesh = meshPtr.pointee
        let indexCount = Int(mesh.num_indices)
        guard indexCount > 0, mesh.vertex_position.exists else { return nil }

        // Unwelded per-corner vertices: simple, and keeps per-face normals/UV seams exact.
        var positions = [SIMD3<Float>](repeating: .zero, count: indexCount)
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: indexCount)
        var uvs = [SIMD2<Float>](repeating: .zero, count: indexCount)
        for ix in 0..<indexCount {
            positions[ix] = vec3(mesh.vertex_position.values.data[Int(mesh.vertex_position.indices.data[ix])])
            if mesh.vertex_normal.exists {
                normals[ix] = vec3(mesh.vertex_normal.values.data[Int(mesh.vertex_normal.indices.data[ix])])
            }
            if mesh.vertex_uv.exists {
                let uv = mesh.vertex_uv.values.data[Int(mesh.vertex_uv.indices.data[ix])]
                uvs[ix] = SIMD2(Float(uv.x), 1 - Float(uv.y)) // FBX V runs bottom-up, SceneKit top-down
            }
        }
        let skinSources = mesh.skin_deformers.count > 0 ? makeSkinSources(mesh.skin_deformers.data[0], mesh: mesh) : nil

        var sources = [
            SCNGeometrySource(data: Data(bytes: positions, count: indexCount * MemoryLayout<SIMD3<Float>>.stride),
                              semantic: .vertex, vectorCount: indexCount, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                              dataStride: MemoryLayout<SIMD3<Float>>.stride),
            SCNGeometrySource(data: Data(bytes: normals, count: indexCount * MemoryLayout<SIMD3<Float>>.stride),
                              semantic: .normal, vectorCount: indexCount, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                              dataStride: MemoryLayout<SIMD3<Float>>.stride),
        ]
        if mesh.vertex_uv.exists {
            sources.append(SCNGeometrySource(data: Data(bytes: uvs, count: indexCount * MemoryLayout<SIMD2<Float>>.stride),
                                             semantic: .texcoord, vectorCount: indexCount, usesFloatComponents: true,
                                             componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0,
                                             dataStride: MemoryLayout<SIMD2<Float>>.stride))
        }

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        var scratch = [UInt32](repeating: 0, count: Int(mesh.max_face_triangles) * 3)

        func makeElement(faceIndices: [Int]) -> SCNGeometryElement? {
            var tris: [UInt32] = []
            for f in faceIndices {
                let face = mesh.faces.data[f]
                guard face.num_indices >= 3 else { continue }
                let count = Int(ufbx_triangulate_face(&scratch, scratch.count, meshPtr, face))
                tris.append(contentsOf: scratch[0..<(count * 3)])
            }
            guard !tris.isEmpty else { return nil }
            return SCNGeometryElement(indices: tris, primitiveType: .triangles)
        }

        if mesh.material_parts.count > 0 {
            for p in 0..<mesh.material_parts.count {
                let part = mesh.material_parts.data[p]
                let faces = (0..<part.face_indices.count).map { Int(part.face_indices.data[$0]) }
                guard let element = makeElement(faceIndices: faces) else { continue }
                elements.append(element)
                let ufbxMaterial = Int(part.index) < mesh.materials.count ? mesh.materials.data[Int(part.index)] : nil
                materials.append(cache.material(for: ufbxMaterial))
            }
        } else if let element = makeElement(faceIndices: Array(0..<Int(mesh.faces.count))) {
            elements.append(element)
            materials.append(cache.material(for: nil))
        }
        guard !elements.isEmpty else { return nil }

        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = materials
        return (geometry, skinSources)
    }

    // MARK: - Skinning

    /// Up to 4 strongest bone influences per vertex (ufbx sorts weights by decreasing strength), per mesh corner.
    private static func makeSkinSources(_ skinPtr: UnsafeMutablePointer<ufbx_skin_deformer>?, mesh: ufbx_mesh) -> SkinSources? {
        guard let skin = skinPtr?.pointee, skin.clusters.count > 0 else { return nil }
        var boneIDs: [UInt32] = []
        var inverseBinds: [SCNMatrix4] = []
        for c in 0..<skin.clusters.count {
            guard let cluster = skin.clusters.data[c]?.pointee, let bone = cluster.bone_node else { return nil }
            boneIDs.append(bone.pointee.typed_id)
            inverseBinds.append(scnMatrix(cluster.geometry_to_bone))
        }

        let count = Int(mesh.num_indices)
        var weights = [SIMD4<Float>](repeating: .zero, count: count)
        var indices = [SIMD4<UInt16>](repeating: .zero, count: count)
        for ix in 0..<count {
            let vertex = Int(mesh.vertex_indices.data[ix])
            guard vertex < skin.vertices.count else { continue }
            let sv = skin.vertices.data[vertex]
            var w = SIMD4<Float>.zero
            var idx = SIMD4<UInt16>.zero
            for k in 0..<min(4, Int(sv.num_weights)) {
                let weight = skin.weights.data[Int(sv.weight_begin) + k]
                w[k] = Float(weight.weight)
                idx[k] = UInt16(truncatingIfNeeded: weight.cluster_index)
            }
            let total = w.sum()
            weights[ix] = total > 0 ? w / total : SIMD4(1, 0, 0, 0)
            indices[ix] = idx
        }
        return SkinSources(
            boneIDs: boneIDs, inverseBinds: inverseBinds,
            weights: SCNGeometrySource(data: Data(bytes: weights, count: count * MemoryLayout<SIMD4<Float>>.stride),
                                       semantic: .boneWeights, vectorCount: count, usesFloatComponents: true,
                                       componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0,
                                       dataStride: MemoryLayout<SIMD4<Float>>.stride),
            indices: SCNGeometrySource(data: Data(bytes: indices, count: count * MemoryLayout<SIMD4<UInt16>>.stride),
                                       semantic: .boneIndices, vectorCount: count, usesFloatComponents: false,
                                       componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0,
                                       dataStride: MemoryLayout<SIMD4<UInt16>>.stride))
    }

    private static func attachSkins(_ context: BuildContext) {
        for skin in context.skins {
            let bones = skin.boneIDs.compactMap { context.nodes[$0] }
            guard bones.count == skin.boneIDs.count else { continue }
            skin.meshNode.skinner = SCNSkinner(baseGeometry: skin.geometry, bones: bones,
                                               boneInverseBindTransforms: skin.inverseBinds.map { NSValue(scnMatrix4: $0) },
                                               boneWeights: skin.weights, boneIndices: skin.indices)
        }
    }

    // MARK: - Animation

    static let animationFrameRate = 30.0
    private static let maxAnimationFrames = 1800

    /// Samples the longest animation stack into one looping transform animation per moving node.
    private static func addAnimation(from scene: UnsafeMutablePointer<ufbx_scene>, context: BuildContext) {
        var best: UnsafeMutablePointer<ufbx_anim_stack>?
        for i in 0..<scene.pointee.anim_stacks.count {
            guard let stack = scene.pointee.anim_stacks.data[i] else { continue }
            if stack.pointee.time_end - stack.pointee.time_begin > (best.map { $0.pointee.time_end - $0.pointee.time_begin } ?? 0.001) {
                best = stack
            }
        }
        guard let stack = best?.pointee, let anim = stack.anim else { return }
        let duration = stack.time_end - stack.time_begin
        let frames = min(maxAnimationFrames, Int((duration * animationFrameRate).rounded(.up)) + 1)
        guard frames > 1 else { return }

        let root = scene.pointee.root_node
        for i in 0..<scene.pointee.nodes.count {
            guard let ufbxNode = scene.pointee.nodes.data[i], ufbxNode != root,
                  let node = context.nodes[ufbxNode.pointee.typed_id] else { continue }
            var values: [NSValue] = []
            var first: SCNMatrix4?
            var moves = false
            for f in 0..<frames {
                let time = stack.time_begin + duration * Double(f) / Double(frames - 1)
                var transform = ufbx_evaluate_transform(anim, ufbxNode, time)
                let m = scnMatrix(ufbx_transform_to_matrix(&transform))
                if let first { if !moves, !nearlyEqual(first, m) { moves = true } } else { first = m }
                values.append(NSValue(scnMatrix4: m))
            }
            guard moves else { continue }
            let animation = CAKeyframeAnimation(keyPath: "transform")
            animation.values = values
            animation.keyTimes = (0..<frames).map { NSNumber(value: Double($0) / Double(frames - 1)) }
            animation.duration = duration
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            node.addAnimation(animation, forKey: "fbx-anim")
        }
    }

    private static func nearlyEqual(_ a: SCNMatrix4, _ b: SCNMatrix4) -> Bool {
        let x = [a.m11, a.m12, a.m13, a.m21, a.m22, a.m23, a.m31, a.m32, a.m33, a.m41, a.m42, a.m43]
        let y = [b.m11, b.m12, b.m13, b.m21, b.m22, b.m23, b.m31, b.m32, b.m33, b.m41, b.m42, b.m43]
        return zip(x, y).allSatisfy { abs($0 - $1) < 1e-5 }
    }

    // MARK: - Helpers

    private static func vec3(_ v: ufbx_vec3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

    private static func string(_ s: ufbx_string) -> String? {
        guard s.length > 0, let data = s.data else { return nil }
        return String(cString: data)
    }

    private static func scnMatrix(_ m: ufbx_matrix) -> SCNMatrix4 {
        SCNMatrix4(m11: m.m00, m12: m.m10, m13: m.m20, m14: 0,
                   m21: m.m01, m22: m.m11, m23: m.m21, m24: 0,
                   m31: m.m02, m32: m.m12, m33: m.m22, m34: 0,
                   m41: m.m03, m42: m.m13, m43: m.m23, m44: 1)
    }

    private static func errorString(_ error: inout ufbx_error) -> String {
        string(error.description) ?? "unknown error"
    }
}

/// One SCNMaterial per FBX material, shared across meshes. Textures are decoded while the
/// ufbx scene is alive, so the resulting SceneKit objects never reference ufbx memory.
private final class MaterialCache {
    private let baseDirectory: URL
    private var materials: [OpaquePointer: SCNMaterial] = [:]
    private var images: [OpaquePointer: NSImage] = [:]

    init(baseDirectory: URL) { self.baseDirectory = baseDirectory }

    private lazy var fallback: SCNMaterial = {
        let m = Self.base(name: nil)
        m.diffuse.contents = NSColor(white: 0.75, alpha: 1)
        return m
    }()

    func material(for ufbxMaterial: UnsafeMutablePointer<ufbx_material>?) -> SCNMaterial {
        guard let ufbxMaterial else { return fallback }
        let key = OpaquePointer(ufbxMaterial)
        if let hit = materials[key] { return hit }
        let pbr = ufbxMaterial.pointee.pbr
        let name = ufbxMaterial.pointee.name.length > 0 ? String(cString: ufbxMaterial.pointee.name.data) : nil
        let m = Self.base(name: name)

        // Base color: texture wins; otherwise the constant color.
        if let image = image(pbr.base_color) {
            m.diffuse.contents = image
        } else if pbr.base_color.texture != nil && pbr.base_color.texture_enabled {
            // Texture is referenced but unreadable (missing or sandboxed): the constant is usually a placeholder.
            m.diffuse.contents = NSColor(white: 0.75, alpha: 1)
        } else {
            let c = pbr.base_color.value_vec4
            let f = pbr.base_factor.has_value ? CGFloat(pbr.base_factor.value_real) : 1
            m.diffuse.contents = NSColor(red: CGFloat(c.x) * f, green: CGFloat(c.y) * f, blue: CGFloat(c.z) * f, alpha: 1)
        }

        m.metalness.contents = image(pbr.metalness) ?? (pbr.metalness.has_value ? CGFloat(pbr.metalness.value_real) : 0)
        m.roughness.contents = image(pbr.roughness) ?? (pbr.roughness.has_value ? CGFloat(pbr.roughness.value_real) : 0.6)

        if let image = image(pbr.normal_map) { m.normal.contents = image }
        if let image = image(pbr.ambient_occlusion) { m.ambientOcclusion.contents = image }

        if let image = image(pbr.emission_color) {
            m.emission.contents = image
        } else if pbr.emission_factor.has_value, pbr.emission_factor.value_real > 0 {
            let c = pbr.emission_color.value_vec3
            let f = CGFloat(pbr.emission_factor.value_real)
            m.emission.contents = NSColor(red: CGFloat(c.x) * f, green: CGFloat(c.y) * f, blue: CGFloat(c.z) * f, alpha: 1)
        }

        // Constant opacity only; opacity textures are not mapped.
        if pbr.opacity.has_value, pbr.opacity.value_real < 1 {
            m.transparency = CGFloat(max(0, pbr.opacity.value_real))
        }

        for property in [m.diffuse, m.metalness, m.roughness, m.normal, m.ambientOcclusion, m.emission] {
            property.wrapS = .repeat
            property.wrapT = .repeat
        }
        materials[key] = m
        return m
    }

    /// Decodes the map's texture (embedded blob or external file ufbx managed to read), if any.
    private func image(_ map: ufbx_material_map) -> NSImage? {
        guard map.texture_enabled, let texture = map.texture else { return nil }
        let key = OpaquePointer(texture)
        if let hit = images[key] { return hit }
        var image: NSImage?
        let blob = texture.pointee.content
        if blob.size > 0, let bytes = blob.data {
            image = NSImage(data: Data(bytes: bytes, count: blob.size)) // embedded
        } else {
            image = externalImage(texture.pointee) // next to the model; unreadable when sandboxed
        }
        guard let image else { return nil }
        images[key] = image
        return image
    }

    private func externalImage(_ texture: ufbx_texture) -> NSImage? {
        let candidates = [texture.filename, texture.relative_filename, texture.absolute_filename]
            .compactMap { str -> String? in
                guard str.length > 0, let data = str.data else { return nil }
                return String(cString: data).replacingOccurrences(of: "\\", with: "/")
            }
        for path in candidates {
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDirectory.appendingPathComponent(path)
            if let image = NSImage(contentsOf: url) { return image }
            // Windows-style absolute paths: fall back to the bare file name next to the model.
            let local = baseDirectory.appendingPathComponent(url.lastPathComponent)
            if let image = NSImage(contentsOf: local) { return image }
        }
        return nil
    }

    private static func base(name: String?) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = name
        material.lightingModel = .physicallyBased
        material.isDoubleSided = true
        return material
    }
}
