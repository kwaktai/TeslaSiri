import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore
import RealityKit
import simd

@_spi(Verification) public enum WindowStudy:Int32 {case photograph,transmission,reflection,receiver}

/// Reusable GPU viewport. No cloning, PNG generation or CPU pixel readback
/// on the interactive path. Use one renderer per displayed experience.
@MainActor public final class VehicleFrameRenderer {
    public let device: any MTLDevice
    private let queue:any MTLCommandQueue
    private let pipeline:any MTLRenderPipelineState
    private let fieldPipeline:any MTLRenderPipelineState
    private let classicPipeline: any MTLRenderPipelineState
    private let emptySky:any MTLTexture
    private var field:LowLevelTexture?,fieldResource:TextureResource?
    private let renderer:RealityRenderer
    private let taking=PerspectiveCamera()
    private let tileCamera = Entity()
    private let mirror=PerspectiveCamera()
    private var studioBeam:StudioLampProjection?
    private let studioLibrary:any MTLLibrary
    private var studioShadows:StudioShadows?
    private var classicGlass: ClassicGlassRenderer?
    private var studioGlazing:StudioGlazing?
    private var coach:Coachwork?
    private(set) var radiance:StudioRadiance?
    private var previousRadiance:StudioRadiance?
    @_spi(Verification) public var portableRays=false
    @_spi(Verification) public var reflectVehicle=true
    @_spi(Verification) public var inspectRays=false
    @_spi(Verification) public var rayBackend:String{coach.map{$0.native ? "Metal intersector":"Metal software BVH"} ?? "inactive"}
    @_spi(Verification) public var rayTriangles:Int{coach?.geometry.triangles ?? 0}
    @_spi(Verification) public func rayEvents()->[UInt8]{
        guard !drawing,let t=coach?.events else{return []}
        var v=[UInt8](repeating:0,count:t.width*t.height);v.withUnsafeMutableBytes{t.getBytes($0.baseAddress!,bytesPerRow:t.width,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0)};return v
    }
    private let experience:VehicleExperience
    var currentLook: VehicleLook { experience.look }
    private var front:(any MTLTexture)?, reflected:(any MTLTexture)?,mirrorPass:(any MTLTexture)?
    private var mask:(any MTLTexture)?, normal:(any MTLTexture)?
    private var shadowRevision:UInt64?
    private weak var configured:VehicleScene?
    private var ground:Entity?, originalGround=true
    private var drawing=false
    private var drawQueue=[CheckedContinuation<Void,Never>]()
    private var lastView:String?
    private var lastLook:VehicleLook?
    private var lastCameraEpoch:UInt64?
    private var lastLightingRevision:UInt64?
    private var lastPhotoForward:SIMD3<Float>?
    @_spi(Verification) public var studioVisibilityEnabled=true
    @_spi(Verification) public var windowStudy:WindowStudy = .photograph
    /// Incident-light adjustment used by the most recently completed frame.
    @_spi(Verification) public private(set) var appliedViewMeterEV: Float = 0
    /// A camera control, in stops. Never re-lights a material or the room.
    public var exposureCompensation:Float=0

    public init(_ experience:VehicleExperience) throws {
        guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else {throw VehicleError.invalid("A Metal GPU is required")}
        device=d;queue=q;self.experience=experience
        let sd=MTLTextureDescriptor();sd.textureType = .type2DArray;sd.pixelFormat = .rgba16Float;sd.width=1;sd.height=1;sd.arrayLength=6;sd.usage = .shaderRead
        guard let empty=d.makeTexture(descriptor:sd) else{throw VehicleError.invalid("Cannot bind studio sky")};emptySky=empty
        let library=try d.makeLibrary(source:vehicleCompositeSource,options:nil);studioLibrary=library
        let pipe=MTLRenderPipelineDescriptor()
        pipe.vertexFunction=library.makeFunction(name:"triangle")
        pipe.fragmentFunction=library.makeFunction(name:"composite")
        pipe.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline=try d.makeRenderPipelineState(descriptor:pipe)
        pipe.fragmentFunction=library.makeFunction(name:"resolveClassic")
        classicPipeline=try d.makeRenderPipelineState(descriptor:pipe)
        pipe.fragmentFunction=library.makeFunction(name:"groundLightField")
        pipe.colorAttachments[0].pixelFormat = .rgba16Float
        fieldPipeline=try d.makeRenderPipelineState(descriptor:pipe)
        renderer=try RealityRenderer()
        renderer.cameraSettings.isToneMappingEnabled=false
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.colorBackground = .color(CGColor(gray:0,alpha:0))
        renderer.entities.append(contentsOf:[experience.root,taking,mirror,tileCamera])
    }
    public func makeOutput(width:Int,height:Int) throws -> any MTLTexture {
        guard width>=4,height>=4,width<=4096,height<=4096 else {throw VehicleError.invalid("Invalid viewport size")}
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        d.usage=[.renderTarget,.shaderRead];d.storageMode = .shared
        guard let t=device.makeTexture(descriptor:d) else {throw VehicleError.invalid("No output texture")};return t
    }
    private func target(_ w:Int,_ h:Int,hdr:Bool=false,mips:Bool=false)throws->any MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:hdr ? .rgba16Float:.bgra8Unorm_srgb,width:w,height:h,mipmapped:mips)
        d.usage=hdr ? [.renderTarget,.shaderRead,.shaderWrite]:[.renderTarget,.shaderRead];d.storageMode = .private
        guard let t=device.makeTexture(descriptor:d) else {throw VehicleError.invalid("No vehicle render target")};return t
    }
    private func map(_ file:URL?,_ w:Int,_ h:Int,_ channels:Int)throws->any MTLTexture {
        guard (1...4096).contains(w),(1...4096).contains(h) else {throw VehicleError.invalid("Invalid floor dimensions")}
        let bytes=try file.map {try Data(contentsOf:$0)} ?? Data(repeating:0,count:w*h*channels)
        guard bytes.count==w*h*channels else {throw VehicleError.invalid("Incomplete floor map")}
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:channels==1 ? .r8Unorm : .rg8Unorm,width:w,height:h,mipmapped:false)
        d.storageMode = .shared;d.usage = .shaderRead
        guard let t=device.makeTexture(descriptor:d) else {throw VehicleError.invalid("No floor texture")}
        bytes.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*channels) };return t
    }
    private func capture(_ camera:Entity,_ texture:any MTLTexture,_ delta:TimeInterval, excluding glass: ClassicGlassRenderer? = nil) async throws {
        renderer.activeCamera=camera
        let output=try RealityRenderer.CameraOutput(.singleProjection(colorTexture:texture))
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            do {
                let submit = { try self.renderer.updateAndRender(deltaTime:delta,cameraOutput:output,onComplete:{_ in c.resume()}) }
                if let glass { try glass.submitReceiver(submit) } else { try submit() }
            }
            catch {c.resume(throwing:error)}
        }
    }
    /// Reflect the full sensor basis, including roll. Flipping the sensor's
    /// Y keeps the basis right-handed; the composite undoes that one UV flip.
    static func mirrorPose(position:SIMD3<Float>,orientation q:simd_quatf)->Transform {
        let s:SIMD3<Float>=[1,-1,1]
        let basis=simd_float3x3(columns:(s*q.act([1,0,0]),(-s)*q.act([0,1,0]),s*q.act([0,0,1])))
        return Transform(rotation:simd_quatf(basis),translation:s*position)
    }
    private func makeField()throws{
        let f=try LowLevelTexture(descriptor:.init(pixelFormat:.rgba16Float,width:1024,height:1024,mipmapLevelCount:11,textureUsage:[.shaderRead,.renderTarget]))
        fieldResource=try TextureResource(from:f);field=f
    }
    private func selectRadiance(at directory:URL)throws {
        guard radiance?.directory != directory else{return}
        let next:StudioRadiance
        if let previousRadiance,previousRadiance.directory==directory{next=previousRadiance}
        else{next=try StudioRadiance(device:device,directory:directory)}
        previousRadiance=radiance;radiance=next
    }
    private func updateField(_ params:[SIMD4<Float>],car:VehicleScene,lamp:PhotographicLight)async throws{
        if field==nil{try makeField()}
        if studioShadows==nil{studioShadows=try StudioShadows(device:device,library:studioLibrary)}
        guard let cmd=queue.makeCommandBuffer(),let field,let studioShadows else{throw VehicleError.invalid("Cannot draw ground light field")}
        try studioShadows.encode(car:car,light:lamp,command:cmd)
        guard let coach,let radiance else{throw VehicleError.invalid("Missing studio room")}
        try coach.geometry.update(car,cmd,native:coach.native)
        try studioShadows.integrateSky(radiance.room,command:cmd)
        let t=field.replace(using:cmd),pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=t;pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
        guard let enc=cmd.makeRenderCommandEncoder(descriptor:pass) else{throw VehicleError.invalid("Cannot encode reflected light")}
        enc.setRenderPipelineState(fieldPipeline)
        enc.setFragmentTexture(studioShadows.atlas,index:0)
        enc.setFragmentTexture(studioShadows.skyIntegral,index:1)
        var fieldParams=params
        let box=studioShadows.floorBounds
        fieldParams[7]=[box.min.x,box.min.z,box.max.x,box.max.z]
        lamp.meter.samples.withUnsafeBytes{enc.setFragmentBytes($0.baseAddress!,length:$0.count,index:1)}
        fieldParams.withUnsafeBytes{enc.setFragmentBytes($0.baseAddress!,length:$0.count,index:0)}
        enc.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);enc.endEncoding()
        guard let blit=cmd.makeBlitCommandEncoder() else{throw VehicleError.invalid("Cannot filter reflected light")}
        blit.generateMipmaps(for:t);blit.endEncoding()
        try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in
            cmd.addCompletedHandler{b in if let e=b.error{c.resume(throwing:e)}else{c.resume()}};cmd.commit()
        }
    }
    public func draw(into output:any MTLTexture,present drawable:(any MTLDrawable)?=nil) async throws {
        try await draw(into: output, present: drawable, expectedLook: nil)
    }
    func draw(into output: any MTLTexture, present drawable: (any MTLDrawable)?, expectedLook: VehicleLook?) async throws {
        let w=output.width,h=output.height
        if drawing{await withCheckedContinuation{drawQueue.append($0)}}else{drawing=true}
        defer{renderer.activeCamera=experience.camera;if drawQueue.isEmpty{drawing=false}else{drawQueue.removeFirst().resume()}}
        try Task.checkCancellation()
        if let expectedLook, expectedLook != experience.look { throw CancellationError() }
        guard let car=experience.car,output.pixelFormat == .bgra8Unorm,(4...4096).contains(w),(4...4096).contains(h) else {throw VehicleError.invalid("Invalid vehicle frame")}
        experience.resize(aspect:Float(w)/Float(h))
        let view=experience.view,epoch=experience.cameraEpoch
        let home=view==VehicleExperience.home, settings=car.manifest.rig.parked,g=settings?.ground
        let look=experience.look,photo=look == .northlight,revision=experience.geometryRevision
        let interactionRevision=experience.revision
        let lightingRevision=photo ? car.photo?.lightingRevision:nil
        func validateShot()throws{
            guard experience.car===car,experience.look==look,experience.cameraEpoch==epoch,
                  (photo || experience.revision == interactionRevision),
                  !photo || (car.photoActive && car.photo?.lightingRevision==lightingRevision)
            else{throw CancellationError()}
        }
        let fresh=configured !== car
        if fresh {
            ground?.isEnabled=originalGround
            mask=try map(g.map{car.directory.appendingPathComponent($0.mask)},g?.width ?? 1,g?.height ?? 1,1)
            normal=try map(settings.map{car.directory.appendingPathComponent($0.floorNormals)},settings?.normalSize ?? 1,settings?.normalSize ?? 1,2)
            ground=g?.path.flatMap{car.node(at:$0)} ?? ["GroundPlane","Ground_Shadow2","Floor","Floor_LongRange"].compactMap{car.body.findEntity(named:$0)}.first
            originalGround=ground?.isEnabled ?? true;configured=car
            shadowRevision=nil;coach=nil;studioBeam=nil;classicGlass=nil
        }
        // RealityKit's portable PBR import can draw the entire shadow quad
        // in a dark snapshot. Composite its actual authored mask in all views.
        ground?.isEnabled = false
        defer {ground?.isEnabled=originalGround}
        renderer.cameraSettings.antialiasing = photo ? .multisample4X : .none
        if photo && (front?.width != w || front?.height != h || front?.pixelFormat != .rgba16Float) {
            front=try target(w,h,hdr:true);reflected=try target(max(2,w/2),max(2,h/2),hdr:true,mips:true)
            mirrorPass=try target(max(2,w/2),max(2,h/2),hdr:true,mips:true)
        }
        // Hold one lens across asynchronous front, mirror and shadow passes.
        taking.transform=experience.camera.transform;taking.camera=experience.camera.camera
        let camera=taking,eye=camera.position,rot=camera.orientation
        let fwd=rot.act([0,0,-1]),right=rot.act([1,0,0]),up=rot.act([0,1,0])
        let f=StudioWheelView(camera.camera,width:w,height:h).focal
        renderer.lighting.resource=photo ? car.photographicEnvironment : (home ? car.parkedEnvironment : car.environment)
        let rig=car.manifest.rig
        let preset=rig.presets[view] ?? rig.presets[rig.defaultView]
        renderer.lighting.intensityExponent=photo ? 0 : (home ? car.parkedNativeExposure : log2(max(0.001,(preset?.ambientEnergy ?? 1)*(preset?.skyEnergy ?? 1))))
        // SwiftUI can coalesce Charging → Cabin → Charging into one draw.
        // The name matches, but RealityKit must still settle visibility and
        // native shadow state before exposing the caliper through the spokes.
        let switching=fresh || lastView != view || lastLook != look || (photo && (lastCameraEpoch != epoch || lastLightingRevision != lightingRevision))
        // A single orbit jump can take the previous optical axis outside the
        // new lens. Give native visibility a zero-time update at the front and
        // reflected cameras without recomputing any world-space illumination.
        let halfFOV=camera.camera.fieldOfViewInDegrees * .pi/360
        let jumped=photo && (lastPhotoForward.map{simd_dot($0,fwd)<cos(halfFOV)} ?? false)
        let settleNative=switching || jumped
        if photo{
            guard let rig=car.photo,let source=rig.source else{throw VehicleError.invalid("Missing studio illumination")}
            let hardware=Coachwork.nativeAvailable(device) && !portableRays
            if coach?.native != hardware{coach=try Coachwork(device,dir:rig.studioDirectory,native:hardware);shadowRevision=nil}
            try selectRadiance(at:source.directory)
        }
        let needsField=photo && (switching || shadowRevision != revision)
        try validateShot()
        let rgb=car.parkedHighlightRGB
        let us=g?.uvFromXZ.first ?? [0,0,0],vs=g?.uvFromXZ.last ?? [0,0,0],bounds=g?.bounds ?? [0,0,0,0]
        guard us.count==3,vs.count==3,bounds.count==4 else {throw VehicleError.invalid("Invalid ground transform")}
        var params:[SIMD4<Float>]=[SIMD4(eye,f),SIMD4(right,Float(w)),SIMD4(up,Float(h)),SIMD4(fwd,(home || photo) ? 1:0),
            SIMD4(Float(rgb>>16),Float((rgb>>8)&255),Float(rgb&255),settings==nil ? 0:1),
            [us[0],us[1],us[2],photo ? 1:0],[vs[0],vs[1],vs[2],studioVisibilityEnabled ? 1:0],[bounds[0],bounds[1],bounds[2],bounds[3]]]
        var viewMeterEV: Float = 0
        if photo {
            guard let lamp=car.photographicLamp else{throw VehicleError.invalid("Missing photographic key")}
            let sky=lamp.meter.roomHorizontal
            viewMeterEV = lamp.viewExposure(eye: eye)
            let stops = exposureCompensation + viewMeterEV
            params[4]=SIMD4(exp2(min(8,max(-8,stops))),sky.x,sky.y,sky.z)
            params += [lamp.shadowRegion]+lamp.vectors
            if needsField{
                try await updateField(params,car:car,lamp:lamp)
                try validateShot()
                try car.attachGround(fieldResource!);shadowRevision=revision
            }
        }
        if !photo {
            var glass: ClassicGlassRenderer?
            if !home && car.hasClassicDisplayGlass {
                let candidate = classicGlass ?? ClassicGlassRenderer(device: device)
                classicGlass = candidate
                if try candidate.prepare(car, epoch: epoch) { glass = candidate }
            }
            try await drawClassic(into: output, present: drawable, home: home, glass: glass,
                                  settle: settleNative, params: params, validate: validateShot)
            lastView=view;lastLook=look;lastCameraEpoch=epoch;lastLightingRevision=nil
            lastPhotoForward=nil;appliedViewMeterEV=0
            return
        }
        classicGlass = nil
        let kit=car.photo?.glazing
        let panes=kit != nil ? car.photo!.mountedPanes():[]
        let projections = StudioLampProjection.visible(on: car)
        for draw in projections { draw.entity.isEnabled = false }
        defer { for draw in projections { draw.entity.isEnabled = true } }
        let backs=Set(panes.compactMap(\.back).filter(\.isEnabledInHierarchy).map(ObjectIdentifier.init))
        // The receiver is exposed without optical sheets. Their parent controls
        // still supply the exact posed matrices; restore native draws on all exits.
        for pane in panes{pane.front.isEnabled=false}
        defer{for pane in panes{pane.front.isEnabled=true}}
        do {
            let coatRig = car.photo
            coatRig?.beginCoatReceiver()
            defer { coatRig?.endCoatReceiver() }
            if settleNative {
                try await capture(camera,front!,0)
            }
            try await capture(camera,front!,1/60)
            for draw in projections { draw.entity.isEnabled = true }
            mirror.camera=camera.camera
            mirror.transform=Self.mirrorPose(position:eye,orientation:rot)
            // Let overlapping seat fittings settle before exposing the mirror.
            if settleNative || needsField {try await capture(mirror,reflected!,0)}
            try await capture(mirror,reflected!,0)
        }
        try validateShot()
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
        pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
        guard let cmd=queue.makeCommandBuffer() else{throw VehicleError.invalid("No compositor")}
        let m=mirror.orientation,mw=reflected!.width,mh=reflected!.height
        var mp=params
        mp[0]=SIMD4(mirror.position,StudioWheelView(mirror.camera,width:mw,height:mh).focal)
        mp[1]=SIMD4(m.act([1,0,0]),Float(mw));mp[2]=SIMD4(m.act([0,1,0]),Float(mh));mp[3]=SIMD4(m.act([0,0,-1]),1)
        if photo,let coach,let radiance,let shadow=studioShadows,let lamp=car.photographicLamp,let field=field?.read(){
            let frontRelief=try shadow.surfaceRelief(params:params,slot:0,room:radiance.room,lamp:lamp,command:cmd)
            _=try coach.expose(front!,slot:0,params:params,car:car,relief:frontRelief,field:field,radiance:radiance,local:reflectVehicle,record:inspectRays,cmd:cmd)
            let mirrorRelief=try shadow.surfaceRelief(params:mp,slot:1,room:radiance.room,lamp:lamp,command:cmd)
            _=try coach.expose(reflected!,slot:1,params:mp,car:car,relief:mirrorRelief,field:field,radiance:radiance,local:reflectVehicle,record:inspectRays,cmd:cmd)
        }
        var transfer:StudioGlazing.Transfer?
        if let kit,let radiance,!panes.isEmpty,let shadow=studioShadows,let f=field?.read(){
            if studioGlazing==nil{studioGlazing=try StudioGlazing(device,studioLibrary)}
            transfer=try studioGlazing!.glass(kit:kit,radiance:radiance,panes:panes,backEnabled:backs,params:params,slot:0,shadow:shadow,field:f,command:cmd)
            if let bounce=try studioGlazing!.glass(kit:kit,radiance:radiance,panes:panes,backEnabled:backs,params:mp,slot:1,shadow:shadow,field:f,command:cmd){
                try studioGlazing!.mirrorTransmission(bounce,car:reflected!,into:mirrorPass!,command:cmd);params[8].w=1
                try studioGlazing!.applyMirror(bounce,to:reflected!,command:cmd)
            }
        }
        if photo{
            guard let blit=cmd.makeBlitCommandEncoder() else{throw VehicleError.invalid("Cannot prefilter mirror")}
            blit.generateMipmaps(for:reflected!);if params[8].w>0,let mirrorPass{blit.generateMipmaps(for:mirrorPass)};blit.endEncoding()
        }
        guard let enc=cmd.makeRenderCommandEncoder(descriptor:pass) else{throw VehicleError.invalid("Cannot encode photograph")}
        enc.setRenderPipelineState(pipeline)
        for (i,t) in [front,reflected,mask,normal,photo ? field?.read():mask].enumerated(){enc.setFragmentTexture(t,index:i)}
        enc.setFragmentTexture(transfer?.light ?? mask,index:6);enc.setFragmentTexture(transfer?.pass ?? mask,index:7)
        enc.setFragmentTexture(mirrorPass ?? mask,index:8)
        if photo,let radiance,let meter=car.photographicLamp?.meter{
            enc.setFragmentTexture(radiance.room,index:10)
            meter.samples.withUnsafeBytes{enc.setFragmentBytes($0.baseAddress!,length:$0.count,index:3)}
        }else{enc.setFragmentTexture(emptySky,index:10);[SIMD4<Float>](repeating:.zero,count:32).withUnsafeBytes{enc.setFragmentBytes($0.baseAddress!,length:$0.count,index:3)}}
        var region=transfer?.region ?? .zero;enc.setFragmentBytes(&region,length:16,index:1)
        var study=windowStudy.rawValue;enc.setFragmentBytes(&study,length:4,index:2)
        params.withUnsafeBytes{ enc.setFragmentBytes($0.baseAddress!,length:$0.count,index:0) }
        enc.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);enc.endEncoding()
        // Preserve the optical subject coverage in the HDR verification target.
        // This is after the print: the room behind transparent panes was still RGB.
        if let transfer{try studioGlazing!.applyMirror(transfer,to:front!,command:cmd)}
        if !projections.isEmpty, windowStudy == .photograph, let shadow=studioShadows {
            if studioBeam == nil {studioBeam=try StudioLampProjection(device:device,library:studioLibrary)}
            try studioBeam!.print(projections,onto:output,camera:params,shadows:shadow,command:cmd)
        }
        if let drawable {cmd.present(drawable)}
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            cmd.addCompletedHandler{ b in if let e=b.error{c.resume(throwing:e)}else{c.resume()} };cmd.commit()
        }
        appliedViewMeterEV = viewMeterEV
        lastView=view;lastLook=look;lastCameraEpoch=epoch;lastLightingRevision=lightingRevision
        lastPhotoForward=photo ? fwd:nil
    }
}

extension VehicleFrameRenderer {
    private func drawClassic(into output: any MTLTexture, present drawable: (any MTLDrawable)?, home: Bool,
                             glass: ClassicGlassRenderer?, settle: Bool, params: [SIMD4<Float>],
                             validate: () throws -> Void) async throws {
        let width = output.width, height = output.height
        let sampling = ClassicSampling(width: width, height: height)
        let rasterWidth = sampling.tileWidth * sampling.grid
        let rasterHeight = sampling.tileHeight * sampling.grid
        if front?.width != rasterWidth || front?.height != rasterHeight || front?.pixelFormat != .bgra8Unorm_srgb {
            front = try target(rasterWidth, rasterHeight)
        }
        guard let front, let mask, let normal else { throw VehicleError.invalid("Missing Classic render targets") }
        mirrorPass = nil
        if home {
            // The reflected car only contributes to the soft floor. Preserve the
            // original distortion footprint when increasing its sampling density.
            let factor = min(1, 2048 / Float(max(width, height)))
            let mw = max(2, Int(Float(width)*factor)), mh = max(2, Int(Float(height)*factor))
            if reflected?.width != mw || reflected?.height != mh || reflected?.pixelFormat != .bgra8Unorm_srgb {
                reflected = try target(mw, mh)
            }
            let eye = taking.position, forward = taking.orientation.act([0, 0, -1]), flip: SIMD3<Float> = [1, -1, 1]
            mirror.camera = taking.camera
            mirror.look(at: (eye + forward)*flip, from: eye*flip, relativeTo: nil)
            if settle { try await capture(mirror, reflected!, 0) }
            try await capture(mirror, reflected!, 0)
            try validate()
        } else {
            reflected = nil
        }

        let lens = StudioWheelView(taking.camera, width: width, height: height)
        var paneBounds = glass?.projectedBounds(camera: taking, lens: lens) ?? .zero
        for (index, tile) in sampling.tiles.enumerated() {
            let projection = sampling.tiles.count > 1 ? lens.projection(for: tile) : nil
            let active: Entity
            if let projection {
                tileCamera.transform = taking.transform
                tileCamera.components.set(ProjectiveTransformCameraComponent(projectionMatrix: projection))
                active = tileCamera
            } else {
                active = taking
            }
            if settle && index == 0 {
                try await capture(active, front, 0, excluding: glass)
                try validate()
            }
            let delta: TimeInterval = index == 0 ? 1/60 : 0
            let layer: (any MTLTexture)?
            if let glass {
                // Each renderer owns its camera, scene and target. Join both
                // captures before resolving or allowing the next shot to reuse them.
                let lens = glass.camera(matching: taking, projection: projection)
                async let exposure: Void = glass.expose(from: lens, width: rasterWidth, height: rasterHeight)
                try await capture(active, front, delta, excluding: glass)
                try validate()
                try Task.checkCancellation()
                try await exposure
                layer = glass.target
            } else {
                try await capture(active, front, delta)
                layer = nil
            }
            try Task.checkCancellation()
            try validate()

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = index == 0 ? .dontCare : .load
            pass.colorAttachments[0].storeAction = .store
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw VehicleError.invalid("Cannot resolve Classic samples")
            }
            let area = tile.intersection(lens.viewport)
            encoder.setScissorRect(MTLScissorRect(x: Int(area.minX), y: Int(area.minY), width: Int(area.width), height: Int(area.height)))
            encoder.setRenderPipelineState(classicPipeline)
            encoder.setFragmentTexture(front, index: 0)
            encoder.setFragmentTexture(reflected ?? mask, index: 1)
            encoder.setFragmentTexture(mask, index: 2)
            encoder.setFragmentTexture(normal, index: 3)
            encoder.setFragmentTexture(layer ?? mask, index: 4)
            var sample = SIMD4<UInt32>(UInt32(tile.minX), UInt32(tile.minY), UInt32(sampling.grid), layer != nil ? 1 : 0)
            encoder.setFragmentBytes(&sample, length: MemoryLayout.size(ofValue: sample), index: 1)
            encoder.setFragmentBytes(&paneBounds, length: MemoryLayout.size(ofValue: paneBounds), index: 2)
            params.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            if index + 1 == sampling.tiles.count, let drawable { command.present(drawable) }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                command.addCompletedHandler { buffer in
                    if let error = buffer.error { c.resume(throwing: error) } else { c.resume() }
                }
                command.commit()
            }
            try Task.checkCancellation()
            try validate()
        }
    }
}

extension VehicleFrameRenderer {
    /// Offline checker only. Inspect native object alpha *before* adding any
    /// floor, backdrop or shadow. No instrumented pass or readback in the app.
    private func readPhotoTargets(_ mirror:Bool) async throws -> [(any MTLBuffer,Int,Int,Int)] {
        guard !drawing,lastLook == .northlight,let front,let reflected,
              let cmd=queue.makeCommandBuffer(),let blit=cmd.makeBlitCommandEncoder() else {throw VehicleError.invalid("No finished photographic frame")}
        var copies=[(any MTLBuffer,Int,Int,Int)]()
        for t in mirror ? [front,reflected]:[front] {
            let w=t.width,h=t.height,row=((w*8+255)/256)*256
            guard let bytes=device.makeBuffer(length:row*h,options:.storageModeShared) else {throw VehicleError.invalid("No diagnostic readback")}
            blit.copy(from:t,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:w,height:h,depth:1),to:bytes,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:row*h)
            copies.append((bytes,w,h,row))
        }
        blit.endEncoding()
        try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in
            cmd.addCompletedHandler{b in if let e=b.error{c.resume(throwing:e)}else{c.resume()}};cmd.commit()
        }
        return copies
    }
    @_spi(Verification) public func opaqueSubject() async throws -> [UInt8] {
        let (bytes,w,h,row)=try await readPhotoTargets(false)[0]
        let px=bytes.contents().assumingMemoryBound(to:UInt16.self)
        return (0..<(w*h)).map{i in px[(i/w)*(row/2)+(i%w)*4+3]>=0x3bfb ? 255:0}
    }
    @_spi(Verification) public func photographicCoverage() async throws -> [[Int]] {
        try await readPhotoTargets(true).map{bytes,w,h,row in
            let px=bytes.contents().assumingMemoryBound(to:UInt16.self)
            var count=0,left=w,top=h,right = -1,bottom = -1
            for y in 0..<h {for x in 0..<w where px[y*(row/2)+x*4+3]>=0x3800 { // binary16 alpha >= 0.5
                count+=1;left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
            }}
            return [w,h,count,left,top,right,bottom]
        }
    }
}

let vehicleCompositeSource = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; };
vertex V triangle(uint i [[vertex_id]]) { return {float4(i==1?3.f:-1.f,i==2?3.f:-1.f,0,1)}; }
float3 enc(float3 x){return select(1.055*pow(max(0.f,x),float3(1./2.4))-.055,12.92*x,x<=.0031308);}
float3 lin(float3 x){return select(pow((x+.055)/1.055,float3(2.4)),x/12.92,x<=.04045);}
\(northlightSetSource)
\(studioShadowSource)
\(windowSource)
\(lampProjectionSource)
fragment float4 composite(V v [[stage_in]],texture2d<float> front [[texture(0)]],texture2d<float> mirror [[texture(1)]],
 texture2d<float> mask [[texture(2)]],texture2d<float> normal [[texture(3)]],texture2d<float> field [[texture(4)]],
 texture2d<float> light [[texture(6)]],texture2d<float> through [[texture(7)]],texture2d<float> passMap [[texture(8)]],
 texture2d_array<float> sky [[texture(10)]],constant float4* p [[buffer(0)]],constant float4& region [[buffer(1)]],constant int& study [[buffer(2)]],constant float4* lamps [[buffer(3)]]){
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 size=float2(p[1].w,p[2].w),uv=v.pos.xy/size;
 float4 obj=front.sample(s,uv);
  float3 ray=p[3].xyz+p[1].xyz*(v.pos.x-size.x*.5)/p[0].w+p[2].xyz*(size.y*.5-v.pos.y)/p[0].w;
  float3 r=0.,t=1.;float2 q=v.pos.xy-region.xy;
  if(all(q>=0.)&&all(q<region.zw)){
    float4 local=light.sample(s,q/region.zw);r=local.rgb;t=through.sample(s,q/region.zw).rgb;
  }
  if(study==1)return float4(t,1.);
  if(study==2)return float4(enc(printFilm(r)),1.);
  if(study==3){r=0.;t=1.;}
  return photograph(uv,ray,obj,mirror,passMap,field,s,p,r,t,sky,lamps);
}
float3 classicBacking(float2 position,texture2d<float> mirror,texture2d<float> mask,texture2d<float> normal,constant float4* p){
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 constexpr sampler rep(coord::normalized,address::repeat,filter::nearest);
 float2 size=float2(p[1].w,p[2].w),uv=position/size;
 float3 bg=float3(22,23,24)/255, color=bg;
 if(p[3].w>.5 && p[4].w>.5){
  float3 eye=p[0].xyz, fwd=p[3].xyz;
  float3 ray=fwd+p[1].xyz*(position.x-size.x*.5)/p[0].w+p[2].xyz*(size.y*.5-position.y)/p[0].w;
  float3 delta=float3(0,1,0)-eye;float dist=length(delta);float3 axis=normalize(delta);
  float3 rx=cross(axis,float3(0,1,0));rx=length(rx)>.0001?normalize(rx):float3(1,0,0);float3 ry=cross(rx,axis);
  float planeD=dist+16.3,scale=(planeD/max(dist,.0001))*15.8/(15.8+16.3);
  float2 e=float2(dot(ray,rx)/8.2,dot(ray,ry)/4.3)*(planeD/max(.0001,dot(ray,axis))/scale);
  float halo=(1-smoothstep(.5,1.,length(e)))*.26*(1-smoothstep(.6,.85,-fwd.y));
  float fade=0,contact=0;float3 floor=0;
  if(ray.y<-.00001){float t=-eye.y/ray.y;float2 xz=(eye+ray*t).xz;float d=length(xz);
   if(t>0 && d<15){float2 ruv=float2(uv.x,1-uv.y);float a=mirror.sample(s,ruv).a;
    float2 noise=(2*normal.sample(rep,xz/6+.5).rg-1)*float2(7.5,-7.5)/max(float2(2),metal::floor(size*.5));
    floor=bg*(1-.4*a)+.1*enc(mirror.sample(s,ruv+noise).rgb)+.03*a;fade=1-smoothstep(5.,15.,d);
    float2 muv=float2(dot(p[5].xyz,float3(xz,1)),dot(p[6].xyz,float3(xz,1)));
    if(all(xz>=p[7].xy)&&all(xz<=p[7].zw)&&all(muv>=0)&&all(muv<=1))contact=mask.sample(s,muv).r;
   }}
  float fw=fade*(1-halo),coverage=(fw+halo)*(1-contact)+contact;
  color=(floor*fw+p[4].rgb*halo/255)*(1-contact)*coverage+bg*(1-coverage);
 }else if(p[4].w>.5){
  float3 ray=p[3].xyz+p[1].xyz*(position.x-size.x*.5)/p[0].w+p[2].xyz*(size.y*.5-position.y)/p[0].w;
  if(ray.y<-.00001 && p[0].y>0){
   float2 xz=(p[0].xyz-ray*p[0].y/ray.y).xz;
   float2 muv=float2(dot(p[5].xyz,float3(xz,1)),dot(p[6].xyz,float3(xz,1)));
   if(all(xz>=p[7].xy)&&all(xz<=p[7].zw)&&all(muv>=0)&&all(muv<=1))color=bg*(1-mask.sample(s,muv).r);
  }
 }
 return color;
}
fragment float4 resolveClassic(V v [[stage_in]],texture2d<float> front [[texture(0)]],texture2d<float> mirror [[texture(1)]],
 texture2d<float> mask [[texture(2)]],texture2d<float> normal [[texture(3)]],texture2d<float> glass [[texture(4)]],
 constant uint4& paneBounds [[buffer(2)]],constant float4* p [[buffer(0)]],constant uint4& tile [[buffer(1)]]){
 uint2 pixel=uint2(v.pos.xy), origin=(pixel-tile.xy)*tile.z;
 bool hasGlass=tile.w && all(pixel>=paneBounds.xy) && all(pixel<paneBounds.zw);
 float3 sum=0;
 for(uint y=0; y<tile.z; ++y) for(uint x=0; x<tile.z; ++x){
   uint2 offset=uint2(x,y), sample=origin+offset;
   float4 object=front.read(sample);
   float3 linear=object.rgb;
   if(object.a<1.){
     float2 position=float2(pixel)+(float2(offset)+.5)/float(tile.z);
     linear+=(1.-object.a)*lin(classicBacking(position,mirror,mask,normal,p));
   }
   float3 display=enc(linear);
   if(hasGlass){
     float4 pane=glass.read(sample);
     display=pane.rgb+(1.-pane.a)*display;
   }
   sum+=saturate(display);
 }
 return float4(sum/float(tile.z*tile.z),1);
}
"""
