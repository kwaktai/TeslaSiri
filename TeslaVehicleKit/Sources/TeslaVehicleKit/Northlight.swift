import CoreGraphics
import Foundation
import ImageIO
import RealityKit
#if os(macOS)
import AppKit
private typealias StudioColor = NSColor
#else
import UIKit
private typealias StudioColor = UIColor
#endif

/// Classic reproduces the app-style studio. Northlight is an independent,
/// photographic art direction, not a different trim level or a Tesla preset.
public enum VehicleLook: String, CaseIterable, Sendable { case northlight, classic }

struct NorthlightFinish {
    let binder: SIMD3<Float>
    let flake: SIMD3<Float>
    let metal, rough: Float
    let normalReflectance: Float?
    var family: Float = 4
    private(set) var referenceFlakeCoverage: Float?

    private init(binder: SIMD3<Float>, flake: SIMD3<Float>, metal: Float, rough: Float, normalReflectance: Float? = nil) {
        self.binder = binder
        self.flake = flake
        self.metal = 0.65 * min(1, max(0, metal))
        self.rough = Self.coatRoughness(rough)
        self.normalReflectance = normalReflectance
    }

    static func coatRoughness(_ source: Float) -> Float {
        0.24 + 0.30 * min(1, max(0, source))
    }

    private static func decodeSRGB(_ s: Float) -> Float {
        s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    init(rgb: UInt32, metal: Float, rough: Float) {
        func channel(_ shift: Int) -> Float {
            Self.decodeSRGB(Float((rgb >> shift) & 255) / 255)
        }
        let pigment = SIMD3(channel(16), channel(8), channel(0))
        self.init(binder: pigment, flake: pigment, metal: metal, rough: rough)
    }

    static func sourceResponse(name: String, source: VehicleLibrary.Paint) throws
        -> (pigment: SIMD3<Float>, neutral: Float, linearSourceColor: SIMD3<Float>) {
        let digits = source.color.dropFirst()
        guard source.color.first == "#", digits.count == 6, let raw = UInt32(digits, radix: 16) else {
            throw VehicleError.invalid("Invalid paint preset " + name)
        }
        func channel(_ shift: Int) -> Float { Float((raw >> shift) & 255) / 255 }
        // Meter the original material head-on under a uniform middle-gray sky.
        // Drive uses 4x sky and 4x ambient in the GLES2 display-space sum.
        // A second reading with zero pigment isolates the neutral reflection.
        func meter(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            let weight = StudioPaint.response(rgb: rgb, metallic: source.metallic, roughness: source.roughness, cosine: 1)
            let display = simd_clamp((4 * 118 / Float(255)) * (weight.specular + 4 * weight.diffuse), .zero, .one)
            return [Self.decodeSRGB(display.x), Self.decodeSRGB(display.y), Self.decodeSRGB(display.z)]
        }
        let rgb = SIMD3(channel(16), channel(8), channel(0))
        let neutral = meter(.zero).x
        let total = meter(rgb)
        let substrate = simd_clamp((total - SIMD3(repeating: neutral)) / (1 - neutral), .zero, .one)
        return (substrate, neutral, [Self.decodeSRGB(rgb.x), Self.decodeSRGB(rgb.y), Self.decodeSRGB(rgb.z)])
    }

    init(name: String, source: VehicleLibrary.Paint) throws {
        let response = try Self.sourceResponse(name: name, source: source)
        switch name {
        case "Black", "SolidBlack", "DiamondBlack", "MetallicBlack":
            // The mobile zero-pigment coupon includes its display transform.
            // On black it reaches white before grazing and nearly vanishes
            // head-on. PBSB is solid, though its mobile preset sets metal=1.
            // Use the decoded paint color for that diffuse basecoat. PX02 and
            // PMBL retain the source-metered metallic return under the varnish.
            let metallic = name == "DiamondBlack" || name == "MetallicBlack"
            let substrate = metallic ? response.pigment : response.linearSourceColor
            self.init(binder: substrate, flake: substrate, metal: source.metallic, rough: source.roughness)
            family = metallic ? 1 : 0
            referenceFlakeCoverage = metallic ? 0.32 + 0.54 * min(1, max(0, source.metallic)) : 0
            return
        default:
            break
        }
        // Linear-light gains on the diffuse color coat and the colored flake
        // return. The independent comparison uses paint-only patches in the
        // factory configurator and a daylight photograph of both blues.
        let binderGain, flakeGain: SIMD3<Float>
        switch name {
        case "DeepBlue":
            binderGain = [1, 0.985, 1.049]
            flakeGain = [1, 1.362, 0.970]
        case "FrostBlue":
            binderGain = [0.675, 0.915, 1.173]
            flakeGain = [2.258, 2.376, 2.249]
        case "Quicksilver":
            binderGain = [0.73, 0.66, 0.57]
            flakeGain = [0.95, 0.87, 0.68]
        case "UltraRed":
            binderGain = [0.30, 1, 0.24]
            flakeGain = [0.85, 1, 0.02]
        case "StealthGrey":
            binderGain = [0.70, 0.56, 0.54]
            flakeGain = [1.10, 0.96, 0.95]
        default:
            binderGain = .one
            flakeGain = .one
        }
        self.init(binder: simd_min(.one, response.pigment * binderGain),
                  flake: simd_min(.one, response.pigment * flakeGain),
                  metal: source.metallic, rough: source.roughness, normalReflectance: response.neutral)
        switch name {
        case "White": family = 0
        case "PearlWhite", "Pearl": family = 2
        case "UltraRed", "Red", "RedMulticoat", "MidnightCherryRed", "GarnetRed", "SigRed": family = 3
        default: family = 1
        }
        if binderGain != .one || flakeGain != .one {
            referenceFlakeCoverage = family == 3 ? 0.53 : 0.32 + 0.54 * min(1, max(0, source.metallic))
        }
    }

    var tint: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                components: [CGFloat(binder.x), CGFloat(binder.y), CGFloat(binder.z), 1])!
    }
}

private func swatch(_ value:UInt32)->StudioColor {
    StudioColor(red:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)
}

@MainActor final class Northlight {
    private(set) var environment:EnvironmentResource?
    private(set) var location:VehicleLocation?
    private(set) var lamp:PhotographicLight?
    private(set) var source:VehicleLibrary.PhotographicSource?
    private(set) var lightingRevision:UInt64=0
    private var groundLight:TextureResource?
    let subject:CameraSubject
    private let seatNormal:TextureResource
    private var hardware:[String:VehicleLibrary.HardwareMaps]
    func hasAuthoredExteriorMaps(_ sourceName:String)->Bool { hardware[sourceName]?.authoredExterior == true }
    func include(_ extra:[String:VehicleLibrary.HardwareMaps]){hardware.merge(extra){a,_ in a}}
    let key=DirectionalLight()
    let panels:[String:MeshResource]
    private let paint:Set<String>
    private let factoryNames:[String:String]
    private let mounts:[String]
    private var originals=[String:(model:ModelComponent,draw:Entity)]()
    private var polishedTrim = [String: (draw: Entity, finish: PhysicallyBasedMaterial)]()
    private var lampLenses = [String:GlazingKit.Piece]()
    private var optical=[String:ShaderGraphMaterial](), opticalPath=[String:String]()
    private var inside=[String:ShaderGraphMaterial]()
    private var kinds=[String:String](),occlusion=[String:TextureResource]()
    private var lacquer=Set<String>()
    private let model:String
    let glazing:GlazingKit?
    let studioDirectory:URL
    private(set) var localFloor=true
    private var coatReceiverCaptures = 0
    private let opaqueBlack = UnlitMaterial(color: .black)

    private func isMetalShaded(_ group: String) -> Bool {
        kinds[group] == "Lacquer" || kinds[group] == "Brushed"
    }

    // The native MSAA resolve must carry only the radiance of the hardware
    // visible between painted samples. Keep the exact coat mesh and its depth.
    private func nativeMaterial(_ graph: ShaderGraphMaterial, group: String) -> any Material {
        guard coatReceiverCaptures > 0, isMetalShaded(group) else { return graph }
        var receiver = opaqueBlack
        receiver.faceCulling = graph.faceCulling
        return receiver
    }

    func beginCoatReceiver() {
        coatReceiverCaptures += 1
        if coatReceiverCaptures == 1 { rebindOptics(coatsOnly: true) }
    }

    func endCoatReceiver() {
        coatReceiverCaptures -= 1
        // Restore the current finish, including recolors made during capture.
        if coatReceiverCaptures == 0 { rebindOptics(coatsOnly: true) }
    }

    func registerPolishedTrim(_ draw: Entity, material: PhysicallyBasedMaterial, at path: String) {
        polishedTrim[path] = (draw, material)
        if coatReceiverCaptures > 0 { setPolishedReceiver(on: draw, finish: material) }
    }

    private func setPolishedReceiver(on draw: Entity, finish: PhysicallyBasedMaterial) {
        guard var model = draw.components[ModelComponent.self] else { return }
        var receiver = opaqueBlack
        receiver.faceCulling = finish.faceCulling
        model.materials[0] = coatReceiverCaptures > 0 ? receiver : finish
        draw.components.set(model)
    }

    func finishDraws()->[ObjectIdentifier:(UInt32,Float)] {
        var ids=[ObjectIdentifier:(UInt32,Float)]()
        for (path,group) in opticalPath{
            if let draw=originals[path]?.draw,let kind=kinds[group],isMetalShaded(group){
                ids[ObjectIdentifier(draw)]=(kind=="Lacquer" ? 1:2,group.lowercased().contains("rough") ? 1:0)
            }
        }
        for item in polishedTrim.values { ids[ObjectIdentifier(item.draw)] = (4, 0) }
        return ids
    }
    func mountedPanes()->[GlazingKit.Mounted] {
        guard let glazing else{return []}
        let windows:[GlazingKit.Mounted] = glazing.panes.keys.sorted().compactMap{path in
            guard let front=originals[path]?.draw,front.isEnabledInHierarchy,
                  let back=front.children.first(where:{$0.name=="Glass_Interior_Transmission"}) else{return nil}
            return .init(front:front,back:back,pieces:glazing.panes[path]!)
        }
        return windows + lampLenses.keys.sorted().compactMap { path in
            guard let front = originals[path]?.draw, front.isEnabledInHierarchy,
                  let piece = lampLenses[path] else { return nil }
            return .init(front: front, back: nil, pieces: [piece])
        }
    }
    init(car:VehicleScene,library:VehicleLibrary) async throws {
        studioDirectory=library.studioDirectory
        glazing=FileManager.default.fileExists(atPath:car.directory.appendingPathComponent("Glazing.json").path)
            ? try await GlazingKit(fleet:library.directory,car:car):nil
        subject=try JSONDecoder().decode(CameraSubject.self,from:Data(contentsOf:car.directory.appendingPathComponent("Subject.json")))
        seatNormal=try await library.upholstery()
        hardware=try await library.studioHardware(in:car.body,originalMaterials:car.originalParkedMaterials)
        guard [subject.body,subject.cabin].allSatisfy({$0.count>=4 && $0.allSatisfy{p in p.x.isFinite && p.y.isFinite && p.z.isFinite}}) else {throw VehicleError.invalid("Invalid subject framing hull")}
        key.name="Photographic key"
        key.light.color=swatch(0xfff3e5)
        var shadow=DirectionalLightComponent.Shadow()
        shadow.shadowProjection = .fixed(zNear:0.1,zFar:31,orthographicScale:car.manifest.model=="semi" ? 12:8)
        shadow.depthBias=1.0;key.shadow=shadow
        let names=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:car.directory.appendingPathComponent("Northlight.json")))
        let bank=try await Entity(contentsOf:library.directory.appendingPathComponent("Northlight/\(car.manifest.model).usdc"))
        var meshes=[String:MeshResource]()
        for (path,name) in names {
            guard car.node(at:path)?.components[ModelComponent.self] != nil,
                  let mesh=bank.findEntity(named:name)?.components[ModelComponent.self]?.mesh else{throw VehicleError.invalid("Missing refined panel: \(path)")}
            meshes[path]=mesh
        }
        panels=meshes;paint=Set(car.manifest.paintSurfaces);model=car.manifest.model
        factoryNames=Dictionary(uniqueKeysWithValues:car.manifest.paintSurfaces.compactMap{path in car.factoryPaintName(at:path).map{(path,$0)}})
        mounts=car.manifest.wheelMounts.map{$0.socket+"/"+$0.child+"/"}
        let dir=library.directory.appendingPathComponent("Northlight/Studio")
        let baked=car.directory.appendingPathComponent("Parked")
        if let shader=car.manifest.rig.parked?.shader{
            for (group,paths) in shader.bindings{
                let n=group.lowercased(),kind:String
                if (shader.paintGraphs ?? []).contains(group){kind="Lacquer";lacquer.insert(group)}
                else if model=="cybertruck" && n.hasPrefix("paintmix"){kind="Brushed"}
                else if n.contains("glass") && !n.contains("interior"){kind=n.contains("tint") || n.contains("dark") || n.contains("top") ? "Privacy":"Glazing"}
                else{continue}
                kinds[group]=kind
                if kind=="Lacquer" || kind=="Brushed"{
                    let file=baked.appendingPathComponent(group+"AO.png")
                    occlusion[group]=try await TextureResource(contentsOf:FileManager.default.fileExists(atPath:file.path) ? file:dir.appendingPathComponent("White.png"),options:.init(semantic:.raw))
                }
                for path in paths{opticalPath[path]=group}
            }
        }
        // The structural stainless above the beltline has a different source
        // material from the seven PaintMix skins. It is the same bare metal,
        // not a white-painted roof. Keep the original rough vs finished groups.
        if model=="cybertruck" {
            func mapSteel(_ entity:Entity,_ path:String){
                if let name=car.portableMaterialName(at:path),
                   name.lowercased().hasPrefix("stainless_steel"),opticalPath[path]==nil {
                    kinds[name]="Brushed";opticalPath[path]=name
                }
                for child in entity.children{mapSteel(child,path+"/"+child.name)}
            }
            mapSteel(car.body,"Body")
        }
        // The mobile parked graph omits the door returns, jambs and roof
        // fade skins. They are still factory paint slots. Bind them to the
        // same transport, with a wider lobe for the authored rough surfaces.
        for path in paint where opticalPath[path]==nil{
            guard let name=factoryNames[path] else{throw VehicleError.invalid("Unidentified finish at \(path)")}
            let group="Factory_"+name;kinds[group]=model=="cybertruck" ? "Brushed":"Lacquer"
            if model != "cybertruck"{lacquer.insert(group)}
            opticalPath[path]=group
        }
    }
    func illuminate(_ site:VehicleLocation,source:VehicleLibrary.PhotographicSource,finish:NorthlightFinish?,angle:VehicleKeyLight) throws {
        var materials=[String:ShaderGraphMaterial]()
        for (group,kind) in kinds {
            guard var g=source.templates[kind] else{throw VehicleError.invalid("Missing \(kind) at \(site.rawValue)")}
            if kind=="Glazing" || kind=="Privacy"{g.faceCulling = .back;g.writesDepth=false;g.readsDepth=true}
            if kind=="Brushed",g.parameterNames.contains("SheetFinish"){
                try g.setParameter(name:"SheetFinish",value:.float(group.lowercased().contains("rough") ? 0.87:0.32))
            }
            if kind=="Lacquer"{try g.setParameter(name:"Matte",value:.float(group.lowercased().contains("rough") ? 1:0))}
            if let ao=occlusion[group]{try g.setParameter(name:"Occlusion",value:.textureResource(ao))}
            materials[group]=g
        }
        let light=PhotographicLight(angle,subject:subject,meter:source.meter)
        let updated=try lit(pigmented(materials,finish),by:light)
        inside=["Glazing":source.templates["InsideGlass"],"Privacy":source.templates["InsidePrivacy"]].compactMapValues{$0}
        optical=updated
        groundLight=nil
        self.source=source
        install(light,at:site,angle:angle,source:source)
    }
    func setEmitter(_ site:VehicleLocation,angle:VehicleKeyLight)throws{
        guard let source else{throw VehicleError.invalid("Missing studio illumination")}
        let light=PhotographicLight(angle,subject:subject,meter:source.meter)
        optical=try lit(optical,by:light)
        groundLight=nil
        install(light,at:site,angle:angle,source:source)
    }
    private func lit(_ materials:[String:ShaderGraphMaterial],by light:PhotographicLight)throws -> [String:ShaderGraphMaterial] {
        var updated=materials
        for (group,var graph) in updated {
            for (name,v) in [("LightCenter",light.center),("LightU",light.u),("LightV",light.v),("LightAxis",light.axis),
                             ("LightSize",SIMD3(light.width,light.height,light.power)),("LightColor",light.color)]{
                try graph.setParameter(name:name,value:.simd3Float(v))
            }
            // A handoff can precede the next GPU frame. Until the new ground
            // exposure is ready, reflect this rig's baked floor.
            if graph.parameterNames.contains("GroundEnabled"){try graph.setParameter(name:"GroundEnabled",value:.float(0))}
            updated[group]=graph
        }
        return updated
    }
    private func install(_ light:PhotographicLight,at site:VehicleLocation,angle:VehicleKeyLight,source:VehicleLibrary.PhotographicSource) {
        lamp=light;location=site;lightingRevision &+= 1
        // No point-sized sun alongside the softbox. Native wheels, trim and
        // the paint base all see the same extended luminous area.
        environment=source.areaLights[angle] ?? source.env
        key.isEnabled=source.areaLights.isEmpty;key.light.intensity=source.areaLights.isEmpty ? site.lux:0
        key.light.color=StudioColor(red:CGFloat(light.color.x),green:CGFloat(light.color.y),blue:CGFloat(light.color.z),alpha:1)
        key.look(at:light.target,from:light.center,relativeTo:nil)
    }
    func meter(_ site:VehicleLocation){key.light.intensity=source?.areaLights.isEmpty==true ? site.lux:0;location=site}
    func attachGround(_ texture:TextureResource)throws{
        guard groundLight !== texture else{return}
        var updated=optical
        for (group,var graph) in optical{
            try graph.setParameter(name:"GroundLight",value:.textureResource(texture))
            try graph.setParameter(name:"GroundEnabled",value:.float(localFloor ? 1:0));updated[group]=graph
        }
        optical=updated;groundLight=texture;rebindOptics()
    }
    func inspectGround(_ on:Bool)throws{
        var updated=optical
        for (group,var g) in optical{try g.setParameter(name:"GroundEnabled",value:.float(on && groundLight != nil ? 1:0));updated[group]=g}
        optical=updated;localFloor=on;rebindOptics()
    }
    // Only the drawings whose shader contains a light probe change. Keep
    // meshes, sockets, articulated parents and wheel replacements in place.
    func rebindOptics(coatsOnly: Bool = false) {
        for item in polishedTrim.values { setPolishedReceiver(on: item.draw, finish: item.finish) }
        for (path,group) in opticalPath{
            if coatsOnly && !isMetalShaded(group) { continue }
            guard let old=originals[path],let g=optical[group],
                  var m=old.draw.components[ModelComponent.self] else{continue}
            m.materials[0]=nativeMaterial(g,group:group);old.draw.components.set(m)
            if let kind=kinds[group],let pane=inside[kind],
               let back=old.draw.children.first(where:{$0.name=="Glass_Interior_Transmission"}),
               var reverse=back.components[ModelComponent.self]{
                reverse.materials[0]=pane;back.components.set(reverse)
            }
        }
    }
    func pigment(_ finish:NorthlightFinish?) throws {
        optical=try pigmented(optical,finish)
    }
    private func pigmented(_ materials:[String:ShaderGraphMaterial],_ finish:NorthlightFinish?) throws -> [String:ShaderGraphMaterial] {
        guard let finish else{return materials}
        var update=materials
        for name in lacquer{
            var g=update[name]!
            let roughReturn = name.lowercased().contains("rough")
            try g.setParameter(name:"Pigment",value:.simd3Float(finish.binder))
            if g.parameterNames.contains("FlakePigment") {
                try g.setParameter(name:"FlakePigment",value:.simd3Float(finish.flake))
            }
            if g.parameterNames.contains("FlakeCoverage") {
                try g.setParameter(name:"FlakeCoverage",value:.float(finish.referenceFlakeCoverage ?? -1))
            }
            try g.setParameter(name:"Metal",value:.float(finish.metal))
            if g.parameterNames.contains("NormalReflectance") {
                try g.setParameter(name:"NormalReflectance",value:.float(finish.normalReflectance ?? (roughReturn ? 0 : -1)))
            }
            // The APK recolors the jambs with the body and keeps their roughness at 1.
            let roughness = roughReturn ? NorthlightFinish.coatRoughness(1) : finish.rough
            try g.setParameter(name:"Roughness",value:.float(roughness));update[name]=g
        }
        return update
    }
    func remove(from car:VehicleScene,onlyPaint:Bool=false) {
        if !onlyPaint { polishedTrim.removeAll() }
        for (path,original) in originals where !onlyPaint || paint.contains(path) {
            original.draw.removeFromParent();car.node(at:path)?.components.set(original.model);originals.removeValue(forKey:path)
        }
    }
    func unpackClassicClone(_ body:Entity) {
        for (path,item) in originals {
            let e=path.split(separator:"/").dropFirst().reduce(Optional(body)){node,name in node?.children.first{$0.name==name}}
            e?.children.first{$0.name==item.draw.name}?.removeFromParent();e?.components.set(item.model)
        }
    }
    func forget(prefix:String){
        originals=originals.filter{!$0.key.hasPrefix(prefix+"/") && $0.key != prefix}
        polishedTrim=polishedTrim.filter{!$0.key.hasPrefix(prefix+"/") && $0.key != prefix}
    }
    func bindPaint(to car:VehicleScene){for p in paint{if let e=car.node(at:p){bind(e,path:p,finish:car.photographicPaint)}}}
    func bindTree(_ e:Entity,path:String,finish:NorthlightFinish?) {
        let children=Array(e.children)
        bind(e,path:path,finish:finish)
        for c in children{bindTree(c,path:path+"/"+c.name,finish:finish)}
    }
    private func present(_ model:ModelComponent,original:ModelComponent,on parent:Entity,path:String){
        // Preserve the authored transform/visibility target. Give the alternative
        // geometry its own native draw identity, never the factory material's slot.
        let draw=Entity();draw.name="NorthlightSurface_"+(original.materials.first?.name ?? "paint");draw.components.set(model)
        if let group=opticalPath[path],let kind=kinds[group],let pane=inside[kind] {
            // The outgoing ray through the opposite window sees the back
            // face, which a front-only exterior shader necessarily culls.
            // Reuse its mesh, fade state, transform and actual privacy tint.
            var reverse=model;reverse.materials[0]=pane
            let back=Entity();back.name="Glass_Interior_Transmission";back.components.set(reverse);draw.addChild(back)
        }
        originals[path]=(original,draw);parent.components.remove(ModelComponent.self);parent.addChild(draw)
    }
    private func bind(_ e:Entity,path:String,finish:NorthlightFinish?) {
        guard var m=e.components[ModelComponent.self],let src=m.materials.first as? PhysicallyBasedMaterial else{return}
        let original=m
        if src.name?.hasPrefix("GlossyBlack_") == true {
            present(original, original: original, on: e, path: path)
            if let draw = originals[path]?.draw { registerPolishedTrim(draw, material: src, at: path) }
            return
        }
        if glazing != nil, let lens = LampLens(material: src) {
            lampLenses[path] = .init(mesh: m.mesh, surface: .lamp(lens))
            present(m, original: original, on: e, path: path)
            return
        }
        if let group=opticalPath[path],let graph=optical[group] {
            if let mesh=panels[path]{m.mesh=mesh}
            m.materials[0]=nativeMaterial(graph,group:group);present(m,original:original,on:e,path:path);return
        }
        let n=(src.name ?? "").lowercased(),wheel=mounts.contains{path.hasPrefix($0)}
        // Construct separate materials; mutating an imported USD tint can
        // mutate RealityKit's cached uniform block, including its Classic copy.
        var p=PhysicallyBasedMaterial()
        p.textureCoordinateTransform=src.textureCoordinateTransform
        p.baseColor=src.baseColor;p.normal=src.normal;p.ambientOcclusion=src.ambientOcclusion
        p.blending=src.blending;p.faceCulling=src.faceCulling;p.metallic=src.metallic;p.roughness=src.roughness;p.specular=src.specular
        p.clearcoat=src.clearcoat;p.clearcoatRoughness=src.clearcoatRoughness
        p.emissiveColor=src.emissiveColor;p.emissiveIntensity=src.emissiveIntensity
        let detail=src.name.flatMap{hardware[$0]}
        if let base=detail?.base{p.baseColor = .init(tint:.white,texture:.init(base))}
        // Exterior atlas channels include their original USD sampler weights.
        // Cabin maps retain the separate weight on the imported material.
        let nativeTrim = !wheel && !n.hasPrefix("brakes_") && detail?.authoredExterior != true
        if let ao=detail?.ao{p.ambientOcclusion = .init(texture:.init(ao))}
        if let metal=detail?.metal{p.metallic = .init(scale:nativeTrim ? src.metallic.scale:1,texture:.init(metal))}
        if let rough=detail?.rough{p.roughness = .init(scale:nativeTrim ? src.roughness.scale:1,texture:.init(rough))}
        if let split=detail?.finishGeometry {
            m.mesh=split.fascia;m.materials[0]=p
            present(m,original:original,on:e,path:path)
            // Editing an imported PBR parameter clears its source name. The
            // ray palette needs the factory finish identity on this draw.
            let gloss=split.material
            let draw=Entity()
            draw.name="NorthlightSurface_"+(gloss.name ?? "GlossyBlack")
            draw.components.set(ModelComponent(mesh:split.appliques,materials:[gloss]))
            originals[path]?.draw.addChild(draw)
            registerPolishedTrim(draw,material:gloss,at:path)
            return
        }
        var replace=true
        if model=="cybertruck" && (n.hasPrefix("paintmix") || n.hasPrefix("stainless_steel")) {
            p.baseColor.tint=swatch(0xafb3b4);p.metallic=0.97;p.roughness=n.contains("rough") ? 0.43:0.28
            p.anisotropyLevel=0.64;p.anisotropyAngle=0.25
        } else if paint.contains(path),let finish {
            let rough=(src.name ?? factoryNames[path] ?? "").lowercased().contains("rough")
            #if os(macOS)
            p.baseColor.tint = StudioColor(cgColor: finish.tint)!
            #else
            p.baseColor.tint = StudioColor(cgColor: finish.tint)
            #endif
            p.metallic = .init(floatLiteral:finish.metal)
            p.roughness = .init(floatLiteral:rough ? 0.63:finish.rough)
            p.clearcoat = .init(floatLiteral:rough ? 0.13:1);p.clearcoatRoughness = .init(floatLiteral:rough ? 0.32:0.095)
            p.specular=0.48
        } else if n.contains("glass") && (n.contains("skybox") || n.contains("window") || n.contains("topfade") || n.contains("interior")) {
            let inner=n.contains("interior"),dark=n.contains("tint") || n.contains("dark") || n.contains("top")
            p.baseColor.tint=swatch(inner ? 0x0d1315:0x213639);p.metallic = .init(floatLiteral:inner ? 0:0.18)
            p.specular = .init(floatLiteral:inner ? 0:0.72);p.roughness = .init(floatLiteral:inner ? 1:0.064)
            p.clearcoat = .init(floatLiteral:inner ? 0:0.85);p.clearcoatRoughness=0.055
            p.blending = .transparent(opacity:.init(floatLiteral:inner ? (inside.isEmpty ? 0.02:0):(dark ? 0.63:0.40)))
            p.faceCulling = .back;p.writesDepth=false
        } else if n.hasPrefix("seats") || n.hasPrefix("fabric_") || n.hasPrefix("suede") || n.hasPrefix("cloth_") {
            // Keep the actual upholstery atlas and its color. These surfaces
            // have a broad grazing return, not the clear lacquer of the shell.
            if p.normal.texture==nil{p.normal.texture = .init(seatNormal)}
            if detail?.metal == nil && detail?.rough == nil && detail?.ao == nil{
                if p.roughness.texture==nil{p.roughness=n.hasPrefix("seats") ? 0.56:0.86}
                if p.metallic.texture==nil{p.metallic=0.0}
            }
            p.specular=n.hasPrefix("seats") ? 0.31:0.18
        } else if detail?.metal != nil,(wheel || n.hasPrefix("brakes_")){
            if p.baseColor.texture==nil{p.baseColor.tint=swatch(n.contains("silver") || n.contains("chrome") ? 0xbfc0bd:0x5b6067)}
            p.specular=0.44;p.clearcoat=n.hasPrefix("brakes_") ? 0.04:0.35;p.clearcoatRoughness=0.18
        } else if n.contains("tire") || n.contains("tyre") {
            if p.baseColor.texture==nil{p.baseColor.tint=swatch(0x202120)}
            if p.roughness.texture==nil{p.roughness=0.67}
            if p.metallic.texture==nil{p.metallic=0.0};p.specular=0.38
        } else if wheel && !n.contains("blocker") {
            if p.baseColor.texture==nil {
                let silver=n.contains("silver") || n.contains("chrome") || n.contains("bright")
                p.baseColor.tint=swatch(silver ? 0xacb0b0:0x4b4f54)
                if p.metallic.texture==nil{p.metallic=silver ? 0.86:0.47}
                if p.roughness.texture==nil{p.roughness=silver ? 0.24:0.30}
            }
            p.clearcoat=0.4;p.clearcoatRoughness=0.19
        } else if n.hasPrefix("brakes") && src.roughness.texture==nil {
            p.roughness=0.35 // keep the rotor/caliper's color and metal atlas
        } else {replace=detail?.base != nil || detail?.authoredExterior == true}
        let accent=glazing?.accents[path]
        guard replace || panels[path] != nil || accent != nil else{return}
        if let mesh=panels[path]{m.mesh=mesh}
        if replace{m.materials[0]=p}
        present(m,original:original,on:e,path:path)
        if let accent,let draw=originals[path]?.draw{
            // These islands identify geometry bordering a window. Their
            // original UVs select the rubber, anodized or polished finish.
            let trim = (m.materials[0] as? PhysicallyBasedMaterial) ?? src
            if let base=accent.base {m.mesh=base;draw.components.set(m)} else {draw.components.remove(ModelComponent.self)}
            for (kind,mesh) in accent.details.sorted(by:{$0.key<$1.key}){
                let hardware = kind == "handle" || kind == "repeater"
                var finish = trim
                if hardware {
                    // The shell and pull handles share a fully metallic atlas with
                    // unrelated parts. The factory black coating has a 0.35 metal
                    // weight. The satin pull has a broader lobe than the bezel.
                    finish.metallic = .init(scale:0.35, texture:trim.metallic.texture)
                    if kind == "handle" { finish.roughness = .init(scale:2, texture:trim.roughness.texture) }
                }
                let part=Entity();part.name=(hardware ? "ExteriorHardware_" : "WindowAccent_")+kind
                part.components.set(ModelComponent(mesh:mesh,materials:[finish]));draw.addChild(part)
            }
        }
    }
}
