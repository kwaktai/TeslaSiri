import MetalKit
import RealityKit
import simd

/// Thin-sheet optics, evaluated only over the image bounds of the physical
/// windows. The native opaque car remains the backplate. Tints multiply the
/// actual background by channel; reflected light is added separately.
@MainActor final class StudioGlazing {
    struct Transfer {let light,pass:any MTLTexture;let region:SIMD4<Float>}
    private struct Vert {var point,normal:SIMD3<Float>;var uv:SIMD2<Float>}
    private struct Part {let v,i:any MTLBuffer;let count:Int;let local:simd_float4x4}
    private struct Draw {let part:Part,world:simd_float4x4,edge:any MTLTexture;let optics,detail:SIMD4<Float>}
    private struct Scratch {
        let opaque,z0,z1,lr,lt,r,t:any MTLTexture
    }
    private var frames=[Int:Scratch]()
    private var shapes=[ObjectIdentifier:[Part]](),edges=[URL:any MTLTexture]()
    private var lampCoverage = LampCoverage()
    private weak var active:GlazingKit?
    private let dev:any MTLDevice,loader:MTKTextureLoader
    private let peel:any MTLRenderPipelineState,opaque:any MTLRenderPipelineState
    private let collect,mirror,continuation:any MTLComputePipelineState,depth:any MTLDepthStencilState
    private let resolveLens:any MTLComputePipelineState
    private var diffuser:(url:URL,texture:any MTLTexture)?
    init(_ d:any MTLDevice,_ lib:any MTLLibrary)throws{
        dev=d;loader=MTKTextureLoader(device:d)
        let pd=MTLRenderPipelineDescriptor();pd.vertexFunction=lib.makeFunction(name:"paneSolid");pd.depthAttachmentPixelFormat = .depth32Float
        opaque=try d.makeRenderPipelineState(descriptor:pd)
        pd.vertexFunction=lib.makeFunction(name:"paneVertex");pd.fragmentFunction=lib.makeFunction(name:"paneExposure")
        pd.colorAttachments[0].pixelFormat = .rgba16Float;pd.colorAttachments[1].pixelFormat = .rgba16Float
        peel=try d.makeRenderPipelineState(descriptor:pd)
        let dd=MTLDepthStencilDescriptor();dd.depthCompareFunction = .less;dd.isDepthWriteEnabled=true
        guard let depth=d.makeDepthStencilState(descriptor:dd),let f=lib.makeFunction(name:"paneCollect"),let g=lib.makeFunction(name:"paneMirror") else{throw VehicleError.invalid("Missing glass pipeline")}
        guard let h=lib.makeFunction(name:"paneContinuation") else{throw VehicleError.invalid("Missing RGB mirror transfer")}
        self.depth=depth;collect=try d.makeComputePipelineState(function:f);mirror=try d.makeComputePipelineState(function:g)
        continuation=try d.makeComputePipelineState(function:h)
        guard let resolve=lib.makeFunction(name:"resolveLensCoverage") else{throw VehicleError.invalid("Missing lamp coverage resolve")}
        resolveLens=try d.makeComputePipelineState(function:resolve)
    }
    private func scratch(_ slot:Int,_ w:Int,_ h:Int)throws->Scratch{
        if let s=frames[slot],s.r.width==w,s.r.height==h{return s}
        func tex(_ fmt:MTLPixelFormat,_ usage:MTLTextureUsage)throws->any MTLTexture{
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:fmt,width:w,height:h,mipmapped:false)
            d.storageMode = .private;d.usage=usage
            guard let t=dev.makeTexture(descriptor:d) else{throw VehicleError.invalid("No glass layer texture")};return t
        }
        let render:MTLTextureUsage=[.shaderRead,.renderTarget],rw:MTLTextureUsage=[.shaderRead,.shaderWrite]
        let s=try Scratch(opaque:tex(.depth32Float,render),z0:tex(.depth32Float,render),z1:tex(.depth32Float,render),
                          lr:tex(.rgba16Float,render),lt:tex(.rgba16Float,render),r:tex(.rgba16Float,rw),t:tex(.rgba16Float,rw))
        frames[slot]=s;return s
    }
    private func parts(_ mesh:MeshResource)throws->[Part] {
        let key=ObjectIdentifier(mesh);if let g=shapes[key]{return g}
        var result=[Part]();let c=mesh.contents
        for model in c.models {
            let inst=c.instances.filter{$0.model==model.id}.map(\.transform)
            for part in model.parts {
                let p=part.positions.elements
                guard let n=part.normals?.elements,let uv=part.textureCoordinates?.elements,let tri=part.triangleIndices?.elements,
                      !p.isEmpty,!tri.isEmpty,n.count==p.count,uv.count==p.count else{throw VehicleError.invalid("Incomplete window mesh")}
                let v=p.indices.map{Vert(point:p[$0],normal:n[$0],uv:uv[$0])}
                guard let vb=v.withUnsafeBytes({dev.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
                      let ib=tri.withUnsafeBytes({dev.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else{throw VehicleError.invalid("Cannot buffer a window")}
                for m in inst.isEmpty ? [matrix_identity_float4x4]:inst{result.append(.init(v:vb,i:ib,count:tri.count,local:m))}
            }
        };shapes[key]=result;return result
    }
    private func compute(_ e:any MTLComputeCommandEncoder,_ p:any MTLComputePipelineState,_ w:Int,_ h:Int){
        e.setComputePipelineState(p);e.dispatchThreads(.init(width:w,height:h,depth:1),threadsPerThreadgroup:.init(width:8,height:8,depth:1));e.endEncoding()
    }
    func glass(kit:GlazingKit,radiance:StudioRadiance,panes:[GlazingKit.Mounted],backEnabled:Set<ObjectIdentifier>,params:[SIMD4<Float>],slot:Int,
               shadow:StudioShadows,field:any MTLTexture,command:any MTLCommandBuffer)throws->Transfer?{
        if active !== kit{
            shapes.removeAll();edges.removeAll();lampCoverage=LampCoverage();active=kit
        }
        let face=kit.directory.deletingLastPathComponent().appendingPathComponent("Studio/SoftboxFace.png")
        if diffuser?.url != face {
            let options:[MTKTextureLoader.Option:Any]=[.SRGB:true,.generateMipmaps:true,.origin:MTKTextureLoader.Origin.topLeft]
            diffuser=(face,try loader.newTexture(URL:face,options:options))
        }
        let maps=try radiance.glazing(using:loader)
        func xyz(_ v:SIMD4<Float>)->SIMD3<Float>{[v.x,v.y,v.z]}
        let eye=xyz(params[0]),rt=xyz(params[1]),up=xyz(params[2]),fwd=xyz(params[3])
        let size=SIMD2(params[1].w,params[2].w);var lo=size,hi=SIMD2<Float>.zero,draws=[Draw](),intersectsEye=false
        let viewport=CGRect(x:0,y:0,width:CGFloat(size.x),height:CGFloat(size.y))
        let view=simd_float4x4(columns:(SIMD4(rt,0),SIMD4(up,0),SIMD4(-fwd,0),SIMD4(eye,1))).inverse
        var lensRegions=[CGRect](),coverRects=[CGRect]()
        for window in panes {
            let matrix=window.front.transformMatrix(relativeTo:nil)
            for s in window.pieces {
                let b=s.mesh.bounds
                var near:Float = .infinity,far:Float = -.infinity,lower=size,upper=SIMD2<Float>.zero
                for x in [b.min.x,b.max.x]{for y in [b.min.y,b.max.y]{for z in [b.min.z,b.max.z]{
                    let d=xyz(matrix*SIMD4(x,y,z,1))-eye,v=simd_dot(d,fwd);near=min(near,v);far=max(far,v)
                    if v>0.025{let pt=size*0.5+SIMD2(simd_dot(d,rt),-simd_dot(d,up))*(params[0].w/v);lower=simd_min(lower,pt);upper=simd_max(upper,pt)}
                }}}
                if far<=0.035{continue};if near<0.035{intersectsEye=true}
                lo=simd_min(lo,lower);hi=simd_max(hi,upper)
                let tex:any MTLTexture, detail:SIMD4<Float>
                switch s.surface {
                case .window(_,let edge,let span):
                    if let t=edges[edge]{tex=t}else{tex=try loader.newTexture(URL:edge,options:[.SRGB:false,.generateMipmaps:true,.origin:MTKTextureLoader.Origin.topLeft]);edges[edge]=tex}
                    let back = window.back.map { backEnabled.contains(ObjectIdentifier($0)) } ?? false
                    detail = [span.x,span.y,back ? 1:0,0]
                case .lamp(let lens):
                    // The lamp shader has no perimeter ink and doesn't sample this slot.
                    tex = maps.low
                    detail = [LampLens.indexOfRefraction,lens.roughness,0,0]
                    let camera = view * matrix
                    for box in lampCoverage.clusters(of:s.mesh) {
                        if let patch=LampCoverage.patch(box,camera:camera,focal:params[0].w,viewport:viewport) {coverRects.append(patch)}
                    }
                    for box in lampCoverage.islands(of:s.mesh){
                        if let region=LampCoverage.patch(box,camera:camera,focal:params[0].w,viewport:viewport){
                            lensRegions.append(region)
                        }
                    }
                }
                for g in try parts(s.mesh){draws.append(.init(part:g,world:matrix*g.local,edge:tex,optics:s.optical,detail:detail))}
            }
        }
        if intersectsEye{lo = .zero;hi=size}
        lo=simd_max(.zero,floor(lo-2));hi=simd_min(size,ceil(hi+2))
        guard !draws.isEmpty,hi.x>lo.x,hi.y>lo.y else{return nil}
        let rect=SIMD4(lo.x,lo.y,hi.x-lo.x,hi.y-lo.y)
        func expose(_ rect:SIMD4<Float>,scale:Int,into s:Scratch,covered:SIMD4<Float>? = nil)throws {
            let w=Int(rect.z)*scale,h=Int(rect.w)*scale
            let bounds=covered ?? rect
            let left=Int(bounds.x-rect.x)*scale,top=Int(bounds.y-rect.y)*scale
            let coveredWidth=Int(bounds.z)*scale,coveredHeight=Int(bounds.w)*scale
            // Keep the original viewport and projection, including subpixel edge rounding.
            let viewport=MTLViewport(originX:0,originY:0,width:Double(w),height:Double(h),znear:0,zfar:1)
            let scissor=MTLScissorRect(x:left,y:top,width:coveredWidth,height:coveredHeight)
            var p=params+[rect]
            let solid=MTLRenderPassDescriptor();solid.depthAttachment.texture=s.opaque
            solid.renderTargetWidth=left+coveredWidth;solid.renderTargetHeight=top+coveredHeight
            solid.depthAttachment.loadAction = .clear;solid.depthAttachment.clearDepth=1;solid.depthAttachment.storeAction = .store
            guard let z=command.makeRenderCommandEncoder(descriptor:solid) else{throw VehicleError.invalid("Cannot expose pane occluders")}
            z.setRenderPipelineState(opaque);z.setDepthStencilState(depth);z.setCullMode(.none);z.setViewport(viewport);z.setScissorRect(scissor)
            p.withUnsafeBytes{z.setVertexBytes($0.baseAddress!,length:$0.count,index:2)}
            shadow.drawGlassOccluders(z);z.endEncoding()
            p.append(.zero)
            // Pixel depth order, not entity order: an open frameless door can
            // cross a fixed pane. Four layers cover both sides plus two open panes.
            for i in 0..<min(4,draws.count){
                p[16].x=Float(i)
                let pass=MTLRenderPassDescriptor();pass.depthAttachment.texture=i%2==0 ? s.z0:s.z1
                pass.renderTargetWidth=left+coveredWidth;pass.renderTargetHeight=top+coveredHeight
                pass.depthAttachment.loadAction = .clear;pass.depthAttachment.clearDepth=1;pass.depthAttachment.storeAction = .store
                for (j,t) in [s.lr,s.lt].enumerated(){
                    let a=pass.colorAttachments[j]!;a.texture=t;a.clearColor=j==0 ? .init(red:0,green:0,blue:0,alpha:0):.init(red:1,green:1,blue:1,alpha:1)
                    a.loadAction = .clear;a.storeAction = .store
                }
                guard let e=command.makeRenderCommandEncoder(descriptor:pass) else{throw VehicleError.invalid("Cannot expose glass layer")}
                e.setRenderPipelineState(peel);e.setDepthStencilState(depth);e.setCullMode(.none);e.setViewport(viewport);e.setScissorRect(scissor)
                p.withUnsafeBytes{e.setVertexBytes($0.baseAddress!,length:$0.count,index:2);e.setFragmentBytes($0.baseAddress!,length:$0.count,index:0)}
                e.setFragmentTexture(s.opaque,index:0);e.setFragmentTexture(i==0 ? s.opaque:(i%2==0 ? s.z1:s.z0),index:1)
                e.setFragmentTexture(maps.low,index:2);e.setFragmentTexture(diffuser?.texture,index:3);e.setFragmentTexture(field,index:4)
                e.setFragmentTexture(maps.high,index:6)
                for d in draws{
                    var m=d.world,optics=d.optics,detail=d.detail
                    e.setVertexBuffer(d.part.v,offset:0,index:0);e.setVertexBytes(&m,length:64,index:1)
                    e.setFragmentBytes(&optics,length:16,index:1);e.setFragmentBytes(&detail,length:16,index:2);e.setFragmentTexture(d.edge,index:5)
                    e.drawIndexedPrimitives(type:.triangle,indexCount:d.part.count,indexType:.uint32,indexBuffer:d.part.i,indexBufferOffset:0)
                }
                e.endEncoding()
                guard let c=command.makeComputeCommandEncoder() else{throw VehicleError.invalid("Cannot integrate glass")}
                for (j,t) in [s.lr,s.lt,s.r,s.t].enumerated(){c.setTexture(t,index:j)}
                var layer=SIMD4(UInt32(i),UInt32(left),UInt32(top),0)
                c.setBytes(&layer,length:16,index:0);compute(c,collect,coveredWidth,coveredHeight)
            }
        }
        let scale=slot==0 && max(size.x,size.y)<=1024 ? 2:1
        let s=try scratch(slot,Int(rect.z)*scale,Int(rect.w)*scale)
        try expose(rect,scale:scale,into:s)
        let sensor=CGRect(x:CGFloat(rect.x),y:CGFloat(rect.y),width:CGFloat(rect.z),height:CGFloat(rect.w))
        let tiles=LampCoverage.tiles(lensRegions,within:sensor)
        if !tiles.isEmpty {
            // Both camera and floor reflection reuse this scratch after each
            // local resolve. All optical layers and opaque occluders take the
            // same subpixel rays as the lamp, including a moving trunk or door.
            let lensScale=8
            let fine=try scratch(2,128*lensScale,96*lensScale)
            // Ignore tiles and pixel rows outside the conservative projections of
            // every triangle cluster. Both the coarse and 8x samples must be
            // outside the cover there, so the existing transfer is already final.
            for original in tiles {
                let tile = coverRects.reduce(CGRect.null) { bounds, patch in bounds.union(patch.intersection(original)) }
                if tile.isEmpty {continue}
                let crop=SIMD4(Float(tile.minX),Float(tile.minY),Float(tile.width),Float(tile.height))
                let projection=SIMD4(Float(original.minX),Float(original.minY),Float(original.width),Float(original.height))
                try expose(projection,scale:lensScale,into:fine,covered:crop)
                guard let c=command.makeComputeCommandEncoder() else{throw VehicleError.invalid("Cannot resolve a lamp cover")}
                for (i,t) in [fine.r,fine.t,s.r,s.t].enumerated(){c.setTexture(t,index:i)}
                var sample=SIMD4(UInt32((Int(tile.minX)-Int(rect.x))*scale),UInt32((Int(tile.minY)-Int(rect.y))*scale),UInt32(lensScale/scale),0)
                var source=SIMD2(UInt32(Int(tile.minX-original.minX)*lensScale),UInt32(Int(tile.minY-original.minY)*lensScale))
                c.setBytes(&source,length:8,index:1)
                c.setBytes(&sample,length:16,index:0);compute(c,resolveLens,Int(tile.width)*scale,Int(tile.height)*scale)
            }
        }
        return .init(light:s.r,pass:s.t,region:rect)
    }
    func applyMirror(_ glass:Transfer,to target:any MTLTexture,command:any MTLCommandBuffer)throws{
        guard let c=command.makeComputeCommandEncoder() else{throw VehicleError.invalid("Cannot reflect glass")}
        for (i,t) in [target,glass.light,glass.pass].enumerated(){c.setTexture(t,index:i)}
        var region=glass.region;c.setBytes(&region,length:16,index:0);compute(c,mirror,Int(region.z),Int(region.w))
    }
    func mirrorTransmission(_ glass:Transfer,car:any MTLTexture,into dest:any MTLTexture,command:any MTLCommandBuffer)throws{
        guard let c=command.makeComputeCommandEncoder() else{throw VehicleError.invalid("Cannot pass light through the mirror")}
        c.setTexture(car,index:0);c.setTexture(glass.pass,index:1);c.setTexture(dest,index:2)
        var region=glass.region;c.setBytes(&region,length:16,index:0);compute(c,continuation,car.width,car.height)
    }
}

let windowSource = """
float4 windowClip(float3 world,constant float4* p){
 float3 d=world-p[0].xyz;float z=dot(d,p[3].xyz);
 float2 full=float2(p[1].w,p[2].w),upper=float2(dot(d,p[1].xyz),-dot(d,p[2].xyz))*p[0].w+full*.5*z;
 float2 clip=(upper-p[15].xy*z)/p[15].zw*2.-z;return float4(clip.x,-clip.y,z-.035,z);
}
vertex float4 paneSolid(uint i [[vertex_id]],const device float3* pt [[buffer(0)]],constant float4x4& m [[buffer(1)]],constant float4* p [[buffer(2)]]){
 return windowClip((m*float4(pt[i],1)).xyz,p);
}
struct PanePt{float3 p,n;float2 uv;};
struct PaneV{float4 clip [[position]];float3 pos,n;float2 uv;};
vertex PaneV paneVertex(uint i [[vertex_id]],const device PanePt* v [[buffer(0)]],constant float4x4& m [[buffer(1)]],constant float4* p [[buffer(2)]]){
 float3 pos=(m*float4(v[i].p,1)).xyz;
 float3 n=v[i].n.x*cross(m[1].xyz,m[2].xyz)+v[i].n.y*cross(m[2].xyz,m[0].xyz)+v[i].n.z*cross(m[0].xyz,m[1].xyz);
 n*=sign(dot(m[0].xyz,cross(m[1].xyz,m[2].xyz)));
 return {windowClip(pos,p),pos,normalize(n),v[i].uv};
}
struct Sheet{half4 light [[color(0)]];half4 pass [[color(1)]];};
// Sum the internal bounces separately for each polarization. The mean
// of two geometric series is NOT the series of their mean.
void slab(float f,float3 A,thread float3& R,thread float3& T){
 float3 den=max(1.e-7,1.-f*f*A*A);
 T=(1.-f)*(1.-f)*A/den;R=f+f*A*T;
}
void paneTransport(float c,float3 normalPass,thread float3& R,thread float3& T,thread float& front,float ior=1.52){
 float ct=sqrt(1.-(1.-c*c)/(ior*ior));
 float s=(c-ior*ct)/(c+ior*ct),p=(ior*c-ct)/(ior*c+ct);
 float3 A=pow(normalPass,float3(1./ct)),rs,ts,rp,tp;
 slab(s*s,A,rs,ts);slab(p*p,A,rp,tp);
 R=.5*(rs+rp);T=.5*(ts+tp);front=.5*(s*s+p*p);
}
fragment Sheet paneExposure(PaneV v [[stage_in]],depth2d<float> solid [[texture(0)]],depth2d<float> previous [[texture(1)]],
 texture2d<float> cards [[texture(2)]],texture2d<float> lamp [[texture(3)]],texture2d<float> floorMap [[texture(4)]],texture2d<float> edge [[texture(5)]],texture2d<float> highlights [[texture(6)]],
 constant float4* p [[buffer(0)]],constant float4& spec [[buffer(1)]],constant float4& detail [[buffer(2)]]){
 uint2 pix=uint2(v.clip.xy);float z=v.clip.z;
 if(z>=solid.read(pix)+2.e-7 || (p[16].x>.5 && z<=previous.read(pix)+1.e-7))discard_fragment();
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
 constexpr sampler sky(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear,mip_filter::linear);
 float3 n=normalize(v.n),eye=normalize(p[0].xyz-v.pos);float ndv=dot(n,eye);
 bool inside=ndv<0.;if(inside && detail.z<.5)discard_fragment();
 uint role=uint(spec.w+.5);bool isLens=role==6,drop=role==1||role==2;
 float c=saturate(abs(ndv)),front;float3 R,T;paneTransport(c,spec.rgb,R,T,front,isLens?detail.x:1.52);
 float ink=0.;
 if(!isLens){
 // MeshResource retains USD V-up coordinates; the PNG and Metal loader
 // have their first row at the top. Convert once, only for the image lookup.
 float2 uv=float2(v.uv.x,1.-v.uv.y);
 float3 dist=edge.sample(s,uv).rgb*float3(.072,.18,.18);float distance=dist.x;
 float band=role==0?.024:role==3?.021:role==4?.019:.007;
 float gap=distance-band;
 // Bond beds are deeper under the cowl and the headliner than along the
 // A-posts. Both distances follow the curved source outline, not a UV box.
 if(role==0)gap=min(gap,min(dist.y-.061,dist.z-.099));
 if(role==4)gap=min(gap,min(dist.y-.036,dist.z-.048));
 float foot=max(.00020,fwidth(gap)),transition=role==0?.009:.006;
 float ceramic=1.-smoothstep(-foot,foot,gap);
 float fade=1.-smoothstep(0.,transition,gap);
 // The fired enamel fades into tiny dots. Above their Nyquist frequency,
 // use area coverage, not flickering binary dots. Movable glass has no frit.
 float2 lattice=uv*detail.xy/.0028;lattice.x+=.5*fmod(floor(lattice.y),2.);
 float rad=.46*sqrt(fade),d=length(fract(lattice)-.5),aa=clamp(max(fwidth(lattice.x),fwidth(lattice.y))*.5,.012,.45);
 float dots=mix(1.-smoothstep(rad-aa,rad+aa,d),3.14159*rad*rad,smoothstep(.16,.48,aa));
 ink=drop?0.:max(ceramic,fade*dots);
 float cut=drop?(1.-smoothstep(.0008,.0027+foot,distance)):0.;
 T*=1.-ink;T*=mix(float3(1.),float3(.40,.76,.67),cut);
 }
 float3 ray=reflect(-eye,n),factor=1./float3(6.3,4.65,7.8),x=(v.pos-float3(0,1.34,0))*factor,q=normalize(ray*factor);
 float h=dot(x,q),t=sqrt(max(.001,h*h+1.-dot(x,x)))-h;float3 dir=normalize((x+t*q)/factor);
 float2 pano=float2(atan2(dir.x,dir.z)/6.2831853,acos(clamp(dir.y,-1.,1.))/3.1415927);
 // Normal spread for a GGX receiver is proportional to squared roughness.
 // Convert the reflected angular footprint to a level in the studio panorama.
 float width=isLens?2.*detail.y*detail.y:0.;
 float lod=isLens?log2(max(1.,width*float(cards.get_width())/6.2831853)):1.;
 float3 L=4.*cards.sample(sky,pano,level(lod)).rgb+512.*highlights.sample(sky,pano,level(lod)).rgb;
 if(ray.y<-.015){
   float travel=max(0.,-v.pos.y/ray.y);float2 g=v.pos.xz+ray.xz*travel;
   float weight=smoothstep(.02,.45,-ray.y)*(1.-smoothstep(3.,13.,travel))*saturate(12.-max(abs(g.x),abs(g.y)));
   L=mix(L,floorMap.sample(s,g/24.+.5).rgb,weight);
 }
 float3 axis=normalize(cross(p[10].xyz,p[11].xyz));float side=dot(ray,axis);
 if(side>.001){
  float3 to=p[9].xyz-v.pos;float travel=dot(to,axis)/side;float3 at=ray*travel-to;
  float2 k=float2(dot(at,p[10].xyz)/p[9].w,dot(at,p[11].xyz)/p[10].w);
  // The polished sheet reflects a point on the graduated diffuser. Implicit
  // mip selection in a partially covered quad can sample the bright average
  // of the whole lamp at its black perimeter, drawing a line across the pane.
  float faceLOD=log2(max(1.,width*travel*float(lamp.get_width())/(2.*max(.001,min(p[9].w,p[10].w)))));
  if(all(abs(k)<1.)&&travel>0.)L+=p[11].w*p[12].rgb*lamp.sample(s,.5+k*float2(.5,-.5),level(faceLOD)).rgb;
 }
 if(inside)L=p[4].yzw*.025; // diffuse approximation to the opposite cabin hemisphere
 float3 specular=L*mix(R,float3(front),ink);
 float3 back=p[4].yzw*.008*ink*(1.-front);
 return {half4(half3(specular+back),half(isLens)),half4(half3(T),1)};
}
kernel void paneCollect(texture2d<half,access::read> r [[texture(0)]],texture2d<half,access::read> t [[texture(1)]],
 texture2d<half,access::read_write> sum [[texture(2)]],texture2d<half,access::read_write> through [[texture(3)]],
 constant uint4 &dispatch [[buffer(0)]],uint2 local [[thread_position_in_grid]]){
 uint layer=dispatch.x;uint2 xy=local+dispatch.yz;
 if(any(xy>=uint2(r.get_width(),r.get_height())))return;
 float3 prev=layer?float3(through.read(xy).rgb):float3(1.);
 float3 light=layer?float3(sum.read(xy).rgb):float3(0.);
 half mask=max(layer?sum.read(xy).a:half(0),r.read(xy).a);
 sum.write(half4(half3(light+prev*float3(r.read(xy).rgb)),mask),xy);through.write(half4(half3(prev*float3(t.read(xy).rgb)),1),xy);
}
kernel void resolveLensCoverage(texture2d<half,access::read> fineR [[texture(0)]],texture2d<half,access::read> fineT [[texture(1)]],
 texture2d<half,access::read_write> light [[texture(2)]],texture2d<half,access::write> pass [[texture(3)]],
 constant uint4& sample [[buffer(0)]],constant uint2& source [[buffer(1)]],uint2 q [[thread_position_in_grid]]){
 uint2 dest=sample.xy+q;uint n=sample.z;float3 r=0.,t=0.;bool covered=light.read(dest).a>0.;
 for(uint y=0;y<n;y++){for(uint x=0;x<n;x++){
  uint2 sub=source+q*n+uint2(x,y);half4 l=fineR.read(sub);covered|=l.a>0.;
  r+=float3(l.rgb);t+=float3(fineT.read(sub).rgb);
 }}
 // Preserve every existing windscreen and body sample outside the cover.
 if(covered){light.write(half4(half3(r/float(n*n)),1),dest);pass.write(half4(half3(t/float(n*n)),1),dest);}
}
kernel void paneMirror(texture2d<half,access::read_write> scene [[texture(0)]],texture2d<float> r [[texture(1)]],texture2d<float> t [[texture(2)]],
 constant float4& region [[buffer(0)]],uint2 q [[thread_position_in_grid]]){
 if(any(q>=uint2(region.zw)))return;uint2 xy=q+uint2(region.xy);float4 car=float4(scene.read(xy));float2 uv=(float2(q)+.5)/region.zw;
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);float3 pass=t.sample(s,uv,level(0)).rgb;
 scene.write(half4(half3(r.sample(s,uv,level(0)).rgb+car.rgb*pass),half(1.-(1.-car.a)*dot(pass,float3(.2126,.7152,.0722)))),xy);
}
kernel void paneContinuation(texture2d<half,access::read> car [[texture(0)]],texture2d<float> t [[texture(1)]],texture2d<half,access::write> dest [[texture(2)]],
 constant float4& region [[buffer(0)]],uint2 xy [[thread_position_in_grid]]){
 if(any(xy>=uint2(car.get_width(),car.get_height())))return;
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 st=(float2(xy)+.5-region.xy)/region.zw;
 float3 remaining=all(st>=0.)&&all(st<=1.)?t.sample(s,st,level(0.)).rgb:float3(1.);
 dest.write(half4(half3((1.-float(car.read(xy).a))*remaining),1),xy);
}
"""
