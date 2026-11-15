import Foundation
import OSLog
import RealityKit

/// Camera-dependent Classic finishes. The optional index can describe individual
/// body surfaces and portable USD material names shared by interchangeable wheels.
@MainActor final class ClassicComponents {
    struct Paint {
        let rgb: SIMD3<Float>
        let metallic, roughness: Float
        var deepenUltraRed = false
    }

    private struct Definition: Decodable {
        let file, prim: String
        let twoSided, paint: Bool?
        let fixedRoughness: Float?
    }

    private struct Index: Decodable {
        let version: Int
        let materials: [String: Definition]
        let bindings, bySourceMaterial: [String: String]?
    }

    private static let log = Logger(subsystem: "TeslaVehicleKit", category: "ClassicComponents")
    private(set) var hasDisplayGlass = false
    private let directory: URL
    private let index: Index
    private let wheelRoots: Set<String>
    private var templates: [String: ShaderGraphMaterial] = [:]
    private var unavailable: Set<String> = []
    private var lighting: VehicleManifest.Rig.Lighting?
    private var paint: Paint?
    private var active: [String: ShaderGraphMaterial] = [:]
    private var mirrored: [String: ShaderGraphMaterial] = [:]

    init?(vehicle: URL, wheelRoots: Set<String>) {
        let directory = vehicle.appendingPathComponent("Classic", isDirectory: true)
        let file = directory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: file))
            guard index.version == 1 else { throw VehicleError.invalid("Unsupported Classic component index") }
            self.index = index
        } catch {
            Self.log.error("Using portable materials for \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.directory = directory
        self.wheelRoots = wheelRoots
    }

    private func identifier(for material: any Material, path: String?, slot: Int) -> String? {
        if slot == 0, let path, let id = index.bindings?[path] { return id }
        guard let name = material.name else { return nil }
        return index.bySourceMaterial?[name]
    }

    /// Stop using body path bindings inside a wheel. A cover variant can put an
    /// entirely different material at the same relative surface path.
    func bodyPath(_ path: String?) -> String? {
        guard let path, !wheelRoots.contains(path) else { return nil }
        return path
    }

    func collectIdentifiers(on node: Entity, bodyPath: String?, into needed: inout Set<String>) {
        guard let model = node.components[ModelComponent.self] else { return }
        for (slot, material) in model.materials.enumerated() {
            if let id = identifier(for: material, path: bodyPath, slot: slot) { needed.insert(id) }
        }
    }

    func identifiers(inWheel wheel: Entity) -> Set<String> {
        var needed: Set<String> = []
        func visit(_ node: Entity) {
            collectIdentifiers(on: node, bodyPath: nil, into: &needed)
            for child in node.children { visit(child) }
        }
        visit(wheel)
        return needed
    }

    func prepare(_ needed: Set<String>) async throws {
        try Task.checkCancellation()
        let missing = needed.filter { index.materials[$0] != nil && templates[$0] == nil && !unavailable.contains($0) }
        guard !missing.isEmpty else { return }
        var jobs = missing.sorted().makeIterator()
        try await withThrowingTaskGroup(of: (String, Result<ShaderGraphMaterial, Error>).self) { group in
            func enqueue() {
                guard let id = jobs.next(), let definition = index.materials[id] else { return }
                let file = directory.appendingPathComponent(definition.file).standardizedFileURL
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileNoSuchFile) }
                        var graph = try await ShaderGraphMaterial(named: definition.prim, from: file)
                        graph.faceCulling = definition.twoSided == true ? .none : .back
                        return (id, .success(graph))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            // Overlap independent USD imports while bounding simultaneous texture decodes.
            for _ in 0..<8 { enqueue() }
            while let (id, result) = try await group.next() {
                try Task.checkCancellation()
                switch result {
                case .success(let graph):
                    templates[id] = graph
                    if !hasDisplayGlass && graph.parameterNames.contains("DisplayTransfer") { hasDisplayGlass = true }
                    update(id)
                case .failure(let error):
                    unavailable.insert(id)
                    Self.log.error("Using portable material for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                enqueue()
            }
        }
    }

    func setLighting(_ lighting: VehicleManifest.Rig.Lighting?) {
        self.lighting = lighting
        active.removeAll(keepingCapacity: true)
        mirrored.removeAll(keepingCapacity: true)
        if lighting != nil { for id in templates.keys { update(id) } }
    }

    func setPaint(_ paint: Paint?) {
        self.paint = paint
        if lighting != nil {
            for id in templates.keys where index.materials[id]?.paint == true { update(id) }
        }
    }

    private func update(_ id: String) {
        guard let lighting, let definition = index.materials[id], var graph = templates[id] else { return }
        mirrored.removeValue(forKey: id)
        do {
            try lighting.apply(to: &graph)
            if let paint, definition.paint == true {
                try ClassicPaint.apply(to: &graph, rgb: paint.rgb, metallic: paint.metallic,
                                       roughness: definition.fixedRoughness ?? paint.roughness,
                                       deepenUltraRed: paint.deepenUltraRed)
            }
            active[id] = graph
        } catch {
            active.removeValue(forKey: id)
            Self.log.error("Using portable material for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    var isActive: Bool { !active.isEmpty }

    func finish(
        for original: any Material, path: String?, slot: Int,
        customPaintSurface: Bool, reversedWinding: @autoclosure () -> Bool
    ) -> ShaderGraphMaterial? {
        guard let id = identifier(for: original, path: path, slot: slot),
              !customPaintSurface || index.materials[id]?.paint == true, var graph = active[id] else { return nil }
        guard reversedWinding() else { return graph }
        if let variant = mirrored[id] { return variant }
        guard graph.parameterNames.contains("NormalSign") else { return graph }
        // A negatively scaled instance reverses triangle winding. RealityKit
        // also flips its shading normal when drawing the exposed back face.
        if graph.faceCulling == .back { graph.faceCulling = .front }
        do {
            try graph.setParameter(name: "NormalSign", value: .float(-1))
            mirrored[id] = graph
            return graph
        } catch {
            Self.log.error("Using portable material for mirrored \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
