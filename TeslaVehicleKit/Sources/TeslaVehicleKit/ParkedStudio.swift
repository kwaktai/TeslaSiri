import Foundation
import CoreGraphics
import Metal
import RealityKit
import simd

/// Offscreen equivalent of the app's parked vehicle viewport. The image contains
/// the loaded geometry, not a sprite; the floor gets its own mirrored camera pass.
@MainActor public final class ParkedStudio {
    // Only affects native PBR trim/interior. The glass and paint graphs evaluate
    // the separate app energies and do not receive this light a second time.
    static let trimExposure: Float = 0.45
    private let renderer: RealityRenderer
    private let product: Entity
    public let camera: PerspectiveCamera
    private let device: any MTLDevice
    private let resolveQueue: any MTLCommandQueue
    private let areaResolve: any MTLComputePipelineState
    private let floorPipeline: any MTLComputePipelineState
    private let glow: SIMD3<Float>
    private let grounds: [Entity]
    private let wheels: [Entity]
    private var rendering = false
    private let mask: any MTLBuffer
    private let maskSpec: VehicleManifest.Rig.Parked.Ground?
    private let normals: any MTLBuffer
    private let normalSize: Int

    public init(scene: VehicleScene) async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { throw VehicleError.invalid("No Metal device or command queue") }
        self.device = device
        resolveQueue = queue
        let library = try await device.makeLibrary(source: parkedResolveSource, options: nil)
        guard let function = library.makeFunction(name: "parkedArea") else { throw VehicleError.invalid("No parked area resolve") }
        areaResolve = try await device.makeComputePipelineState(function: function)
        guard let floorFunction = library.makeFunction(name: "parkedFloor") else { throw VehicleError.invalid("No parked floor kernel") }
        floorPipeline = try await device.makeComputePipelineState(function: floorFunction)
        renderer = try RealityRenderer()
        camera = scene.parkedCamera()
        let product = scene.classicStillBody()
        self.product = product
        // Do not keep a receiver referencing the light in a different scene.
        product.components.remove(ImageBasedLightReceiverComponent.self)
        if let s = scene.manifest.rig.parked?.shader {
            for (name,paths) in s.bindings where scene.shouldBind(name) {
              let material = try await scene.parkedMaterial(name, file: s.file)
              for path in paths {
                var node: Entity? = product
                for name in path.split(separator: "/").dropFirst() { node = node?.children.first { $0.name == name } }
                guard let node, var model = node.components[ModelComponent.self] else { throw VehicleError.invalid("Missing studio mesh: \(path)") }
                model.materials = [material]; node.components.set(model)
              }
            }
        }
        try await scene.applyParkedWheels(to:product,remember:false)
        wheels = scene.manifest.wheelMounts.compactMap { mount in
            (mount.socket+"/"+mount.child).split(separator:"/").dropFirst().reduce(Optional(product)) { node, part in
                node?.children.first { $0.name == part }
            }
        }
        renderer.entities.append(contentsOf: [product, camera])
        renderer.activeCamera = camera
        renderer.lighting.resource = scene.parkedEnvironment ?? scene.environment
        renderer.lighting.intensityExponent = scene.parkedNativeExposure
        renderer.cameraSettings.isToneMappingEnabled = false
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0, alpha: 0))
        renderer.cameraSettings.antialiasing = .none
        let rgb = scene.parkedHighlightRGB
        glow = SIMD3(Float(rgb >> 16), Float((rgb >> 8)&255), Float(rgb&255))/255
        grounds = ["GroundPlane","Ground_Shadow2","Floor","Floor_LongRange"].compactMap { product.findEntity(named: $0) }
        maskSpec = scene.manifest.rig.parked?.ground
        // Metal requires bound buffers even when the model has no floor maps.
        func mapBuffer(_ file: String?, bytes: Int) throws -> any MTLBuffer {
            let data = try file.map { try Data(contentsOf: scene.directory.appendingPathComponent($0)) } ?? Data([0])
            guard data.count == bytes,
                  let buffer = data.withUnsafeBytes({ raw in
                      device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
                  }) else { throw VehicleError.invalid("Cannot load parked floor map") }
            return buffer
        }
        let parked = scene.manifest.rig.parked
        normalSize = parked?.normalSize ?? 0
        guard parked == nil || (1...4096).contains(normalSize) else { throw VehicleError.invalid("Invalid floor normal size") }
        normals = try mapBuffer(parked?.floorNormals, bytes: max(1, 2*normalSize*normalSize))
        if let spec = maskSpec {
            let (bytes, overflow) = spec.width.multipliedReportingOverflow(by: spec.height)
            guard spec.width > 0, spec.height > 0, !overflow, UInt32(exactly: bytes) != nil,
                  spec.bounds.count == 4, spec.uvFromXZ.count == 2, spec.uvFromXZ.allSatisfy({$0.count == 3}) else {
                throw VehicleError.invalid("Invalid contact shadow")
            }
            mask = try mapBuffer(spec.mask, bytes: bytes)
        } else {
            mask = try mapBuffer(nil, bytes: 1)
        }
        for e in grounds { e.isEnabled = false }
    }

    /// Useful when the host changes the reference exposure or uses another environment.
    public func setEnvironment(_ resource: EnvironmentResource, intensityExponent: Float) {
        renderer.lighting.resource = resource
        renderer.lighting.intensityExponent = intensityExponent
    }

    /// Resolve independently shaded points after compositing each with the authored
    /// floor. The mirror instead keeps both its display color and coverage.
    private func raster(_ rect: CGRect, tile: CGRect, region: CGRect, grid: Int, feather: Bool,
                        backdrop: (any MTLTexture)?, into output: any MTLBuffer,
                        width: Int, height: Int, advanceScene: Bool) async throws {
        let w = Int(rect.width), h = Int(rect.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w*grid, height: h*grid, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc) else { throw VehicleError.invalid("No parked sample target") }
        let cameraOutput = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))
        // Submit a zero-time update for every new projection, including wheel tiles.
        // Otherwise reflected geometry can retain visibility from the previous tile.
        for passIndex in 0..<2 {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                do { try renderer.updateAndRender(deltaTime: advanceScene && passIndex == 1 ? 1/60 : 0, cameraOutput: cameraOutput, onComplete: { _ in cont.resume() }) }
                catch { cont.resume(throwing: error) }
            }
        }
        guard let cmd = resolveQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw VehicleError.invalid("Cannot resolve parked samples")
        }
        let params: [SIMD4<UInt32>] = [
            [UInt32(grid), UInt32(rect.minX), UInt32(rect.minY), backdrop == nil ? 0 : 1],
            [UInt32(tile.minX), UInt32(tile.minY), UInt32(tile.width), UInt32(tile.height)],
            [UInt32(region.minX), UInt32(region.minY), UInt32(region.maxX), UInt32(region.maxY)],
            [UInt32(width), UInt32(height), UInt32(StudioWheelView.margin), feather ? 1 : 0]
        ]
        enc.setComputePipelineState(areaResolve)
        enc.setTexture(target, index: 0)
        enc.setTexture(backdrop ?? target, index: 1)
        params.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.setBuffer(output, offset: 0, index: 1)
        enc.dispatchThreads(.init(width: Int(tile.width), height: Int(tile.height), depth: 1),
                            threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cmd.addCompletedHandler { result in
                if let error = result.error { cont.resume(throwing: error) } else { cont.resume() }
            }
            cmd.commit()
        }
    }

    private func frame(_ w: Int, _ h: Int, backdrop: (any MTLTexture)? = nil) async throws -> any MTLBuffer {
        let storage: MTLResourceOptions = backdrop == nil ? .storageModePrivate : .storageModeShared
        guard let pixels = device.makeBuffer(length: w*h*4, options: storage) else {
            throw VehicleError.invalid("Cannot allocate parked frame")
        }
        let sampling = ClassicSampling(width: w, height: h)
        let base = sampling.grid
        let view = StudioWheelView(camera.camera, width: w, height: h)
        let regions = StudioWheelView.merged(wheels.compactMap { wheel in
            wheel.isEnabledInHierarchy ? view.region(for: wheel.visualBounds(relativeTo: camera)) : nil
        })
        let detail = StudioWheelView.detailLevel(regions, above: base >= 4 ? 2 : 1)
        let fullFrame = sampling.tiles.count == 1
        if fullFrame {
            try await raster(view.viewport, tile: view.viewport, region: view.viewport, grid: base, feather: false,
                             backdrop: backdrop, into: pixels, width: w, height: h, advanceScene: true)
            if detail == nil { return pixels }
        }
        let lens = Entity()
        lens.transform = Transform(matrix: camera.transformMatrix(relativeTo: nil))
        renderer.entities.append(lens)
        renderer.activeCamera = lens
        defer { renderer.activeCamera = camera; renderer.entities.remove(lens) }

        func tiles(_ region: CGRect, grid: Int, feather: Bool) async throws {
            // A small guard band keeps derivatives well defined across tile boundaries.
            let side = 2048/grid-4
            for y in stride(from: Int(region.minY), to: Int(region.maxY), by: side) {
                for x in stride(from: Int(region.minX), to: Int(region.maxX), by: side) {
                    let tile = CGRect(x: x, y: y, width: min(side,Int(region.maxX)-x), height: min(side,Int(region.maxY)-y))
                    let sample = tile.insetBy(dx: -2, dy: -2).intersection(view.viewport)
                    lens.components.set(ProjectiveTransformCameraComponent(projectionMatrix: view.projection(for: sample)))
                    try await raster(sample, tile: tile, region: region, grid: grid, feather: feather,
                                     backdrop: backdrop, into: pixels, width: w, height: h, advanceScene: !feather)
                }
            }
        }
        if !fullFrame { try await tiles(view.viewport, grid: base, feather: false) }
        if let detail {
            for region in regions { try await tiles(region, grid: 1 << detail, feather: true) }
        }
        return pixels
    }

    public func image(width w: Int = 1120, height h: Int = 700) async throws -> CGImage {
        guard w >= 4, h >= 4, w <= 4096, h <= 4096 else { throw VehicleError.invalid("Invalid render size") }
        guard !rendering else { throw VehicleError.invalid("A parked image is already rendering") }
        rendering = true
        defer { rendering = false }
        let original = camera.transform, enabled = grounds.map(\.isEnabled)
        defer {
            camera.transform = original
            for (e,on) in zip(grounds,enabled) { e.isEnabled = on }
        }
        let mirror: SIMD3<Float> = [1,-1,1]
        // Reflect the camera and invert the resulting screen Y, leaving the
        // source mesh winding, materials and world-space lighting untouched.
        let from = camera.position * mirror
        let forward = camera.orientation.act([0,0,-1]) * mirror
        camera.look(at: from + forward, from: from, relativeTo: nil)
        for e in grounds { e.isEnabled = false }
        let mw = w/2, mh = h/2
        let reflection = try await frame(mw,mh)
        camera.transform = original
        let backdrop = try await floorTexture(reflection: reflection, size: SIMD2(w,h), pose: original)
        let foreground = try await frame(w,h,backdrop:backdrop)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let image = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
            space:CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo:.init(rawValue:info),
            provider:CGDataProvider(data:Data(bytes: foreground.contents(), count: w*h*4) as CFData)!, decode:nil, shouldInterpolate:false, intent:.defaultIntent)
        else { throw VehicleError.invalid("Could not create parked image") }
        return image
    }

    // Matches the consecutive float4 fields in ParkedFloorUniforms.
    private struct FloorUniforms {
        var eyeAndFocal: SIMD4<Float>
        var right: SIMD4<Float>
        var up: SIMD4<Float>
        var forward: SIMD4<Float>
        var planeAxisAndDistance: SIMD4<Float>
        var planeRightAndScale: SIMD4<Float>
        var planeUp: SIMD4<Float>
        var glow: SIMD4<Float>
        var contactU: SIMD4<Float>
        var contactV: SIMD4<Float>
        var contactBounds: SIMD4<Float>
    }

    private func floorTexture(reflection: any MTLBuffer, size: SIMD2<Int>, pose: Transform) async throws -> any MTLTexture {
        let w = size.x, h = size.y
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor), let cmd = resolveQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { throw VehicleError.invalid("Cannot draw parked backdrop") }

        let toCenter = SIMD3<Float>(0, 1, 0) - pose.translation
        let distance = max(simd_length(toCenter), 0.0001)
        let axis = toCenter / distance
        let horiz = simd_cross(axis, SIMD3<Float>(0,1,0))
        let right = simd_length_squared(horiz) > 1e-10 ? simd_normalize(horiz) : SIMD3<Float>(1,0,0)
        let planeDistance = distance + 16.3
        let g = maskSpec
        let u = g?.uvFromXZ[0] ?? [0,0,0], v = g?.uvFromXZ[1] ?? [0,0,0]
        let bounds = g?.bounds ?? [0,0,0,0]
        var uniforms = FloorUniforms(
            eyeAndFocal: SIMD4(pose.translation, StudioWheelView(camera.camera, width: w, height: h).focal),
            right: SIMD4(pose.rotation.act([1,0,0]), 0), up: SIMD4(pose.rotation.act([0,1,0]), 0),
            forward: SIMD4(pose.rotation.act([0,0,-1]), 0), planeAxisAndDistance: SIMD4(axis, planeDistance),
            planeRightAndScale: SIMD4(right, (planeDistance/distance)*15.8/(15.8+16.3)),
            planeUp: SIMD4(simd_cross(right,axis), 0), glow: SIMD4(glow, 0),
            contactU: [u[0],u[1],u[2],0], contactV: [v[0],v[1],v[2],0],
            contactBounds: [bounds[0],bounds[1],bounds[2],bounds[3]]
        )
        var mapSize = SIMD4<UInt32>(UInt32(g?.width ?? 0), UInt32(g?.height ?? 0), UInt32(normalSize), 0)
        enc.setComputePipelineState(floorPipeline)
        enc.setBuffer(reflection, offset: 0, index: 0)
        enc.setBuffer(normals, offset: 0, index: 1)
        enc.setBuffer(mask, offset: 0, index: 2)
        enc.setBytes(&uniforms, length: MemoryLayout<FloorUniforms>.stride, index: 3)
        enc.setBytes(&mapSize, length: MemoryLayout.size(ofValue: mapSize), index: 4)
        enc.setTexture(texture, index: 0)
        enc.dispatchThreads(.init(width: w, height: h, depth: 1), threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
        enc.endEncoding()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in
            cmd.addCompletedHandler { b in if let error = b.error { c.resume(throwing: error) } else { c.resume() } }
            cmd.commit()
        }
        return texture
    }
}

// A RealityRenderer sRGB attachment contains linear-premultiplied color after
// hardware decode. Composite each shaded point over the floor before encoding
// and averaging. The mirror's RGB and undistorted coverage remain separate.
private let parkedResolveSource = """
#include <metal_stdlib>
using namespace metal;
float3 encodeParked(float3 x) {
    return select(1.055*pow(max(x,0.),float3(1./2.4))-.055,12.92*x,x<=.0031308);
}
float3 decodeParked(float3 x) {
    return select(pow((x+.055)/1.055,float3(2.4)),x/12.92,x<=.04045);
}
kernel void parkedArea(texture2d<float,access::read> samples [[texture(0)]],
                       texture2d<float,access::read> backdrop [[texture(1)]],
                       constant uint4* p [[buffer(0)]], device uchar4* frame [[buffer(1)]],
                       uint2 local [[thread_position_in_grid]]) {
    const uint4 layout = p[0], tile = p[1], region = p[2], frameSize = p[3];
    if (any(local >= tile.zw)) return;
    uint2 xy = tile.xy + local;
    uint grid = layout.x;
    uint2 origin = (xy - layout.yz) * grid;
    float3 backing = layout.w ? decodeParked(backdrop.read(xy).rgb) : float3(0.);
    float4 sum = 0.;
    for (uint y=0; y<grid; ++y) {
        for (uint x=0; x<grid; ++x) {
            float4 s = samples.read(origin+uint2(x,y));
            float3 rgb = s.a>0. ? s.rgb : float3(0.);
            sum += float4(encodeParked(rgb+(1.-s.a)*backing),layout.w ? 1. : s.a);
        }
    }
    uint index = xy.y * frameSize.x + xy.x;
    // Preserve the former intermediate BGRA8 quantization before feathering.
    uchar4 bytes = uchar4(rint(saturate(sum.bgra/float(grid*grid))*255.));
    if (frameSize.w) {
        uint margin = frameSize.z;
        uint2 low  = select(xy-region.xy, uint2(margin), region.xy == uint2(0));
        uint2 high = select(region.zw-1-xy, uint2(margin), region.zw == frameSize.xy);
        uint edge = min(min(low.x,low.y),min(high.x,high.y));
        if (edge == 0) return;
        if (edge < margin-1) {
            float t = float(edge)/float(margin-1);
            bytes = uchar4(round(float4(frame[index])*(1.-t)+float4(bytes)*t));
        }
    }
    frame[index] = bytes;
}

// Use the original full-precision, clamped bilinear weights. Hardware linear
// filtering rounds these weights, which is visible on sharp mirror silhouettes.
template<typename F, typename T> F parkedBilinear(const device T* data, uint2 dims, float2 coord) {
    float2 pos = clamp(coord, 0., float2(dims-1));
    uint2 lo = uint2(pos), hi = min(lo+1,dims-1);
    float2 f = pos-float2(lo);
    F top = (1.-f.x)*F(data[lo.y*dims.x+lo.x])+f.x*F(data[lo.y*dims.x+hi.x]);
    F bottom = (1.-f.x)*F(data[hi.y*dims.x+lo.x])+f.x*F(data[hi.y*dims.x+hi.x]);
    return (1.-f.y)*top+f.y*bottom;
}

struct ParkedFloorUniforms {
    float4 eyeAndFocal;
    float4 right;
    float4 up;
    float4 forward;
    float4 planeAxisAndDistance;
    float4 planeRightAndScale;
    float4 planeUp;
    float4 glow;
    float4 contactU;
    float4 contactV;
    float4 contactBounds;
};

kernel void parkedFloor(const device uchar4* mirror [[buffer(0)]],
                        const device uchar2* normals [[buffer(1)]], const device uchar* mask [[buffer(2)]],
                        constant ParkedFloorUniforms& p [[buffer(3)]], constant uint4& dims [[buffer(4)]],
                        texture2d<float,access::write> result [[texture(0)]], uint2 xy [[thread_position_in_grid]]) {
    uint2 size(result.get_width(),result.get_height());
    if (any(xy>=size)) return;
    uint2 mirrorSize=size/2;
    float2 center=float2(xy)+.5, offset=(center-float2(size)*.5)/p.eyeAndFocal.w;
    float3 ray=(p.forward.xyz-p.up.xyz*offset.y)+p.right.xyz*offset.x;
    float t=ray.y < -.00001 ? -p.eyeAndFocal.y/ray.y : -1.;
    float2 point=p.eyeAndFocal.xz+ray.xz*max(t,0.);
    float dist=length(point);
    float planeT=p.planeAxisAndDistance.w/max(.0001,dot(ray,p.planeAxisAndDistance.xyz));
    float2 ellipse=float2(dot(ray,p.planeRightAndScale.xyz)/8.2,dot(ray,p.planeUp.xyz)/4.3)*(planeT/p.planeRightAndScale.w);
    float halo=(1.-smoothstep(.5,1.,length(ellipse)))*.26*(1.-smoothstep(.6,.85,-p.forward.y));
    const float3 bg=float3(22,23,24)/255.;
    float3 floorRGB=0.;
    float fade=0.,contact=0.;
    if (t>0. && dist<15.) {
        float2 sample=center*float2(mirrorSize)/float2(size)-.5;
        sample.y=float(mirrorSize.y)-1.-sample.y;
        float4 undistorted=parkedBilinear<float4>(mirror,mirrorSize,sample)/255.;
        float3 reflected=undistorted.bgr;
        if (dims.z) {
            uint2 at=min(uint2(fract(point/6.+.5)*float(dims.z)),uint2(dims.z-1));
            float2 noise=float2(normals[at.y*dims.z+at.x])/127.5-1.;
            reflected=parkedBilinear<float4>(mirror,mirrorSize,sample+noise*float2(7.5,-7.5)).bgr/255.;
        }
        floorRGB=bg*(1.-.4*undistorted.a)+.10*reflected+.03*undistorted.a;
        fade=1.-smoothstep(5.,15.,dist);
        if (dims.x && all(point>=p.contactBounds.xy) && all(point<=p.contactBounds.zw)) {
            float2 uv=float2(dot(p.contactU.xy,point)+p.contactU.z,dot(p.contactV.xy,point)+p.contactV.z);
            if (all(uv>=0.) && all(uv<1.)) contact=parkedBilinear<float>(mask,dims.xy,uv*float2(dims.xy)-.5)/255.;
        }
    }
    float weight=fade*(1.-halo);
    float3 viewport=(floorRGB*weight+p.glow.xyz*halo)*(1.-contact);
    float coverage=(weight+halo)*(1.-contact)+contact;
    result.write(float4(round(saturate(viewport*coverage+bg*(1.-coverage))*255.)/255.,1.),xy);
}
"""
