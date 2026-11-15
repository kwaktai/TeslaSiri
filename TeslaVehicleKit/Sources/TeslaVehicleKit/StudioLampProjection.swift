import Metal
import RealityKit
import simd

/// The photo renderer prints the recovered unshaded beam over the displayed
/// receiver. Straight alpha in Godot's GLES2 output is display referred.
@MainActor final class StudioLampProjection {
    struct Draw {
        let entity: Entity
        let mesh: MeshResource
        let opacity: TextureResource
        let gain: Float
    }

    static func visible(on car: VehicleScene) -> [Draw] {
        guard car.manifest.model == "bayberry" || car.manifest.model == "bayberry_e80",
              let assembly = car.node(at: "Body/Headlights_Beam"), assembly.isEnabledInHierarchy else { return [] }
        // E80 also assigns the ordinary Beam.tres to the face-on insert.
        // Bayberry's separate directional glow is a different source shader.
        return ["Body/Headlights_Beam/surface_00", "Body/Headlights_Beam/FaceOnGlow/surface_00"].compactMap { path in
            guard let e = car.node(at: path), e.isEnabledInHierarchy,
                  let model = e.components[ModelComponent.self], let p = model.materials.first as? PhysicallyBasedMaterial,
                  let name = p.name, name == "Beam_8aea1d82de4e78" || name == "Beam_adcbceed40d632",
                  case .transparent(let alpha) = p.blending, let map = alpha.texture else { return nil }
            return Draw(entity: e, mesh: model.mesh, opacity: map.resource, gain: alpha.scale)
        }
    }

    private struct Part {
        let vertices, indices: any MTLBuffer
        let count: Int
        let placement: simd_float4x4
    }
    private struct Vertex { let point: SIMD3<Float>; let uv: SIMD2<Float> }
    private let device: any MTLDevice
    private let solid, beam: any MTLRenderPipelineState
    private let writeDepth, testDepth: any MTLDepthStencilState
    private var depth: (any MTLTexture)?
    private var meshes = [ObjectIdentifier: (MeshResource, [Part])]()
    private var textures = [ObjectIdentifier: (TextureResource, any MTLTexture)]()

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        self.device = device
        let pd = MTLRenderPipelineDescriptor()
        pd.depthAttachmentPixelFormat = .depth32Float
        let color = pd.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.writeMask = []
        pd.vertexFunction = library.makeFunction(name: "beamOccluder")
        solid = try device.makeRenderPipelineState(descriptor: pd)
        color.writeMask = [.red, .green, .blue]
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.vertexFunction = library.makeFunction(name: "projectionVertex")
        pd.fragmentFunction = library.makeFunction(name: "projectionTransfer")
        beam = try device.makeRenderPipelineState(descriptor: pd)
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .lessEqual
        dd.isDepthWriteEnabled = true
        guard let wd = device.makeDepthStencilState(descriptor: dd) else { throw VehicleError.invalid("No beam depth") }
        writeDepth = wd
        dd.isDepthWriteEnabled = false
        guard let td = device.makeDepthStencilState(descriptor: dd) else { throw VehicleError.invalid("No beam receiver") }
        testDepth = td
    }

    private func alpha(_ source: TextureResource) throws -> any MTLTexture {
        let id = ObjectIdentifier(source)
        if let (_, cached) = textures[id] { return cached }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width,
                    height: source.height, mipmapped: source.mipmapLevelCount > 1)
        desc.mipmapLevelCount = source.mipmapLevelCount
        desc.storageMode = .private
        desc.usage = [.shaderRead, .pixelFormatView, .shaderWrite, .renderTarget]
        guard let result = device.makeTexture(descriptor: desc) else { throw VehicleError.invalid("Cannot allocate beam alpha") }
        try source.copy(to: result)
        textures[id] = (source, result)
        return result
    }

    private func parts(_ mesh: MeshResource) throws -> [Part] {
        let id = ObjectIdentifier(mesh)
        if let (_, cached) = meshes[id] { return cached }
        let contents = mesh.contents
        var parts = [Part]()
        for model in contents.models {
            let placements = contents.instances.filter { $0.model == model.id }.map(\.transform)
            for part in model.parts {
                guard let uv = part.textureCoordinates?.elements, let ix = part.triangleIndices?.elements else { continue }
                let pos = part.positions.elements
                guard uv.count == pos.count, !ix.isEmpty else { continue }
                let points = pos.indices.map { Vertex(point: pos[$0], uv: uv[$0]) }
                guard let vb = points.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
                      let ib = ix.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) else {
                    throw VehicleError.invalid("Cannot buffer lamp projection")
                }
                for p in placements.isEmpty ? [matrix_identity_float4x4] : placements {
                    parts.append(Part(vertices: vb, indices: ib, count: ix.count, placement: p))
                }
            }
        }
        meshes[id] = (mesh, parts)
        return parts
    }

    func print(_ draws: [Draw], onto output: any MTLTexture, camera: [SIMD4<Float>],
               shadows: StudioShadows, command: any MTLCommandBuffer) throws {
        if depth?.width != output.width || depth?.height != output.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: output.width,
                                                             height: output.height, mipmapped: false)
            d.usage = .renderTarget; d.storageMode = .private
            depth = device.makeTexture(descriptor: d)
        }
        guard let depth else { throw VehicleError.invalid("Cannot allocate lamp receiver") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.clearDepth = 1; pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { throw VehicleError.invalid("Cannot print lamp projection") }
        defer { e.endEncoding() }
        e.setRenderPipelineState(solid); e.setDepthStencilState(writeDepth); e.setCullMode(.none)
        camera.withUnsafeBytes { e.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        shadows.drawGlassOccluders(e, includeOptical: true)
        e.setRenderPipelineState(beam); e.setDepthStencilState(testDepth)
        e.setFrontFacing(.counterClockwise); e.setCullMode(.back)
        for draw in draws {
            var gain = draw.gain
            e.setFragmentBytes(&gain, length: 4, index: 0)
            e.setFragmentTexture(try alpha(draw.opacity), index: 0)
            let world = draw.entity.transformMatrix(relativeTo: nil)
            for part in try parts(draw.mesh) {
                var m = world * part.placement
                e.setVertexBuffer(part.vertices, offset: 0, index: 0)
                e.setVertexBytes(&m, length: 64, index: 1)
                e.drawIndexedPrimitives(type: .triangle, indexCount: part.count, indexType: .uint32, indexBuffer: part.indices, indexBufferOffset: 0)
            }
        }
    }
}

let lampProjectionSource = """
float4 beamClip(float3 point,constant float4x4& m,constant float4* p){
  float3 d=(m*float4(point,1.)).xyz-p[0].xyz;float z=dot(d,p[3].xyz);
  return float4(dot(d,p[1].xyz)*(2.*p[0].w/p[1].w),dot(d,p[2].xyz)*(2.*p[0].w/p[2].w),z-.035,z);
}
vertex float4 beamOccluder(uint i [[vertex_id]],const device float3* v [[buffer(0)]],constant float4x4& m [[buffer(1)]],constant float4* p [[buffer(2)]]){
 return beamClip(v[i],m,p);
}
struct ProjectionVertex{float3 point;float2 uv;};
struct ProjectionFragment{float4 position [[position]];float2 uv;};
vertex ProjectionFragment projectionVertex(uint i [[vertex_id]],const device ProjectionVertex* v [[buffer(0)]],constant float4x4& m [[buffer(1)]],constant float4* p [[buffer(2)]]){
 return {beamClip(v[i].point,m,p),float2(v[i].uv.x,1.-v[i].uv.y)};
}
fragment float4 projectionTransfer(ProjectionFragment in [[stage_in]],texture2d<float> opacity [[texture(0)]],constant float& gain [[buffer(0)]]){
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
 return float4(1.,1.,1.,gain*opacity.sample(s,in.uv).r);
}
"""
