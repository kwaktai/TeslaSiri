import CoreGraphics
import Metal
import RealityKit

/// The mobile renderer blends panes in display RGB. Render their premultiplied
/// color and coverage against transparent black with the native depth test,
/// then combine with the real vehicle/background in VehicleFrameRenderer.
@MainActor final class ClassicGlassRenderer {
    private struct Node {
        let source: Entity
        let copy: Entity
    }
    private struct Pane {
        let source: Entity
        let copy: Entity
        let slots: [Int]
        let model: ModelComponent
        var active: [Int]
    }
    private let root = Entity()
    private let camera = PerspectiveCamera()
    private let tileCamera = Entity()
    private var renderer: RealityRenderer?
    private let device: any MTLDevice
    private let transferName = "DisplayTransfer"
    private(set) var target: (any MTLTexture)?
    private var nodes: [Node] = []
    private var panes: [Pane] = []
    private var meshRevision: UInt64?
    private var generation: UInt64?
    private var clear = UnlitMaterial()
    private var occluders: [MaterialParameterTypes.FaceCulling: OcclusionMaterial] = [:]

    init(device: any MTLDevice) {
        self.device = device
        clear.blending = .transparent(opacity: 0.0)
        clear.writesDepth = false
        for cull in [MaterialParameterTypes.FaceCulling.back, .front, .none] {
            var material = OcclusionMaterial()
            material.faceCulling = cull
            occluders[cull] = material
        }
    }

    private func isPane(_ material: any Material) -> Bool {
        (material as? ShaderGraphMaterial)?.getParameter(name: transferName) != nil
    }

    /// Transparent fallbacks (including large textured lamp projections) must
    /// never write the whole triangle to depth. They stay on the native receiver.
    private func blocker(_ material: any Material) -> any Material {
        if let p = material as? PhysicallyBasedMaterial {
            if case .transparent = p.blending { return clear }
            return occluders[p.faceCulling]!
        }
        if let p = material as? UnlitMaterial {
            if case .transparent = p.blending { return clear }
            return occluders[p.faceCulling]!
        }
        if let p = material as? ShaderGraphMaterial { return occluders[p.faceCulling]! }
        return occluders[.back]!
    }

    private func rebuild(_ car: VehicleScene) throws {
        root.children.removeAll()
        nodes.removeAll(keepingCapacity: true)
        panes.removeAll(keepingCapacity: true)
        func copy(_ source: Entity, to parent: Entity) throws {
            let target = Entity()
            target.transform = source.transform
            target.isEnabled = source.isEnabled
            if let sort = source.components[ModelSortGroupComponent.self] { target.components.set(sort) }
            parent.addChild(target)
            nodes.append(Node(source: source, copy: target))
            if var model = source.components[ModelComponent.self] {
                let slots = model.materials.indices.filter { isPane(model.materials[$0]) }
                for slot in model.materials.indices {
                    if slots.contains(slot), var pane = model.materials[slot] as? ShaderGraphMaterial {
                        try pane.setParameter(name: transferName, value: .float(1))
                        model.materials[slot] = pane
                    } else {
                        model.materials[slot] = blocker(model.materials[slot])
                    }
                }
                target.components.set(model)
                if !slots.isEmpty {
                    panes.append(Pane(source: source, copy: target, slots: slots, model: model, active: slots))
                }
            }
            for child in source.children { try copy(child, to: target) }
        }
        try copy(car.entity, to: root)
    }

    func prepare(_ car: VehicleScene, epoch: UInt64) throws -> Bool {
        // Keep local meshes/parents for ordinary orbit and animation frames.
        // Swaps replace wheel roots and some custom paints replace a factory leaf.
        if generation != epoch || meshRevision != car.meshRevision {
            try rebuild(car)
            meshRevision = car.meshRevision
            generation = epoch
        }
        root.setTransformMatrix(car.entity.parent?.transformMatrix(relativeTo: nil) ?? matrix_identity_float4x4, relativeTo: nil)
        guard !panes.isEmpty else { return false }
        for pair in nodes {
            let enabled = pair.source.isEnabled
            if pair.copy.isEnabled != enabled { pair.copy.isEnabled = enabled }
            let pose = pair.source.transform
            if pair.copy.transform != pose { pair.copy.transform = pose }
        }
        // Public clients may temporarily replace a component, including for ID
        // and receiver studies. Only a currently bound source graph opts in.
        for i in panes.indices {
            let p = panes[i]
            let materials = p.source.components[ModelComponent.self]?.materials ?? []
            let active = p.slots.filter { materials.indices.contains($0) && isPane(materials[$0]) }
            if active != p.active {
                var model = p.model
                for slot in active {
                    guard var graph = materials[slot] as? ShaderGraphMaterial else { continue }
                    try graph.setParameter(name: transferName, value: .float(1))
                    model.materials[slot] = graph
                }
                for slot in p.slots where !active.contains(slot) {
                    model.materials[slot] = materials.indices.contains(slot) ? blocker(materials[slot]) : clear
                }
                p.copy.components.set(model)
                panes[i].active = active
            }
        }
        return panes.contains { !$0.active.isEmpty && $0.source.isEnabledInHierarchy }
    }

    /// Bounds in final output pixels, shared by every off-axis tile. Use the
    /// copied mesh and pose that will actually produce the optical layer.
    func projectedBounds(camera source: PerspectiveCamera, lens: StudioWheelView) -> SIMD4<UInt32> {
        let worldToCamera = source.transformMatrix(relativeTo: nil).inverse
        var rect = CGRect.null
        for pane in panes where !pane.active.isEmpty && pane.copy.isEnabledInHierarchy {
            let local = pane.copy.visualBounds(recursive: false, relativeTo: pane.copy)
            let cameraBounds = local.transformed(by: worldToCamera * pane.copy.transformMatrix(relativeTo: nil))
            // A clipped or degenerate projection can still reach the raster.
            // Sample the whole viewport when it has no conservative rectangle.
            guard let region = lens.region(for: cameraBounds) else {
                return [0, 0, UInt32(lens.width), UInt32(lens.height)]
            }
            rect = rect.union(region)
        }
        guard !rect.isNull else { return .zero }
        return [UInt32(rect.minX), UInt32(rect.minY), UInt32(rect.maxX), UInt32(rect.maxY)]
    }

    /// RealityRenderer snapshots the hierarchy at updateAndRender submission.
    /// Restore each leaf *before* the main actor yields to animation or UI.
    func submitReceiver(_ submit: () throws -> Void) rethrows {
        var leaves: [Entity] = []
        var models: [(Entity, ModelComponent)] = []
        defer {
            for leaf in leaves { leaf.isEnabled = true }
            for (node, model) in models { node.components.set(model) }
        }
        for pane in panes where !pane.active.isEmpty && pane.source.isEnabled {
            guard var model = pane.source.components[ModelComponent.self] else { continue }
            if pane.source.children.isEmpty && pane.active.count == model.materials.count {
                leaves.append(pane.source)
                pane.source.isEnabled = false
            } else {
                models.append((pane.source, model))
                for slot in pane.active { model.materials[slot] = clear }
                pane.source.components.set(model)
            }
        }
        try submit()
    }

    /// Freeze the glass lens before the receiver yields to another actor job.
    func camera(matching source: PerspectiveCamera, projection: simd_float4x4?) -> Entity {
        if let projection {
            tileCamera.transform = source.transform
            tileCamera.components.set(ProjectiveTransformCameraComponent(projectionMatrix: projection))
            return tileCamera
        }
        camera.transform = source.transform
        camera.camera = source.camera
        return camera
    }

    func expose(from lens: Entity, width: Int, height: Int) async throws {
        try Task.checkCancellation()
        if renderer == nil {
            let r = try RealityRenderer()
            r.cameraSettings.isToneMappingEnabled = false
            r.cameraSettings.antialiasing = .none
            r.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
            r.entities.append(contentsOf: [root, camera, tileCamera])
            renderer = r
        }
        if target?.width != width || target?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            target = device.makeTexture(descriptor: descriptor)
        }
        guard let renderer, let target else { throw VehicleError.invalid("Cannot create Classic glass exposure") }
        renderer.activeCamera = lens
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in c.resume() }) }
            catch { c.resume(throwing: error) }
        }
    }
}
