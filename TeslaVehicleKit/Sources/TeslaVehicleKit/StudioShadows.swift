import Metal
import RealityKit
import simd

/// Project the live, opaque triangles onto the floor from different parts
/// of the softbox and sky. No shadow decal, model readback or fixed wheelbase.
@MainActor final class StudioShadows {
    private struct Geometry {
        let vertices,normals,indices:any MTLBuffer
        let texcoords:(any MTLBuffer)?
        let count,material:Int
        let local:simd_float4x4
    }
    private struct Entry {let mesh:MeshResource;let draws:[Geometry];let includesTexcoords:Bool}
    private struct ReceiverMaps {
        let roughness,metallic:(any MTLTexture)?
        let scales:SIMD2<Float>
    }
    private struct PosedDraw {
        let geometry:Geometry
        let matrix:simd_float4x4
        let kind:UInt32
        let material:SIMD4<Float>
        let maps:ReceiverMaps?
    }
    private struct MapCopy {
        let source:TextureResource
        let texture:(any MTLTexture)?
    }
    private var mapCopies=[ObjectIdentifier:MapCopy]()
    private var cache=[ObjectIdentifier:Entry]()
    private let pipe,visibilityPipe,skyPipe:any MTLRenderPipelineState
    private let depthPipe,mappedDepthPipe,reliefPipe:any MTLRenderPipelineState
    private let depthState:any MTLDepthStencilState
    private var posed=[PosedDraw]()
    private(set) var floorBounds = BoundingBox.empty
    let skyIntegral:any MTLTexture
    private var integratedRoom:(any MTLTexture)?
    func drawGlassOccluders(_ encoder:any MTLRenderCommandEncoder,includeOptical:Bool=false){
        func draw(_ g:Geometry,_ m:simd_float4x4){
            var m=m;encoder.setVertexBuffer(g.vertices,offset:0,index:0);encoder.setVertexBytes(&m,length:64,index:1)
            encoder.drawIndexedPrimitives(type:.triangle,indexCount:g.count,indexType:.uint32,indexBuffer:g.indices,indexBufferOffset:0)
        }
        for part in posed where includeOptical || part.kind==0{draw(part.geometry,part.matrix)}
    }
    private struct ReceiverTargets{
        let z,response,normals,relief:any MTLTexture
    }
    private var receivers=[Int:ReceiverTargets]()
    private let device:any MTLDevice
    let atlas:any MTLTexture
    private let visibility:any MTLTexture
    init(device:any MTLDevice,library:any MTLLibrary)throws {
        self.device=device
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rg8Unorm,width:2048,height:2048,mipmapped:true)
        d.storageMode = .private;d.usage=[.renderTarget,.shaderRead]
        guard let a=device.makeTexture(descriptor:d) else{throw VehicleError.invalid("No studio shadow atlas")};atlas=a
        let p=MTLRenderPipelineDescriptor()
        p.vertexFunction=library.makeFunction(name:"projectCaster");p.fragmentFunction=library.makeFunction(name:"blocker")
        let color=p.colorAttachments[0]!
        color.pixelFormat=d.pixelFormat;color.isBlendingEnabled=true
        color.rgbBlendOperation = .max;color.alphaBlendOperation = .max
        color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor = .one
        pipe=try device.makeRenderPipelineState(descriptor:p)
        // Eight orthographic views of the *posed car*, not of the viewport.
        // Each stores nearest opaque, clear-glass and tinted-glass depths.
        // Keeping separate channels lets light pass through an actual pane.
        let vt=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Unorm,width:2048,height:1024,mipmapped:false)
        vt.storageMode = .private;vt.usage=[.shaderRead,.renderTarget]
        guard let v=device.makeTexture(descriptor:vt) else{throw VehicleError.invalid("No studio visibility atlas")};visibility=v
        let vp=MTLRenderPipelineDescriptor()
        vp.vertexFunction=library.makeFunction(name:"visibilityCaster");vp.fragmentFunction=library.makeFunction(name:"nearestSurface")
        let vc=vp.colorAttachments[0]!;vc.pixelFormat=vt.pixelFormat;vc.isBlendingEnabled=true
        vc.rgbBlendOperation = .min;vc.alphaBlendOperation = .min
        vc.sourceRGBBlendFactor = .one;vc.destinationRGBBlendFactor = .one
        visibilityPipe=try device.makeRenderPipelineState(descriptor:vp)
        let z=MTLRenderPipelineDescriptor();z.vertexFunction=library.makeFunction(name:"depthCaster");z.depthAttachmentPixelFormat = .depth32Float
        z.colorAttachments[0].pixelFormat = .rgba8Unorm;z.colorAttachments[1].pixelFormat = .rgba8Snorm;z.fragmentFunction=library.makeFunction(name:"receiverMaterial")
        depthPipe=try device.makeRenderPipelineState(descriptor:z)
        z.vertexFunction=library.makeFunction(name:"mappedDepthCaster")
        z.fragmentFunction=library.makeFunction(name:"mappedReceiverMaterial")
        mappedDepthPipe=try device.makeRenderPipelineState(descriptor:z)
        let settings=MTLDepthStencilDescriptor();settings.isDepthWriteEnabled=true;settings.depthCompareFunction = .less
        guard let ds=device.makeDepthStencilState(descriptor:settings) else{throw VehicleError.invalid("No studio depth state")};depthState=ds
        let ao=MTLRenderPipelineDescriptor();ao.vertexFunction=library.makeFunction(name:"triangle")
        ao.fragmentFunction=library.makeFunction(name:"localRelief");ao.colorAttachments[0].pixelFormat = .rgba16Float
        reliefPipe=try device.makeRenderPipelineState(descriptor:ao)
        let sd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:32,height:65,mipmapped:false)
        sd.storageMode = .private;sd.usage=[.shaderRead,.renderTarget]
        guard let integrated=device.makeTexture(descriptor:sd) else{throw VehicleError.invalid("No ground sky integral")}
        skyIntegral=integrated
        let sp=MTLRenderPipelineDescriptor();sp.vertexFunction=library.makeFunction(name:"triangle")
        sp.fragmentFunction=library.makeFunction(name:"integrateGroundSky");sp.colorAttachments[0].pixelFormat = sd.pixelFormat
        skyPipe=try device.makeRenderPipelineState(descriptor:sp)
    }
    private func scalarMap(_ input:MaterialParameters.Texture?,used:inout Set<ObjectIdentifier>)->(any MTLTexture)? {
        guard let input,input.uvIndex==0,input.swizzle.red == .red else{return nil}
        let resource=input.resource
        guard resource.textureType == .type2D,resource.pixelFormat == .r8Unorm else{return nil}
        let id=ObjectIdentifier(resource)
        used.insert(id)
        if let copy=mapCopies[id]{return copy.texture}
        // RealityKit copies the loaded texture on the GPU, including its mip levels.
        // Keep one result per bound resource across poses and light changes.
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:resource.pixelFormat,
            width:resource.width,height:resource.height,mipmapped:resource.mipmapLevelCount>1)
        descriptor.mipmapLevelCount=resource.mipmapLevelCount
        descriptor.storageMode = .private
        descriptor.usage=[.shaderRead,.shaderWrite,.renderTarget,.pixelFormatView]
        var texture=device.makeTexture(descriptor:descriptor)
        if let destination=texture {
            do {try resource.copy(to:destination)} catch {texture=nil}
        }
        mapCopies[id]=MapCopy(source:resource,texture:texture)
        return texture
    }
    private func geometry(_ mesh:MeshResource,includeTexcoords:Bool)throws->[Geometry]{
        let id=ObjectIdentifier(mesh)
        if let item=cache[id],!includeTexcoords || item.includesTexcoords{return item.draws}
        let contents=mesh.contents
        var result=[Geometry]()
        for model in contents.models {
            let instances=contents.instances.filter{$0.model==model.id}.map(\.transform)
            for part in model.parts {
                guard let indices=part.triangleIndices?.elements,!indices.isEmpty else{continue}
                let points=part.positions.elements
                let normals=part.normals?.elements ?? [SIMD3<Float>](repeating:.zero,count:points.count)
                guard !points.isEmpty,
                      let vb=points.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
                      let nb=normals.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
                      let ib=indices.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)})
                else{throw VehicleError.invalid("Cannot buffer studio caster")}
                var texcoords:(any MTLBuffer)?
                if includeTexcoords,let uv=part.textureCoordinates?.elements,uv.count==points.count {
                    texcoords=uv.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}
                }
                for transform in instances.isEmpty ? [matrix_identity_float4x4]:instances {
                    result.append(.init(vertices:vb,normals:nb,indices:ib,texcoords:texcoords,count:indices.count,material:part.materialIndex,local:transform))
                }
            }
        }
        cache[id]=Entry(mesh:mesh,draws:result,includesTexcoords:includeTexcoords);return result
    }
    func encode(car:VehicleScene,light:PhotographicLight,command:any MTLCommandBuffer)throws{
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=atlas
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        guard let e=command.makeRenderCommandEncoder(descriptor:pass) else{throw VehicleError.invalid("Cannot project studio shadow")}
        e.setRenderPipelineState(pipe);e.setCullMode(.none)
        var sources=[SIMD4<Float>]()
        // One shadow projection for each vertical pair of fabric samples.
        // Ground shading uses both samples' incident RGB, distance and cosine.
        let taps = light.meter.quadrature
        let luma = light.color * SIMD3<Float>(0.2126, 0.7152, 0.0722)
        for tile in 0..<8 {
            let first = (tile / 4) * 8 + tile % 4
            let a = taps[first], b = taps[first + 4]
            let wa = simd_dot(SIMD3(a[2], a[3], a[4]), luma)
            let wb = simd_dot(SIMD3(b[2], b[3], b[4]), luma)
            let fraction = wa + wb > 0 ? wb / (wa + wb) : 0.5
            let uv = simd_mix(SIMD2(a[0], a[1]), SIMD2(b[0], b[1]), SIMD2(repeating: fraction))
            sources.append(SIMD4(light.center + light.u * (uv.x * light.width) + light.v * (uv.y * light.height), 1))
        }
        // One zenith view stores the lower and upper surfaces above the
        // floor. The sky integral uses their continuous angular silhouettes.
        sources.append([0,1,0,0])
        sources.withUnsafeBytes{e.setVertexBytes($0.baseAddress!,length:$0.count,index:2)}
        var region=light.shadowRegion;e.setVertexBytes(&region,length:16,index:3)
        var used=Set<ObjectIdentifier>();posed.removeAll(keepingCapacity:true);floorBounds = .empty
        var usedMaps=Set<ObjectIdentifier>()
        let rig=car.photo
        let panes=rig?.mountedPanes() ?? []
        let paneIDs=Set(panes.map{ObjectIdentifier($0.front)})
        func add(_ mesh:MeshResource,_ world:simd_float4x4,_ kind:UInt32,_ materials:[any Material]=[],exterior:Bool=false)throws{
            used.insert(ObjectIdentifier(mesh))
            if kind==0{floorBounds.formUnion(mesh.bounds.transformed(by:world))}
            for g in try geometry(mesh,includeTexcoords:exterior){
                var matrix=world*g.local
                if kind==0{
                    e.setVertexBuffer(g.vertices,offset:0,index:0);e.setVertexBytes(&matrix,length:64,index:1)
                    e.drawIndexedPrimitives(type:.triangle,indexCount:g.count,indexType:.uint32,indexBuffer:g.indices,
                                            indexBufferOffset:0,instanceCount:9)
                }
                var response=SIMD4<Float>(0.04,1,0.5,0)
                var maps:ReceiverMaps?
                if materials.indices.contains(g.material){
                    if let mat=materials[g.material] as? PhysicallyBasedMaterial{
                        let emit=mat.emissiveColor.color.cgColor.components?.dropLast().max() ?? 0
                        let emissive=mat.emissiveIntensity>0 && (emit>0 || mat.emissiveColor.texture != nil)
                        let diffuse=mat.metallic.texture == nil ? 1-mat.metallic.scale:1
                        response = [0.08*mat.specular.scale + 0.04*mat.clearcoat.scale,emissive ? 0:diffuse,
                                    mat.roughness.texture == nil ? mat.roughness.scale:0.55,
                                    0]
                        let transform=mat.textureCoordinateTransform
                        if exterior,g.texcoords != nil,transform.offset == .zero,transform.scale == .one,transform.rotation==0 {
                            let rough=scalarMap(mat.roughness.texture,used:&usedMaps)
                            let metal=emissive ? nil:scalarMap(mat.metallic.texture,used:&usedMaps)
                            if rough != nil || metal != nil {
                                maps=ReceiverMaps(roughness:rough,metallic:metal,
                                    scales:[rough == nil ? -1:mat.roughness.scale,metal == nil ? -1:mat.metallic.scale])
                            }
                        }
                    }else if materials[g.material] is UnlitMaterial{response.y=0}
                }
                posed.append(PosedDraw(geometry:g,matrix:matrix,kind:kind,material:response,maps:maps))
            }
        }
        func draw(_ node:Entity)throws{
            guard node.isEnabled,!paneIDs.contains(ObjectIdentifier(node)) else{return}
            if let m=node.components[ModelComponent.self] {
                let name=(node.name+" "+(m.materials.first?.name ?? "")).lowercased()
                if !["glass_interior_transmission","beam","projection","glow","shadow","groundplane"].contains(where:name.contains){
                    let pane=name.contains("glazing") || name.contains("privacy") || name.contains("glass")
                    var kind:UInt32=0
                    let tint=["tint","dark","top","privacy"].contains(where:name.contains)
                    if pane,let p=m.materials.first as? PhysicallyBasedMaterial,case .transparent=p.blending{kind=tint ? 2:1}
                    if pane,m.materials.first is ShaderGraphMaterial{kind=tint ? 2:1}
                    if kind==0 || !name.contains("interior"){
                        // WindowAccent draws retain their parent's authored material and UVs.
                        let source=node.name.hasPrefix("WindowAccent_") ? node.parent?.name ?? "":node.name
                        let prefix="NorthlightSurface_"
                        let exterior=kind==0 && source.hasPrefix(prefix) && rig?.hasAuthoredExteriorMaps(String(source.dropFirst(prefix.count)))==true
                        try add(m.mesh,node.transformMatrix(relativeTo:nil),kind,m.materials,exterior:exterior)
                    }
                }
            }
            for child in node.children{try draw(child)}
        }
        do{
            try draw(car.body)
            for pane in panes{
                let matrix=pane.front.transformMatrix(relativeTo:nil)
                for piece in pane.pieces{
                    try add(piece.mesh,matrix,piece.shadowKind)
                }
            }
        }catch{e.endEncoding();throw error}
        e.endEncoding();cache=cache.filter{used.contains($0.key)}
        mapCopies=mapCopies.filter{usedMaps.contains($0.key)}
        guard !posed.isEmpty,let b=command.makeBlitCommandEncoder() else{throw VehicleError.invalid("Empty studio caster set")}
        b.generateMipmaps(for:atlas);b.endEncoding()
        let casts=MTLRenderPassDescriptor();let slot=casts.colorAttachments[0]!
        slot.texture=visibility;slot.clearColor=MTLClearColorMake(1,1,1,1);slot.loadAction = .clear;slot.storeAction = .store
        guard let vis=command.makeRenderCommandEncoder(descriptor:casts) else{throw VehicleError.invalid("Cannot expose studio visibility")}
        vis.setRenderPipelineState(visibilityPipe);vis.setCullMode(.none)
        ([light.shadowRegion]+light.vectors).withUnsafeBytes{vis.setVertexBytes($0.baseAddress!,length:$0.count,index:2)}
        for part in posed {
            let g=part.geometry
            var matrix=part.matrix,kind=part.kind
            vis.setVertexBuffer(g.vertices,offset:0,index:0);vis.setVertexBytes(&matrix,length:64,index:1)
            vis.setVertexBytes(&kind,length:4,index:3)
            vis.drawIndexedPrimitives(type:.triangle,indexCount:g.count,indexType:.uint32,indexBuffer:g.indices,indexBufferOffset:0,instanceCount:8)
        }
        vis.endEncoding()
    }
    func integrateSky(_ room:any MTLTexture,command:any MTLCommandBuffer)throws {
        if integratedRoom === room{return}
        let pass=MTLRenderPassDescriptor(),slot=pass.colorAttachments[0]!
        slot.texture=skyIntegral;slot.loadAction = .dontCare;slot.storeAction = .store
        guard let enc=command.makeRenderCommandEncoder(descriptor:pass) else{throw VehicleError.invalid("Cannot integrate studio sky")}
        enc.setRenderPipelineState(skyPipe);enc.setFragmentTexture(room,index:0)
        enc.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);enc.endEncoding()
        integratedRoom=room
    }
    /// Reconstruct the opaque receiver in metres and integrate its lighting
    /// separately for the room and diffuser through the posed visibility atlas.
    func surfaceRelief(params:[SIMD4<Float>],slot:Int,room:any MTLTexture,lamp:PhotographicLight,command:any MTLCommandBuffer)throws->any MTLTexture{
        let size=SIMD2(params[1].w,params[2].w),scale=min(1,960/max(size.x,size.y))
        let w=max(4,Int((size.x*scale).rounded())),h=max(4,Int((size.y*scale).rounded()))
        if receivers[slot]?.z.width != w || receivers[slot]?.z.height != h{
            func texture(_ format:MTLPixelFormat)throws->any MTLTexture{
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
                d.storageMode = .private;d.usage=[.shaderRead,.renderTarget]
                guard let t=device.makeTexture(descriptor:d) else{throw VehicleError.invalid("No receiver texture")}
                return t
            }
            receivers[slot]=try ReceiverTargets(z:texture(.depth32Float),response:texture(.rgba8Unorm),normals:texture(.rgba8Snorm),relief:texture(.rgba16Float))
        }
        let targets=receivers[slot]!,zBuffer=targets.z,relief=targets.relief,surfaceResponse=targets.response
        let depth=MTLRenderPassDescriptor();depth.depthAttachment.texture=zBuffer
        let response=depth.colorAttachments[0]!;response.texture=surfaceResponse
        response.loadAction = .clear;response.storeAction = .store
        let normal=depth.colorAttachments[1]!;normal.texture=targets.normals
        normal.loadAction = .clear;normal.storeAction = .store
        depth.depthAttachment.loadAction = .clear;depth.depthAttachment.clearDepth=1;depth.depthAttachment.storeAction = .store
        guard let z=command.makeRenderCommandEncoder(descriptor:depth) else{throw VehicleError.invalid("Cannot encode vehicle depth")}
        z.setRenderPipelineState(depthPipe);z.setDepthStencilState(depthState);z.setCullMode(.none)
        params.withUnsafeBytes{z.setVertexBytes($0.baseAddress!,length:$0.count,index:2)}
        var usingMaps=false
        for part in posed where part.kind==0{
            let g=part.geometry,mapped=part.maps != nil
            var matrix=part.matrix,material=part.material
            if mapped != usingMaps {
                z.setRenderPipelineState(mapped ? mappedDepthPipe:depthPipe)
                usingMaps=mapped
            }
            if let maps=part.maps {
                z.setVertexBuffer(g.texcoords,offset:0,index:5)
                // A missing channel keeps its scalar response. Bind the other valid
                // channel to that unused texture slot for Metal validation.
                z.setFragmentTexture(maps.roughness ?? maps.metallic,index:0)
                z.setFragmentTexture(maps.metallic ?? maps.roughness,index:1)
                var scales=maps.scales
                z.setFragmentBytes(&scales,length:8,index:1)
            }
            z.setFragmentBytes(&material,length:16,index:0)
            z.setVertexBuffer(g.normals,offset:0,index:3)
            var inverse=matrix.inverse;z.setVertexBytes(&inverse,length:64,index:4)
            z.setVertexBuffer(g.vertices,offset:0,index:0);z.setVertexBytes(&matrix,length:64,index:1)
            z.drawIndexedPrimitives(type:.triangle,indexCount:g.count,indexType:.uint32,indexBuffer:g.indices,indexBufferOffset:0)
        }
        z.endEncoding()
        let dest=MTLRenderPassDescriptor();dest.colorAttachments[0].texture=relief
        dest.colorAttachments[0].loadAction = .dontCare;dest.colorAttachments[0].storeAction = .store
        guard let a=command.makeRenderCommandEncoder(descriptor:dest) else{throw VehicleError.invalid("Cannot encode studio relief")}
        a.setRenderPipelineState(reliefPipe);a.setFragmentTexture(zBuffer,index:0)
        a.setFragmentTexture(visibility,index:1);a.setFragmentTexture(room,index:2);a.setFragmentTexture(surfaceResponse,index:3);a.setFragmentTexture(targets.normals,index:4)
        lamp.meter.samples.withUnsafeBytes{a.setFragmentBytes($0.baseAddress!,length:$0.count,index:2)}
        params.withUnsafeBytes{a.setFragmentBytes($0.baseAddress!,length:$0.count,index:1)}
        var focal=params[0].w*Float(h)/size.y;a.setFragmentBytes(&focal,length:4,index:0)
        a.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);a.endEncoding();return relief
    }
}

let studioShadowSource = """
constant float3 studioDirections[7]={{.06,.43,-.90},{-.82,.56,.15},{.84,.42,.31},{.15,.66,.74},
                                    {-.12,.985,-.13},{-.44,-.81,-.38},{.66,-.62,.41}};
struct LightSpace {float3 x,y,n,c;float diameter;};
LightSpace studioView(uint k,constant float4* rig){
 float3 c=(rig[5].xyz+rig[6].xyz)*.5;
 float3 n=normalize(k==0?rig[1].xyz-c:studioDirections[k-1]);
 float3 x=normalize(cross(float3(0,1,0),n));
 return {x,cross(n,x),n,c,1.65*rig[0].z};
}
float3 lightPoint(LightSpace s,float3 pos){
 float3 d=(pos-s.c)/s.diameter;
 return .5+float3(dot(d,s.x),dot(d,s.y),-dot(d,s.n));
}
struct VisOut{float4 pos [[position]];float z;uint tile [[flat]];uint kind [[flat]];};
vertex VisOut visibilityCaster(uint i [[vertex_id]],uint tile [[instance_id]],const device float3* verts [[buffer(0)]],
 constant float4x4& model [[buffer(1)]],constant float4* rig [[buffer(2)]],constant uint& kind [[buffer(3)]]){
 float3 h=lightPoint(studioView(tile,rig),(model*float4(verts[i],1)).xyz);
 float2 uv=(float2(tile%4,tile/4)+h.xy)/float2(4,2);
 return {float4(uv.x*2-1,1-uv.y*2,h.z,1),h.z,tile,kind};
}
fragment float4 nearestSurface(VisOut s [[stage_in]]){
 uint2 t=uint2(s.pos.xy)/512;if(t.x+4*t.y!=s.tile)discard_fragment();
 float4 d=1.;d[s.kind]=s.z;return d;
}
// Soft shadow estimator in metres. Compare each depth first and only
// then average the transmissions, so walls never leak through a filtered
// depth value. The taps spread with blocker-to-receiver separation.
float3 studioTransmission(float3 p,float3 n,float3 geometric,float3 reflected,float rough,texture2d<float> tex,texture2d_array<float> room,constant float4* rig){
 constexpr sampler env(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
 constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
 float received=0,total=0,key=1.,specTotal=0.,specReceived=0.;
 // Integrate the broad reflected lobe against the same room sight lines.
 // Seven directions cannot resolve a polished reflection, which remains
 // with the native material as its roughness approaches zero.
 // Each of the seven room views samples a finite angular cell. Add its
 // angular variance before integrating the lobe, so a single ray cannot
 // supply the entire rough reflection of an extended opening.
 float variance=pow(rough,4.)+.28;
 float exponent=max(0.,2./variance-2.);
 for(uint i=0;i<8;i++){
  LightSpace s=studioView(i,rig);float cosine=dot(n,s.n);
  float2 uv=float2(atan2(s.n.x,s.n.z)/6.2831853,acos(s.n.y)/3.14159265);
  float w=max(0.,cosine)*dot(room.sample(env,uv,3,level(0.)).rgb,float3(.2126,.7152,.0722));
  float sw=w*pow(max(.0001,dot(reflected,s.n)),exponent);
  if(i>0){if(w<.0001)continue;total+=w;specTotal+=sw;}
  float3 q=lightPoint(s,p+geometric*.011+s.n*.006);
  if(any(q.xy<.008)||any(q.xy>.992)||q.z<=0.||q.z>=1.){if(i>0){received+=w;specReceived+=sw;}continue;}
  float2 grid=float2(i%4,i/4),cells=float2(4,2);
  float dx=dot(geometric,s.x),dy=dot(geometric,s.y),dn=dot(geometric,s.n);
  float slope=(dn>=0.?1.:-1.)/max(.14,abs(dn));
  float separation=0.,blockers=0.;
  // Search around the sight line. Estimating the penumbra from a single
  // center depth collapses it as soon as that ray clears a seat or sill.
  const float2 probes[]={{0,0},{-.82,-.36},{.38,-.79},{.74,.42},{-.27,.83}};
  for(uint j=0;j<5;j++){
   float2 off=probes[j]*.018;
   float4 z=tex.sample(nearest,(grid+clamp(q.xy+off,.001,.999))/cells);
   float closest=min(min(z.x,z.y),min(z.z,z.w));
   float dz=q.z+clamp((off.x*dx+off.y*dy)*slope,-.035,.035)-closest;
   if(dz>.0015){separation+=dz;blockers+=1.;}
  }
  separation/=max(1.,blockers);
  // The panel and this view share their horizontal axis. Its half angles
  // determine the key penumbra in each dimension; contact has zero spread.
  float2 radius=i==0 ? min(float2(.15),.0016+separation*float2(rig[1].w,rig[2].w)/max(.001,distance(p,rig[1].xyz)))
                     : float2(min(.078,.0020+separation*.78));
  float sum=0.;
  for(uint j=0;j<9;j++){
   float2 off=taps[j]*radius;

   // Bias follows the local depth plane at the offset location.
   float plane=(off.x*dx+off.y*dy)*slope;
   float limit=2.*max(radius.x,radius.y);
   float compare=q.z+clamp(plane,-limit,limit)-.0012;
   // Reconstruct visibility across neighboring texel centers *after* the
   // depth comparisons. A moving receiver no longer steps across binary
   // shadow-map texels on an otherwise smooth leather bolster.
   float2 pix=clamp(q.xy+off,.002,.998)*512.-.5,f=fract(pix);
   uint2 ix=uint2(floor(pix))+uint2(grid)*512;
   for(uint k=0;k<4;k++){
    uint2 d=uint2(k&1,k>>1);float4 z=tex.read(ix+d);
    float tr=z.r<compare ? 0.:(z.g<compare?.80:1.)*(z.b<compare?.19:1.)*(z.a<compare?.052:1.);
    sum+=tr*(d.x?f.x:1.-f.x)*(d.y?f.y:1.-f.y);
   }
  }
  if(i==0)key=sum/9.;else{received+=w*sum/9.;specReceived+=sw*sum/9.;}
 }
 float sky=total>.001 ? received/total:1.;
 float spec=specTotal>.00001 ? specReceived/specTotal:sky;
 // Between the mirror limit and a fully rough surface, only the broad
 // part of the microfacet lobe is resolved by this angular quadrature.
 // The diffuse integral regularizes the broad lobe in shadowed recesses.
 float broad=mix(spec,sky,rough*rough);
 return float3(sky,key,mix(1.,broad,smoothstep(.12,.92,rough)));
}
struct Caster {float4 pos [[position]];float height;uint tile [[flat]];float heightScale [[flat]];};
vertex Caster projectCaster(uint vertexID [[vertex_id]],uint tile [[instance_id]],const device float3* vertices [[buffer(0)]],
 constant float4x4& model [[buffer(1)]],constant float4* sources [[buffer(2)]],constant float4& region [[buffer(3)]]){
 float3 p=(model*float4(vertices[vertexID],1)).xyz;float4 lamp=sources[tile];
 // Homogeneous intersection of source-to-vertex ray with y=0. Retain
 // w, so even a door that rises past part of the bank clips correctly.
 float w=lamp.y-lamp.w*p.y;
 float2 xz=(lamp.y*p.xz-p.y*lamp.xz-region.xy*w)/(2.*region.z);
 float2 grid=float2(tile%4,tile/4);
 float2 clip=((grid+.5)*w+xz)*.5-w;
 return {float4(clip.x,-clip.y,.5*w,w),p.y,tile,region.z};
}
fragment float2 blocker(Caster c [[stage_in]]){
 uint2 tile=uint2(c.pos.xy)/512;
 if(tile.x+4*tile.y!=c.tile || c.height<-.035)discard_fragment();
 if(c.tile==8){
  float h=saturate(c.height/c.heightScale);
  return float2(h,1.-h);
 }
 // R measures coverage. G encodes distance to the nearest blocker, so
 // contact stays crisp while an elevated door casts a broad penumbra.
 return float2(1.,exp(-max(0.,c.height)*1.65));
}
struct ReceiverVertex{float4 pos [[position]];float3 n;};
ReceiverVertex receiverVertex(float3 point,float3 normal,constant float4x4& model,constant float4* p,constant float4x4& inverse){
 float3 d=(model*float4(point,1)).xyz-p[0].xyz;float z=dot(d,p[3].xyz);
 return {float4(dot(d,p[1].xyz)*(2.*p[0].w/p[1].w),dot(d,p[2].xyz)*(2.*p[0].w/p[2].w),z-.035,z),
         (float4(normal,0)*inverse).xyz};
}
vertex ReceiverVertex depthCaster(uint i [[vertex_id]],const device float3* verts [[buffer(0)]],
 constant float4x4& model [[buffer(1)]],constant float4* p [[buffer(2)]],
 const device float3* normals [[buffer(3)]],constant float4x4& inverse [[buffer(4)]]){
 return receiverVertex(verts[i],normals[i],model,p,inverse);
}
struct MappedReceiverVertex{float4 pos [[position]];float3 n;float2 uv;};
vertex MappedReceiverVertex mappedDepthCaster(uint i [[vertex_id]],const device float3* verts [[buffer(0)]],
 constant float4x4& model [[buffer(1)]],constant float4* p [[buffer(2)]],const device float3* normals [[buffer(3)]],
 constant float4x4& inverse [[buffer(4)]],const device float2* uv [[buffer(5)]]){
 ReceiverVertex v=receiverVertex(verts[i],normals[i],model,p,inverse);
 // MeshResource supplies bottom-left UVs. The copied native map has top-left rows.
 return {v.pos,v.n,float2(uv[i].x,1.-uv[i].y)};
}
struct ReceiverMaterial{float4 response [[color(0)]];float4 normal [[color(1)]];};
fragment ReceiverMaterial receiverMaterial(ReceiverVertex v [[stage_in]],constant float4& response [[buffer(0)]]){
 return {response,float4(v.n*rsqrt(max(1.e-12,dot(v.n,v.n))),0.)};
}
fragment ReceiverMaterial mappedReceiverMaterial(MappedReceiverVertex v [[stage_in]],constant float4& response [[buffer(0)]],
 constant float2& scales [[buffer(1)]],texture2d<float> roughness [[texture(0)]],texture2d<float> metallic [[texture(1)]]){
 constexpr sampler tex(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
 float4 material=response;
 if(scales.x>=0.)material.z=scales.x*roughness.sample(tex,v.uv).r;
 if(scales.y>=0.)material.y=1.-scales.y*metallic.sample(tex,v.uv).r;
 return {material,float4(v.n*rsqrt(max(1.e-12,dot(v.n,v.n))),0.)};
}
float3 eyePoint(int2 q,depth2d<float> tex,float2 size,float focal){
 q=clamp(q,int2(0),int2(size)-1);
 float z=.035/max(1e-7,1.-tex.read(uint2(q)));
 return float3((float2(q)+.5-size*.5)*float2(1.,-1.)/focal,1.)*z;
}
fragment float4 localRelief(V v [[stage_in]],depth2d<float> tex [[texture(0)]],texture2d<float> vis [[texture(1)]],
 texture2d_array<float> room [[texture(2)]],texture2d<float> response [[texture(3)]],texture2d<float> normals [[texture(4)]],
 constant float& focal [[buffer(0)]],constant float4* camera [[buffer(1)]],constant float4* lamps [[buffer(2)]]){
 constexpr sampler env(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
 int2 q=int2(v.pos.xy);float2 size=float2(tex.get_width(),tex.get_height());
 float3 p=eyePoint(q,tex,size,focal);
 if(p.z>2000.)return float4(1.,1.,1.,0.);
 float3 x1=eyePoint(q+int2(1,0),tex,size,focal)-p,x0=p-eyePoint(q-int2(1,0),tex,size,focal);
 float3 y1=eyePoint(q+int2(0,1),tex,size,focal)-p,y0=p-eyePoint(q-int2(0,1),tex,size,focal);
 float3 n=cross(abs(x1.z)<abs(x0.z)?x1:x0,abs(y1.z)<abs(y0.z)?y1:y0);
 n*=rsqrt(max(1.e-16,dot(n,n)));if(dot(n,p)>0.)n=-n;
 float3 world=camera[0].xyz+p.x*camera[1].xyz+p.y*camera[2].xyz+p.z*camera[3].xyz;
 float3 nw=n.x*camera[1].xyz+n.y*camera[2].xyz+n.z*camera[3].xyz;
 float4 mat=response.read(uint2(q));
 float3 geometric=nw,eye=normalize(camera[0].xyz-world);
 float3 shadingNormal=normals.read(uint2(q)).rgb;
 if(dot(shadingNormal,shadingNormal)>.25){nw=normalize(shadingNormal);if(dot(nw,eye)<0.)nw=-nw;}
 float3 r=reflect(-eye,nw);
 float3 visibility=studioTransmission(world,nw,geometric,r,mat.z,vis,room,camera+8);
 // Native PBR draws already contain their authored AO, specular and emission.
 // Estimate only their diffuse loss in the measured room and key. A shadowed
 // receiver still sees light returned from the paper and surrounding surfaces.
 float2 uv=float2(atan2(nw.x,nw.z)/6.2831853,acos(clamp(nw.y,-1.,1.))/3.14159265);
 float3 sky=room.sample(env,uv,5,level(0.)).rgb;
 float3 incident=coveIrradiance(world,nw,camera,lamps,room),key=max(0.,incident-sky);
 float3 luma=float3(.2126,.7152,.0722);
 float indirect=dot(floorBase(world.xz),luma)*.16;
 visibility.x=mix(indirect,1.,visibility.x);
 float diffuse=dot(visibility.x*sky+mix(indirect,1.,visibility.y)*key,luma)/max(.0001,dot(incident,luma));
 float f=mat.x+(1.-mat.x)*pow(1.-saturate(dot(nw,eye)),5.);
 float2 ruv=float2(atan2(r.x,r.z)/6.2831853,acos(clamp(r.y,-1.,1.))/3.14159265);
 float broad=dot(room.sample(env,ruv,3,level(0.)).rgb,luma);
 float sharp=dot(room.sample(env,ruv,1,level(0.)).rgb,luma);
 float dielectric=f*mix(sharp,broad,mat.z*mat.z);
 // A native HDR pixel does not expose its individual BRDF lobes. Bound
 // the reflected energy that can escape diffuse occlusion by how much more
 // of the room the reflected lobe actually sees than the diffuse lobe.
 float nativeDiffuse=mix(1.,saturate(diffuse),mat.y);
 float spec=mix(indirect,1.,visibility.z);
 float protectedFraction=saturate((spec-nativeDiffuse)/max(.0001,1.-nativeDiffuse));
 return float4(visibility.xy,nativeDiffuse,saturate(dielectric*protectedFraction));
}
"""
