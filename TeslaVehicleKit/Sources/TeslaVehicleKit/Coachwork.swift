import MetalKit
import RealityKit
import simd

/// A baked incident light field shared by paint, glass and the cyclorama.
/// Meshes and pipelines live for the lifetime of the vehicle or viewport.
@MainActor final class StudioRadiance {
    let directory:URL
    let room:any MTLTexture
    private var paneMaps:(low:any MTLTexture,high:any MTLTexture)?

    init(device:any MTLDevice,directory:URL)throws{
        self.directory=directory
        let bytes=try Data(contentsOf:directory.appendingPathComponent("CoatFields.f16"),options:.mappedIfSafe)
        let width:Int
        switch bytes.count {
        case 6*1024*512*8:width=1024
        case 6*512*256*8:width=512
        default:throw VehicleError.invalid("Incomplete angular radiance fields in "+directory.path)
        }
        let height=width/2,row=width*8
        let desc=MTLTextureDescriptor()
        desc.textureType = .type2DArray;desc.width=width;desc.height=height;desc.arrayLength=6
        desc.pixelFormat = .rgba16Float;desc.storageMode = .shared;desc.usage = .shaderRead
        guard let array=device.makeTexture(descriptor:desc) else{throw VehicleError.invalid("Cannot allocate angular radiance fields")}
        bytes.withUnsafeBytes { p in
            for i in 0..<6{
                array.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,slice:i,
                              withBytes:p.baseAddress!.advanced(by:i*height*row),bytesPerRow:row,bytesPerImage:height*row)
            }
        }
        room=array
    }
    func glazing(using loader:MTKTextureLoader)throws -> (low:any MTLTexture,high:any MTLTexture) {
        if let paneMaps{return paneMaps}
        let options:[MTKTextureLoader.Option:Any]=[.SRGB:true,.generateMipmaps:true,.origin:MTKTextureLoader.Origin.topLeft]
        let low=try loader.newTexture(URL:directory.appendingPathComponent("RoomLo.png"),options:options)
        let high=try loader.newTexture(URL:directory.appendingPathComponent("RoomHi.png"),options:options)
        paneMaps=(low,high);return (low,high)
    }
}

/// Scene-linear replacement of body paint only. Trim provides depth, never
/// a painted-over silhouette. The same operation precedes the floor mirror.
@MainActor final class Coachwork {
    let geometry:CoatGeometry,native:Bool
    private let device:any MTLDevice,gbuffer:any MTLRenderPipelineState,shade:any MTLComputePipelineState,depth:any MTLDepthStencilState
    private let lobes,fabric,atlas,dummy:any MTLTexture
    private let sampleOffsets:[SIMD2<Float>]
    private struct Gate{let normals,z:any MTLTexture}
    private var gates=[Int:Gate]()
    private(set) var events:(any MTLTexture)?
    static func nativeAvailable(_ d:any MTLDevice)->Bool{
        #if targetEnvironment(simulator)
        return false
        #else
        return d.supportsRaytracing
        #endif
    }
    static func source()throws->String{
        guard let file=Bundle.module.url(forResource:"Coachwork",withExtension:"metal",subdirectory:"Shaders") else{throw VehicleError.invalid("Missing coachwork Metal source")}
        return try String(contentsOf:file,encoding:.utf8)
    }
    init(_ d:any MTLDevice,dir:URL,native:Bool)throws{
        device=d;self.native=native;geometry=try CoatGeometry(d,dir:dir)
        sampleOffsets=d.getDefaultSamplePositions(sampleCount:4).map{SIMD2($0.x,$0.y)}
        let source=try Self.source()
        let lib=try d.makeLibrary(source:"#define COACH_NATIVE \(native ? 1:0)\n"+source,options:nil)
        let pd=MTLRenderPipelineDescriptor();pd.vertexFunction=lib.makeFunction(name:"coachVertex");pd.fragmentFunction=lib.makeFunction(name:"coachNormal")
        pd.colorAttachments[0].pixelFormat = .rgba16Float;pd.depthAttachmentPixelFormat = .depth32Float;pd.rasterSampleCount=4
        gbuffer=try d.makeRenderPipelineState(descriptor:pd)
        let z=MTLDepthStencilDescriptor();z.depthCompareFunction = .less;z.isDepthWriteEnabled=true
        guard let test=d.makeDepthStencilState(descriptor:z),let kernel=lib.makeFunction(name:"exposeCoach") else{throw VehicleError.invalid("Cannot expose coachwork")}
        depth=test;shade=try d.makeComputePipelineState(function:kernel)
        let loader=MTKTextureLoader(device:d)
        func texture(_ name:String,_ srgb:Bool,_ mip:Bool)throws->any MTLTexture{
            try loader.newTexture(URL:dir.appendingPathComponent(name),options:[.SRGB:srgb,.generateMipmaps:mip,.origin:MTKTextureLoader.Origin.topLeft])
        }
        lobes=try texture("EmitterLobes.png",true,false);fabric=try texture("CoatSlopes.png",false,true);atlas=try texture("BounceAlbedo.png",true,false)
        dummy=try Self.tex(d,.r8Uint,1,1,[.shaderWrite])
    }
    private static func tex(_ d:any MTLDevice,_ fmt:MTLPixelFormat,_ w:Int,_ h:Int,_ usage:MTLTextureUsage,shared:Bool=false,sampleCount:Int=1)throws->any MTLTexture{
        let t=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:fmt,width:w,height:h,mipmapped:false)
        if sampleCount>1{t.textureType = .type2DMultisample;t.sampleCount=sampleCount}
        t.storageMode=shared ? .shared:.private;t.usage=usage
        guard let x=d.makeTexture(descriptor:t) else{throw VehicleError.invalid("No paint interface target")};return x
    }
    func expose(_ target:any MTLTexture,slot:Int,params:[SIMD4<Float>],car:VehicleScene,relief:any MTLTexture,field:any MTLTexture,
                radiance:StudioRadiance,local:Bool,record:Bool,cmd:any MTLCommandBuffer)throws->any MTLTexture{
        let w=target.width,h=target.height
        // Reuse the same multisample gate across horizontal strips for large
        // exports. A 4096² image uses the same peak gate allocation as 1600².
        let maxPixels=slot==0 ? 1600*1600 : 800*800
        let stripHeight=min(h,maxPixels/w)
        if gates[slot]?.z.width != w || gates[slot]?.z.height != stripHeight {
            gates[slot]=try Gate(normals:Self.tex(device,.rgba16Float,w,stripHeight,[.shaderRead,.renderTarget],sampleCount:4),
                                 z:Self.tex(device,.depth32Float,w,stripHeight,[.shaderRead,.renderTarget],sampleCount:4))
        }
        guard let gate=gates[slot],let ib=geometry.ib,let rig=car.photo,let lamp=rig.lamp else{throw VehicleError.invalid("Unposed paint interface")}
        let pass=MTLRenderPassDescriptor(),col=pass.colorAttachments[0]!
        col.texture=gate.normals;col.clearColor=MTLClearColorMake(0,0,0,0);col.loadAction = .clear;col.storeAction = .store
        pass.depthAttachment.texture=gate.z;pass.depthAttachment.clearDepth=1;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .store
        let inspect=record && slot==0
        if inspect && (events?.width != w || events?.height != h){events=try Self.tex(device,.r8Uint,w,h,[.shaderWrite],shared:true)}
        if !record{events=nil}
        let paint=car.photographicPaint ?? .init(rgb:0xaaaaaa,metal:1,rough:0.3)
        let p=params+[SIMD4(paint.binder,paint.family),[paint.metal,paint.rough,rig.localFloor ? 1:0,local ? 0:1],
                      [Float(geometry.palette.columns),Float(geometry.palette.rows),Float(geometry.topCount),inspect ? 1:0],
                      [paint.normalReflectance ?? -1,paint.metal / 0.65,(paint.rough - 0.24) / 0.30,0],
                      SIMD4(paint.flake,Float(geometry.palette.exteriorTileSpan ?? 1))]
        for firstRow in stride(from:0,to:h,by:stripHeight){
            guard let e=cmd.makeRenderCommandEncoder(descriptor:pass) else{throw VehicleError.invalid("Cannot rasterize body normals")}
            e.setRenderPipelineState(gbuffer);e.setDepthStencilState(depth);e.setCullMode(.none)
            e.setViewport(.init(originX:0,originY:-Double(firstRow),width:Double(w),height:Double(h),znear:0,zfar:1))
            e.setVertexBuffer(geometry.vb,offset:0,index:0);e.setVertexBuffer(geometry.inst,offset:0,index:1)
            params.withUnsafeBytes{e.setVertexBytes($0.baseAddress!,length:$0.count,index:2)}
            for (i,m) in geometry.instances.enumerated() where m.ids.z != 3{
                let g=geometry.parts[Int(m.ids.w)]
                e.drawIndexedPrimitives(type:.triangle,indexCount:g.count*3,indexType:.uint32,indexBuffer:ib,indexBufferOffset:g.first*12,instanceCount:1,baseVertex:0,baseInstance:i)
            }
            e.endEncoding()
            guard let c=cmd.makeComputeCommandEncoder() else{throw VehicleError.invalid("Cannot shade coachwork")}
            c.setComputePipelineState(shade)
            sampleOffsets.withUnsafeBytes{c.setBytes($0.baseAddress!,length:$0.count,index:9)}
            var row=UInt32(firstRow)
            c.setBytes(&row,length:MemoryLayout<UInt32>.size,index:10)
            p.withUnsafeBytes{c.setBytes($0.baseAddress!,length:$0.count,index:0)}
            lamp.meter.samples.withUnsafeBytes{c.setBytes($0.baseAddress!,length:$0.count,index:1)}
            for (i,b) in [geometry.vb,geometry.ib,geometry.nb,geometry.top,geometry.inst].enumerated(){c.setBuffer(b,offset:0,index:i+2)}
            if native{c.setAccelerationStructure(geometry.sceneAS,bufferIndex:8);for a in geometry.bottomAS{c.useResource(a,usage:.read)}}
            for (i,t) in [target,gate.normals,gate.z,radiance.room,lobes,field,fabric,atlas,relief,inspect ? events!:dummy].enumerated(){c.setTexture(t,index:i)}
            c.dispatchThreads(.init(width:w,height:min(stripHeight,h-firstRow),depth:1),threadsPerThreadgroup:.init(width:8,height:8,depth:1));c.endEncoding()
        }
        return gate.normals
    }
}
