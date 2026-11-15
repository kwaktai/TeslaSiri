import Foundation
import Metal
import RealityKit
import simd

/// Shared triangle representation. Native Metal instances and the portable
/// stackless Metal BVH address precisely the same primitive and material.
@MainActor final class CoatGeometry {
    struct Vertex{var p,n:SIMD4<Float>} // object position/normal, factory UV in w
    struct Bounds{
        var lo=SIMD3<Float>(repeating:.infinity),hi=SIMD3<Float>(repeating: -.infinity)
        mutating func include(_ p:SIMD3<Float>){lo=simd_min(lo,p);hi=simd_max(hi,p)}
        mutating func include(_ b:Bounds){include(b.lo);include(b.hi)}
        func transformed(_ m:simd_float4x4)->Bounds{
            let c=(lo+hi)*0.5,e=(hi-lo)*0.5,v=m*SIMD4(c,1)
            let r=abs(m.columns.0)*e.x+abs(m.columns.1)*e.y+abs(m.columns.2)*e.z
            return Bounds(lo:SIMD3(v.x-r.x,v.y-r.y,v.z-r.z),hi:SIMD3(v.x+r.x,v.y+r.y,v.z+r.z))
        }
    }
    struct Node{var lo,hi:SIMD4<Float>;var link:SIMD4<UInt32>}
    struct Instance{var m,inv:simd_float4x4;var ids:SIMD4<UInt32>,base,extra:SIMD4<Float>}
    struct Part{let root,first,count:Int;let bounds:Bounds}
    struct Placement{let part,material:Int;let local:simd_float4x4}
    private struct Bind{let mesh:MeshResource;let placements:[Placement]}
    struct Palette:Decodable{
        struct Entry:Decodable{
            let rgb:SIMD3<Float>,rough,metal:Float
            let tile:Int,propertyTile,exteriorBaseTile,opacityTile:Int?
            let accentOnly:Bool?,opacity:Float?
        }
        let columns,rows:Int,exteriorTileSpan:Int?,materials:[String:Entry]
    }
    private struct Item{let part:Int;let data:Instance;let bounds:Bounds}
    private var cpuV=[Vertex](),cpuI=[UInt32](),cpuN=[Node](),cached=[ObjectIdentifier:Bind]()
    private(set) var parts=[Part](),instances=[Instance](),partIDs=[Int]()
    private(set) var vb,ib,nb,top,inst:(any MTLBuffer)?
    private(set) var bottomAS=[any MTLAccelerationStructure](),sceneAS:(any MTLAccelerationStructure)?
    let device:any MTLDevice,palette:Palette
    init(_ d:any MTLDevice,dir:URL)throws{
        device=d;palette=try JSONDecoder().decode(Palette.self,from:Data(contentsOf:dir.appendingPathComponent("BounceMaterials.json")))
    }
    private func buffer<T>(_ v:[T])throws->any MTLBuffer{
        guard !v.isEmpty,let b=v.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}) else{throw VehicleError.invalid("Cannot allocate ray geometry")};return b
    }
    private func node(_ b:Bounds,_ end:Int,_ first:Int=0,_ count:Int=0)->Node{
        Node(lo:SIMD4(b.lo-0.00002,0),hi:SIMD4(b.hi+0.00002,0),link:[UInt32(end),UInt32(first),UInt32(count),0])
    }
    private func place(_ mesh:MeshResource)throws->[Placement]{
        let id=ObjectIdentifier(mesh);if let b=cached[id]{return b.placements}
        let contents=mesh.contents;var all=[Placement]()
        func expand(_ x:UInt32)->UInt32{
            var v=x&1023;v=(v|(v<<16))&0x030000ff;v=(v|(v<<8))&0x0300f00f
            v=(v|(v<<4))&0x030c30c3;return (v|(v<<2))&0x09249249
        }
        for model in contents.models{
            let xf=contents.instances.filter{$0.model==model.id}.map(\.transform)
            for p in model.parts{
                guard let idx=p.triangleIndices?.elements,idx.count>=3 else{continue}
                // On split Palladium accents AO is the only varying input;
                // the asset bank places its authored st1 in both UV sets.
                let pos=p.positions.elements,norm=p.normals?.elements,uv=p.textureCoordinates?.elements
                let count=idx.count/3,offset=UInt32(cpuV.count);var bounds=Bounds()
                for j in pos.indices{let v=pos[j],n=norm?[j] ?? SIMD3(0,1,0),t=uv?[j] ?? .zero
                    cpuV.append(.init(p:SIMD4(v,t.x),n:SIMD4(n,t.y)));bounds.include(v)}
                let extent=simd_max(bounds.hi-bounds.lo,SIMD3(repeating:0.000001))
                var keys=[UInt64]();keys.reserveCapacity(count)
                for i in 0..<count{
                    let c=(pos[Int(idx[3*i])]+pos[Int(idx[3*i+1])]+pos[Int(idx[3*i+2])])/3
                    let q=simd_clamp((c-bounds.lo)/extent, .zero, .one)*1023
                    let code=expand(UInt32(q.x))|(expand(UInt32(q.y))<<1)|(expand(UInt32(q.z))<<2)
                    keys.append(UInt64(code)<<32|UInt64(i))
                }
                keys.sort();let first=cpuI.count/3
                for key in keys{let i=3*Int(UInt32(truncatingIfNeeded:key));cpuI.append(offset+idx[i]);cpuI.append(offset+idx[i+1]);cpuI.append(offset+idx[i+2])}
                func tree(_ l:Int,_ h:Int)->Bounds{
                    let here=cpuN.count;cpuN.append(node(bounds,0));var b=Bounds()
                    if h-l<=6{
                        for j in l..<h{
                            let base=Int(UInt32(truncatingIfNeeded:keys[j]))*3
                            for k in base..<base+3{b.include(pos[Int(idx[k])])}
                        };cpuN[here]=node(b,cpuN.count,first+l,h-l)
                    }else{
                        let xor=keys[l]^keys[h-1],bit=UInt64(1)<<(63-xor.leadingZeroBitCount)
                        var mid=(l+h)/2
                        if bit>0xffffffff{var a=l+1,e=h-1;while a<e{let m=(a+e)/2;if (keys[m]&bit)==0{a=m+1}else{e=m}};mid=a}
                        b=tree(l,mid);b.include(tree(mid,h));cpuN[here]=node(b,cpuN.count)
                    };return b
                }
                let root=cpuN.count,box=tree(0,count),i=parts.count
                parts.append(.init(root:root,first:first,count:count,bounds:box))
                for m in xf.isEmpty ? [matrix_identity_float4x4]:xf{all.append(.init(part:i,material:p.materialIndex,local:m))}
            }
        }
        cached[id]=Bind(mesh:mesh,placements:all);return all
    }
    private func nativeBuild(_ desc:MTLAccelerationStructureDescriptor,_ cmd:any MTLCommandBuffer)throws->any MTLAccelerationStructure{
        let sizes=device.accelerationStructureSizes(descriptor:desc)
        guard let acc=device.makeAccelerationStructure(size:sizes.accelerationStructureSize),
              let tmp=device.makeBuffer(length:max(256,sizes.buildScratchBufferSize),options:.storageModePrivate),
              let enc=cmd.makeAccelerationStructureCommandEncoder() else{throw VehicleError.invalid("Cannot build Metal triangle acceleration")}
        enc.build(accelerationStructure:acc,descriptor:desc,scratchBuffer:tmp,scratchBufferOffset:0);enc.endEncoding();return acc
    }
    func update(_ car:VehicleScene,_ cmd:any MTLCommandBuffer,native:Bool)throws {
        guard let rig=car.photo else{throw VehicleError.invalid("Missing paint bindings")}
        let tags=rig.finishDraws(),panes=rig.mountedPanes(),paneIDs=Set(panes.map{ObjectIdentifier($0.front)})
        var list=[(String,Item)]();let initial=parts.count
        func add(_ mesh:MeshResource,_ world:simd_float4x4,_ key:String,_ type:UInt32,_ matte:Float,_ tint:SIMD3<Float>?,_ name:String,_ mats:[any Material],accent:Bool=false,scaledHardware:Bool=false)throws{
            for (j,x) in try place(mesh).enumerated(){
                let part=parts[x.part],m=world*x.local
                guard abs(simd_determinant(m))>1e-11 else{continue}
                let src=mats.indices.contains(x.material) ? mats[x.material].name:nil
                let material=palette.materials[name] ?? src.flatMap{palette.materials[$0]}
                let defaultColor:SIMD3<Float>=name.lowercased().contains("bright") ? [0.53,0.55,0.57]:[0.045,0.049,0.053]
                let b=tint ?? material?.rgb ?? defaultColor
                let usesFinish = type == 0 && (accent || material?.accentOnly != true)
                let properties = usesFinish ? material?.propertyTile : nil
                let albedo = properties == nil ? material?.tile : material?.exteriorBaseTile
                let opacity = material?.opacityTile.map { -Float($0 + 1) } ?? material?.opacity ?? 1
                var metal = properties == nil ? (material?.metal ?? 0) : 1
                var roughnessScale = properties == nil ? matte : 1
                if scaledHardware, properties != nil, mats.indices.contains(x.material),
                   let native = mats[x.material] as? PhysicallyBasedMaterial {
                    metal = native.metallic.scale
                    roughnessScale = native.roughness.scale
                }
                // Zero in w retains the scalar shading of existing archives.
                let data=Instance(m:m,inv:m.inverse,ids:[UInt32(part.root),UInt32(part.first),type,UInt32(x.part)],
                                  base:SIMD4(b,properties == nil ? (material?.rough ?? 0.5) : opacity),
                                  extra:[metal,Float(albedo ?? -1),roughnessScale,Float((properties ?? -1) + 1)])
                list.append((key+"#\(j)",Item(part:x.part,data:data,bounds:part.bounds.transformed(m))))
            }
        }
        func walk(_ e:Entity,_ path:String)throws{
            guard e.isEnabled else{return}
            let id=ObjectIdentifier(e)
            if paneIDs.contains(id){return}
            if let m=e.components[ModelComponent.self]{
                let mat=m.materials.first
                // The window surround and seal keep the parent's UVs and
                // finish when separated from the main exterior mesh.
                let accent = e.name.hasPrefix("WindowAccent_"), hardware = e.name.hasPrefix("ExteriorHardware_")
                let drawName = accent || hardware ? (e.parent?.name ?? e.name) : e.name
                let prefix = "NorthlightSurface_"
                let name = drawName.hasPrefix(prefix) ? String(drawName.dropFirst(prefix.count)) : (mat?.name ?? e.name)
                let s=(e.name+" "+name).lowercased()
                let t=tags[id] ?? (0,0)
                let skip=["glass_interior","beam","projection","glow","shadow","groundplane"].contains(where:s.contains)
                if !skip{try add(m.mesh,e.transformMatrix(relativeTo:nil),path,t.0,t.1,nil,name,m.materials,
                                 accent:accent,scaledHardware:hardware)}
            }
            for c in e.children{try walk(c,path+"/"+c.name)}
        }
        try walk(car.body,"Body")
        for (n,p) in panes.enumerated(){for (j,g) in p.pieces.enumerated(){
            let s=g.optical;try add(g.mesh,p.front.transformMatrix(relativeTo:nil),"Pane\(n)/\(j)",3,0,[s.x,s.y,s.z],"Pane",[])
        }}
        guard !list.isEmpty else{throw VehicleError.invalid("No ray instances")};list.sort{$0.0<$1.0}
        let items=list.map(\.1),next=items.map(\.data),ids=items.map(\.part)
        let same=initial==parts.count && ids==partIDs && zip(next,instances).allSatisfy{$0.m==$1.m && $0.ids==$1.ids && $0.base==$1.base && $0.extra==$1.extra}
        if same,inst != nil,(!native || sceneAS != nil){return}
        if vb==nil || initial != parts.count{vb=try buffer(cpuV);ib=try buffer(cpuI);nb=try buffer(cpuN);sceneAS=nil}
        var nodes=[Node]()
        func upper(_ indices:[Int]){
            var box=Bounds();for i in indices{box.include(items[i].bounds)}
            let here=nodes.count;nodes.append(node(box,here+1))
            if indices.count==1{nodes[here]=node(box,here+1,indices[0],1);return}
            let e=box.hi-box.lo,axis=e.x>e.y && e.x>e.z ? 0:(e.y>e.z ? 1:2)
            let order=indices.sorted{a,b in let x=items[a].bounds,y=items[b].bounds;return x.lo[axis]+x.hi[axis]<y.lo[axis]+y.hi[axis]}
            let mid=order.count/2;upper(Array(order[..<mid]));upper(Array(order[mid...]));nodes[here]=node(box,nodes.count)
        }
        upper(Array(items.indices));top=try buffer(nodes);inst=try buffer(next);instances=next;partIDs=ids
        sceneAS=nil
        if native {
            if bottomAS.count<parts.count{for p in parts.dropFirst(bottomAS.count){
                let tri=MTLAccelerationStructureTriangleGeometryDescriptor();tri.vertexBuffer=vb;tri.vertexStride=MemoryLayout<Vertex>.stride
                tri.indexBuffer=ib;tri.indexBufferOffset=p.first*12;tri.indexType = .uint32;tri.triangleCount=p.count;tri.opaque=true
                let desc=MTLPrimitiveAccelerationStructureDescriptor();desc.geometryDescriptors=[tri]
                bottomAS.append(try nativeBuild(desc,cmd))
            }}
            var raw=[UInt32]();raw.reserveCapacity(next.count*16)
            for (j,t) in next.enumerated(){
                for k in 0..<4{let c=t.m[k];raw.append(contentsOf:[c.x.bitPattern,c.y.bitPattern,c.z.bitPattern])}
                raw.append(contentsOf:[UInt32(MTLAccelerationStructureInstanceOptions.opaque.rawValue),255,0,UInt32(ids[j])])
            }
            let desc=MTLInstanceAccelerationStructureDescriptor();desc.instancedAccelerationStructures=bottomAS
            desc.instanceDescriptorBuffer=try buffer(raw);desc.instanceDescriptorStride=64;desc.instanceCount=next.count
            sceneAS=try nativeBuild(desc,cmd)
        }
    }
    var triangles:Int{partIDs.reduce(0){$0+parts[$1].count}}
    var topCount:UInt32{UInt32((top?.length ?? 0)/MemoryLayout<Node>.stride)}
}
