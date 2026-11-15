import Foundation
import RealityKit
import CoreGraphics
import ImageIO
#if os(macOS)
import AppKit
private typealias PaintColor = NSColor
#else
import UIKit
private typealias PaintColor = UIColor
#endif

/// Load generated assets from a folder reference, local download or app bundle.
@MainActor public final class VehicleLibrary {
    public struct Paint: Decodable {
        public let color: String
        public let metallic, roughness: Float
    }
    public struct Model: Decodable {
        public struct Cap: Decodable { public let caps: Bool; public let scene: String }
        public let scene: String
        public let wheel_scenes: [String: String]
        public let cap_overrides: [String: Cap]
        public let paint_presets: [String: Paint]
    }
    private struct WheelAsset: Decodable { let file: String; let hidden: [String]; let finishes:[String:Bool]? }
    private var wheelAssets:[String:WheelAsset]?
    private func wheels() throws -> [String:WheelAsset] {
        if let wheelAssets { return wheelAssets }
        let a=try JSONDecoder().decode([String:WheelAsset].self,from:Data(contentsOf:directory.appendingPathComponent("Wheels/index.json")))
        wheelAssets=a; return a
    }
    public func availableWheels(for model:String) throws -> [String] {
        let a=try wheels(); return models[model]?.wheel_scenes.filter { a[$0.value] != nil }.keys.sorted() ?? []
    }
    public func supportsCovers(_ wheel:String,on model:String) throws -> Bool {
        guard let m=models[model],let base=m.wheel_scenes[wheel],let alt=m.cap_overrides[wheel] else { return false }
        let a=try wheels();return alt.scene != base && a[base] != nil && a[alt.scene] != nil
    }
    public let directory: URL
    public let models: [String: Model]
    public let bodyStyles: [String: [String: String]]
    @MainActor final class PhotographicSource {
        let directory:URL
        let meter:StudioMeter
        let env:EnvironmentResource
        let areaLights:[VehicleKeyLight:EnvironmentResource]
        let templates:[String:ShaderGraphMaterial]
        init(directory:URL,meter:StudioMeter,env:EnvironmentResource,areaLights:[VehicleKeyLight:EnvironmentResource],templates:[String:ShaderGraphMaterial]) {
            self.directory=directory;self.meter=meter;self.env=env;self.areaLights=areaLights;self.templates=templates
        }
    }
    var studioDirectory:URL {directory.appendingPathComponent("Northlight/Studio",isDirectory:true)}
    func profileDirectory(_ profile:VehicleLightingProfile) -> URL {
        guard profile != .showroom else{return studioDirectory}
        let dir=studioDirectory.appendingPathComponent("Profiles/"+profile.rawValue,isDirectory:true)
        return FileManager.default.fileExists(atPath:dir.appendingPathComponent("Transport.json").path) ? dir:studioDirectory
    }
    private var studioSources=[PhotographicSource]()
    private var loadingSources=[URL:Task<PhotographicSource,Error>]()
    struct HardwareMaps {
        let metal,rough,ao,base:TextureResource?
        let authoredExterior:Bool
        let finishGeometry:FinishGeometry?
    }
    struct FinishGeometry {
        let fascia,appliques:MeshResource
        let material:PhysicallyBasedMaterial
    }
    private struct StudioFiles:Decodable {
        let metal,rough,ao,base:String?
        let authoredExterior:Bool?
        let finishGeometry,finishMaterial:String?
    }
    private var studioFiles:[String:StudioFiles]?
    private var studioTextures=[String:TextureResource]()
    func studioHardware(in body:Entity,originalMaterials:[any Material]=[])async throws->[String:HardwareMaps]{
        let dir=directory.appendingPathComponent("Northlight/Hardware")
        if studioFiles==nil{studioFiles=try JSONDecoder().decode([String:StudioFiles].self,from:Data(contentsOf:dir.appendingPathComponent("index.json")))}
        var wanted=Set<String>(),originals=[String:PhysicallyBasedMaterial](),maps=[String:HardwareMaps]()
        func collect(_ material:any Material){
            guard let name=material.name else{return}
            wanted.insert(name)
            if let p=material as? PhysicallyBasedMaterial {originals[name]=p}
        }
        func visit(_ e:Entity){
            if let material=e.components[ModelComponent.self]?.materials.first {collect(material)}
            for c in e.children{visit(c)}
        }
        visit(body)
        for material in originalMaterials {collect(material)}
        func load(_ file:String?,_ color:Bool=false)async throws->TextureResource?{
            guard let file else{return nil}
            let id=(color ? "srgb:":"raw:")+file
            if let cached=studioTextures[id]{return cached}
            let t=try await TextureResource(contentsOf:dir.appendingPathComponent(file),options:.init(semantic:color ? .color:.raw))
            studioTextures[id]=t;return t
        }
        for key in wanted{if let f=studioFiles?[key]{
            var finish:FinishGeometry?
            if let file=f.finishGeometry {
                let bank=try await Entity(contentsOf:dir.appendingPathComponent(file))
                guard let name=f.finishMaterial,let material=originals[name],
                      let fascia=bank.findEntity(named:"Fascia")?.components[ModelComponent.self]?.mesh,
                      let appliques=bank.findEntity(named:"Appliques")?.components[ModelComponent.self]?.mesh
                else{throw VehicleError.invalid("Missing fascia finish for \(key)")}
                finish = .init(fascia:fascia,appliques:appliques,material:material)
            }
            maps[key]=try await .init(metal:load(f.metal),rough:load(f.rough),ao:load(f.ao),base:load(f.base,true),
                                      authoredExterior:f.authoredExterior ?? false,finishGeometry:finish)
        }}
        return maps
    }
    private var seatNormal:TextureResource?
    func upholstery() async throws ->TextureResource {
        if let seatNormal{return seatNormal}
        let n=try await TextureResource(contentsOf:directory.appendingPathComponent("Northlight/Studio/Upholstery.png"),options:.init(semantic:.normal))
        seatNormal=n;return n
    }
    func illumination(at dir:URL) async throws -> PhotographicSource {
        if let i=studioSources.firstIndex(where:{$0.directory==dir}){
            let source=studioSources.remove(at:i);studioSources.append(source);return source
        }
        if let pending=loadingSources[dir]{return try await pending.value}
        let shared=studioDirectory
        let pending=Task {try await Self.loadIllumination(at:dir,shared:shared)}
        loadingSources[dir]=pending
        defer{loadingSources[dir]=nil}
        let source=try await pending.value
        // Each setup includes three native HDR probes. Keep the last two for
        // immediate camera round trips without retaining the entire fleet of rigs.
        if studioSources.count==2{studioSources.removeFirst()}
        studioSources.append(source)
        return source
    }
    private static func loadIllumination(at dir:URL,shared:URL) async throws -> PhotographicSource {
        let meter=try StudioMeter(directory:dir)
        func probe(_ name:String) async throws ->EnvironmentResource {
            let url=dir.appendingPathComponent(name)
            guard let src=CGImageSourceCreateWithURL(url as CFURL,nil),let hdr=CGImageSourceCreateImageAtIndex(src,0,nil)
            else {throw VehicleError.invalid("Missing studio light: \(name)")}
            return try await EnvironmentResource(equirectangular:hdr)
        }
        let env=try await probe("Light.hdr")
        var area=[VehicleKeyLight:EnvironmentResource]()
        if dir != shared || FileManager.default.fileExists(atPath:dir.appendingPathComponent("Light-Rim.hdr").path){
            area[.rake]=env;area[.overhead]=try await probe("Light-Overhead.hdr");area[.rim]=try await probe("Light-Rim.hdr")
        }
        var templates=[String:ShaderGraphMaterial]()
        for kind in ["Lacquer","Brushed","Glazing","Privacy"]{
            templates[kind]=try await ShaderGraphMaterial(named:"/"+kind,from:dir.appendingPathComponent("Optics.usda"))
        }
        if FileManager.default.fileExists(atPath:shared.appendingPathComponent("SoftboxFace.png").path){
            for kind in ["InsideGlass","InsidePrivacy"]{
                var pane=try await ShaderGraphMaterial(named:"/"+kind,from:dir.appendingPathComponent("Optics.usda"))
                pane.faceCulling = .front;pane.writesDepth=false;pane.readsDepth=true;templates[kind]=pane
            }
        }
        return PhotographicSource(directory:dir,meter:meter,env:env,areaLights:area,templates:templates)
    }
    public init(directory: URL) throws {
        self.directory = directory
        models = try JSONDecoder().decode([String: Model].self, from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
        let styles = directory.appendingPathComponent("body-styles.json")
        bodyStyles = FileManager.default.fileExists(atPath: styles.path)
            ? try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: styles)) : [:]
    }
    public func load(_ model: String, bodyStyle: String = "default") async throws -> VehicleScene {
        guard models[model] != nil else { throw VehicleError.invalid("Unknown model: \(model)") }
        let path = bodyStyle == "default" ? model : bodyStyles[model]?[bodyStyle]
        guard let path else { throw VehicleError.invalid("Unknown or unpackaged body style: \(bodyStyle)") }
        return try await VehicleScene(directory: directory.appendingPathComponent(path), fleet: directory)
    }

    /// Replace only the moving wheel entities. This preserves brakes, body options,
    /// author-specified socket transforms, active poses and the Semi's fixed rear wheels.
    public func setWheels(_ wheel: String, caps: Bool? = nil, on scene: VehicleScene) async throws {
        scene.wheelGeneration += 1; let token=scene.wheelGeneration
        guard let model = models[scene.manifest.model], var source = model.wheel_scenes[wheel] else {
            throw VehicleError.invalid("Unknown wheel: \(wheel)")
        }
        if let caps, let override = model.cap_overrides[wheel], override.caps == caps { source = override.scene }
        let dir = directory.appendingPathComponent("Wheels")
        let assets = try wheels()
        guard let asset = assets[source] else { throw VehicleError.invalid("Wheel not packaged: \(source)") }
        let loaded = try await Entity(contentsOf: dir.appendingPathComponent(asset.file))
        guard let body = loaded.findEntity(named: "Body") else { throw VehicleError.invalid("Empty wheel package") }
        for path in asset.hidden {
            var node: Entity? = body
            for part in path.split(separator: "/").dropFirst() { node = node?.children.first { $0.name == part } }
            node?.isEnabled = false
        }
        let mounts = scene.manifest.wheelMounts.filter { $0.source == scene.manifest.configuration.wheel_scene }
        guard !mounts.isEmpty else { throw VehicleError.invalid("No wheel sockets on \(scene.manifest.model)") }
        let replacements: [(Entity, Entity)] = try mounts.map { mount in
            guard let socket = scene.node(at: mount.socket), let old = socket.children.first(where: { $0.name == mount.child }) else {
                throw VehicleError.invalid("Missing wheel socket: \(mount.socket)/\(mount.child)")
            }
            return (socket, old)
        }
        var finishes=[String:ShaderGraphMaterial]()
        if let defs=asset.finishes,let shader=scene.manifest.rig.parked?.shader {
            let env=(scene.manifest.rig.panorama as NSString).deletingPathExtension
            for (n,twoSided) in defs where !(shader.wheelMaterials ?? []).contains(n) {
                if let existing=scene.replacementFinishes[n] { finishes[n]=existing;continue }
                var finish=try await ShaderGraphMaterial(named:"/"+n,from:dir.appendingPathComponent("Parked/\(env)/\(n).usda"))
                finish.faceCulling=twoSided ? .none : .back; finishes[n]=finish
            }
        }
        try await scene.prepareWheelMaterials(in: body)
        let studio=scene.photo==nil ? [:]:try await studioHardware(in:body)
        try Task.checkCancellation()
        guard token==scene.wheelGeneration else { throw CancellationError() }
        scene.replacementFinishes=finishes
        scene.photo?.include(studio)
        for (mount, (socket, old)) in zip(mounts, replacements) {
            scene.replaceWheel(at: mount.socket + "/" + mount.child, socket: socket, old: old, new: body.clone(recursive: true))
        }
    }

    /// Recolor body paint slots independently of wheels, glass and trim.
    public func setPaint(_ name: String, on scene: VehicleScene) throws {
        guard let paint = models[scene.manifest.model]?.paint_presets[name] else {
            throw VehicleError.invalid("No paint preset \(name) for \(scene.manifest.model)")
        }
        // Named paints are shader coefficients, whereas the public hex API takes sRGB.
        guard let raw = UInt32(paint.color.dropFirst(), radix: 16) else { throw VehicleError.invalid("Invalid paint preset") }
        let factory = name == scene.manifest.configuration.selections.paint
        let sourceRGB = SIMD3<Float>(Float(raw >> 16), Float((raw >> 8) & 255), Float(raw & 255)) / 255
        let classicPaint = factory ? nil : ClassicComponents.Paint(rgb: sourceRGB, metallic: paint.metallic,
                                                                  roughness: paint.roughness, deepenUltraRed: name == "UltraRed")
        try scene.changePhotographicPaint(NorthlightFinish(name:name,source:paint), classicPaint: classicPaint) {
        if scene.restoreNamedFactoryPaint(name) {
            scene.parkedHighlightRGB = scene.namedHighlight(name) ?? VehicleScene.highlight(for: raw)
            return
        }
        let srgb = [16, 8, 0].map { shift -> String in
            let v = Float((raw >> shift) & 255) / 255
            let s = v <= 0.0031308 ? 12.92*v : 1.055*pow(v, 1/2.4)-0.055
            return String(format: "%02x", Int(round(s*255)))
        }.joined()
        try scene.setPortablePaint(hex: srgb, metallic: paint.metallic, roughness: paint.roughness)
        scene.parkedHighlightRGB = scene.namedHighlight(name) ?? VehicleScene.highlight(for: raw)
        }
    }
}

extension VehicleScene {
    /// Static PBR body recoloring. For baked, nonuniform wraps re-export the configuration.
    public func setPaint(hex: String, metallic: Float, roughness: Float) throws {
        let digits=hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let rgb=UInt32(digits,radix:16), (0...1).contains(metallic), (0...1).contains(roughness)
        else {throw VehicleError.invalid("Expected six hex color digits and PBR values in 0...1")}
        let linear = Self.linearRGB(rgb)
        try changePhotographicPaint(.init(rgb:rgb,metal:metallic,rough:roughness),
                                    classicPaint: .init(rgb: linear, metallic: metallic, roughness: roughness)){
            try setPortablePaint(hex:hex,metallic:metallic,roughness:roughness)
        }
    }
    private static func linearRGB(_ rgb: UInt32) -> SIMD3<Float> {
        func channel(_ shift: Int) -> Float {
            let value = Float((rgb >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return .init(channel(16), channel(8), channel(0))
    }
    fileprivate func setPortablePaint(hex: String, metallic: Float, roughness: Float) throws {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let rgb = UInt32(digits, radix: 16), (0...1).contains(metallic), (0...1).contains(roughness) else {
            throw VehicleError.invalid("Expected six hex color digits and PBR values in 0...1")
        }
        guard !manifest.paintSurfaces.isEmpty else { throw VehicleError.invalid("This model has no tintable paint slots") }
        restoreSurfaceMaterials(onlyPaint: true)
        let color = PaintColor(red: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255,
                               blue: CGFloat(rgb & 255)/255, alpha: 1)
        var changes: [(String,Entity, ModelComponent)] = []
        for path in manifest.paintSurfaces {
            guard let entity = node(at: path), var model = entity.components[ModelComponent.self],
                  let original = model.materials.first as? PhysicallyBasedMaterial else {
                throw VehicleError.invalid("Missing PBR paint surface: \(path)")
            }
            // A new native material identity keeps edits to the USD-imported
            // uniform block from leaking into the saved factory edge/rough paint.
            var pbr=PhysicallyBasedMaterial()
            pbr.baseColor=original.baseColor;pbr.normal=original.normal
            pbr.specular=original.specular;pbr.ambientOcclusion=original.ambientOcclusion
            pbr.clearcoat=original.clearcoat;pbr.clearcoatRoughness=original.clearcoatRoughness
            pbr.emissiveColor=original.emissiveColor;pbr.emissiveIntensity=original.emissiveIntensity
            pbr.blending=original.blending;pbr.faceCulling=original.faceCulling
            let originalName = (factoryPaintName(at:path) ?? original.name)?.lowercased() ?? ""
            pbr.baseColor.tint = color
            pbr.metallic = .init(floatLiteral: metallic)
            pbr.roughness = .init(floatLiteral: originalName.contains("rough") ? 1 : roughness)
            model.materials[0] = pbr
            changes.append((path,entity, model))
        }
        for (path,entity,component) in changes { presentCustomPaint(component,on:entity,path:path) }
        hasCustomParkedPaint = true
        try updateStudioPaint(rgb:Self.linearRGB(rgb),metallic:metallic,roughness:roughness)
        parkedHighlightRGB = Self.highlight(for: rgb)
    }

    func setSensorColor(_ value:[Float],on entity:Entity) throws {
        guard value.count==4,var m=entity.components[ModelComponent.self],var p=m.materials.first as? PhysicallyBasedMaterial
        else { throw VehicleError.invalid("Invalid sensor color track") }
        p.baseColor.tint=PaintColor(red:CGFloat(value[0]),green:CGFloat(value[1]),blue:CGFloat(value[2]),alpha:CGFloat(value[3]))
        m.materials=[p];entity.components.set(m)
    }
}
