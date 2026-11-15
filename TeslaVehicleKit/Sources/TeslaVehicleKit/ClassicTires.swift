import Foundation
import RealityKit
import simd

extension VehicleManifest.Rig.Lighting {
    @MainActor func apply(to graph: inout ShaderGraphMaterial) throws {
        // Dot products with the forward sky basis rotate world directions
        // back into the source panorama. Unshaded materials omit these inputs.
        let inputs = graph.parameterNames
        let basis = simd_float3x3(try orientation())
        if inputs.contains("SkyEnergy") { try graph.setParameter(name: "SkyEnergy", value: .float(skyEnergy)) }
        if inputs.contains("AmbientEnergy") { try graph.setParameter(name: "AmbientEnergy", value: .float(ambientEnergy)) }
        for (key, axis) in [("SkyX", basis.columns.0), ("SkyY", basis.columns.1), ("SkyZ", basis.columns.2)]
        where inputs.contains(key) { try graph.setParameter(name: key, value: .simd3Float(axis)) }
    }
}

/// Source tire graphs are shared by wheel packages that use the same Godot material.
/// Each scene uses the graph bank for its own panorama.
@MainActor final class ClassicTires {
    private struct Index: Decodable {
        struct Finish: Decodable { let twoSided: Bool }
        let version: Int
        let parked: Bool?
        let materials: [String: Finish]
    }

    private let index: Index
    private let directory: URL
    private var templates: [String: ShaderGraphMaterial] = [:]
    var supportsParked: Bool { index.parked == true }

    init?(fleet: URL, panorama: String) throws {
        let bank = fleet.appendingPathComponent("Wheels/ClassicTires")
        let file = bank.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: file))
        guard index.version == 1 else { throw VehicleError.invalid("Unknown Classic tire bank version") }
        let family = URL(fileURLWithPath: panorama).deletingPathExtension().lastPathComponent
        directory = bank.appendingPathComponent(family)
    }

    /// Inspect original USD slots while they are still portable PBR. This also
    /// finds the Semi's separate rear tires and wheels with an inner tire surface.
    func prepare(in wheels: [Entity]) async throws {
        var needed = Set<String>()
        func visit(_ node: Entity) {
            if let model = node.components[ModelComponent.self] {
                for material in model.materials {
                    if let name = material.name, index.materials[name] != nil { needed.insert(name) }
                }
            }
            for child in node.children { visit(child) }
        }
        for wheel in wheels { visit(wheel) }
        for name in needed.sorted() where templates[name] == nil {
            let file = directory.appendingPathComponent(name + ".usda")
            var graph = try await ShaderGraphMaterial(named: "/" + name, from: file)
            graph.faceCulling = index.materials[name]?.twoSided == true ? .none : .back
            templates[name] = graph
        }
    }

    func materials(for preset: VehicleManifest.Rig.Lighting?) throws -> [String: ShaderGraphMaterial] {
        guard let preset else { return [:] }
        return try templates.mapValues { template in
            var graph = template
            try preset.apply(to: &graph)
            return graph
        }
    }
}
