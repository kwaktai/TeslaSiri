import Foundation
import Observation
import RealityKit
import simd

/// One live vehicle viewport. Keep this object in app state. All updates are
/// local visualization commands, not commands to a real car.
@MainActor @Observable public final class VehicleExperience {
    public static let home = "HOME"
    public let library: VehicleLibrary
    public let root = Entity()
    public let camera = PerspectiveCamera()
    public private(set) var car: VehicleScene?
    public private(set) var model = ""
    public private(set) var bodyStyle = "default"
    public private(set) var view = VehicleExperience.home
    public private(set) var look:VehicleLook
    public private(set) var keyLight:VehicleKeyLight = .rake
    @ObservationIgnored private var desiredLook:VehicleLook
    @ObservationIgnored private(set) var geometryRevision:UInt64=0
    @ObservationIgnored private(set) var cameraEpoch:UInt64=0
    public private(set) var paint: String?
    public private(set) var wheel: String?
    public private(set) var covers: Bool?
    public private(set) var poses: [String:Float] = [:]
    public private(set) var effects: Set<String> = []
    public private(set) var revision: UInt64 = 0
    public private(set) var wheelChoices: [String] = []
    public private(set) var clipChoices: [String] = []
    public var paintChoices:[String] {
        guard car?.manifest.configuration.selections.paint != nil else{return []} // Stainless is not a named paint.
        return library.models[model]?.paint_presets.keys.sorted() ?? []
    }
    public var effectChoices:[String] { car?.manifest.controls?.keys.sorted() ?? [] }
    public var views:[String] { [Self.home] + (car?.manifest.rig.cameras.keys.sorted() ?? []) }
    public var location:VehicleLocation { .forView(view) }
    /// Lighting requested by the camera. Older asset libraries use the showroom
    /// when they do not contain the corresponding profile.
    public var lightingProfile: VehicleLightingProfile { .forView(view) }
    public var activeLightingProfile: VehicleLightingProfile? {
        guard look == .northlight, let directory = car?.photo?.source?.directory else { return nil }
        guard directory.deletingLastPathComponent().lastPathComponent == "Profiles" else { return .showroom }
        return VehicleLightingProfile(rawValue: directory.lastPathComponent)
    }
    /// Catalog format. A host can still choose any live pane or export aspect.
    public var cameraAspect:Float {
        if let pose=car?.manifest.rig.cameras[view],let w=pose.width,let h=pose.height,w>0,h>0{return w/h}
        if ["TOP_DOWN","CLIMATE","SNAPSHOT_TOPDOWN","SNAPSHOT_TOPDOWN_FADE_ROOF","SNAPSHOT_WIDGET"].contains(view){return 1}
        return 1.6
    }
    @ObservationIgnored private var modelRequest=0
    @ObservationIgnored private var viewRequest=0
    @ObservationIgnored private var baseFOV:Float=40
    @ObservationIgnored private var aspect:Float=1.6
    @ObservationIgnored private var fitRatio:SIMD2<Float>?
    @ObservationIgnored private var photographicLens=false
    @ObservationIgnored private var handFramed=false
    private var target: SIMD3<Float> = [0,0.65,0]
    private var roofOriginals=[String:Bool]()
    private var animationTokens=[String:UUID]()

    /// Existing clients keep Classic; the demo opts into Northlight explicitly.
    public init(library:VehicleLibrary,look:VehicleLook = .classic) { self.library=library;self.look=look;desiredLook=look;root.name="VehicleExperience";root.addChild(camera) }
    public func invalidate() { geometryRevision &+= 1;revision &+= 1 }
    public func load(_ id:String,bodyStyle style:String="default") async throws {
        modelRequest += 1;let token=modelRequest
        let next=try await library.load(id,bodyStyle:style)
        let choices=try library.availableWheels(for:id)
        var prepared=VehicleLook.classic
        while prepared != desiredLook {
            try Task.checkCancellation();guard token==modelRequest else{throw CancellationError()}
            prepared=desiredLook
            if prepared == .northlight{try await next.applyNorthlight(library:library)}else{try await next.applyParkedAppearance()}
        }
        try Task.checkCancellation();guard token==modelRequest else {throw CancellationError()}
        if keyLight != .rake{try next.moveKey(keyLight)}
        viewRequest += 1; animationTokens.removeAll();roofOriginals.removeAll()
        car?.entity.removeFromParent();root.addChild(next.entity)
        car=next;model=id;bodyStyle=style;view=Self.home;look=prepared
        let cfg=next.manifest.configuration;paint=cfg.selections.paint;wheel=cfg.selections.wheel
        if let wheel,try library.supportsCovers(wheel,on:id),let cap=library.models[id]?.cap_overrides[wheel] {
            covers=cap.scene==cfg.wheel_scene ? cap.caps : !cap.caps
        } else {covers=nil}
        wheelChoices=choices.filter{w in
            if id=="semi" {return w=="SemiDefault"}
            if id=="cybertruck"{return w.hasPrefix("Cybertruck")}
            return w != "SemiDefault" && !w.hasPrefix("Cybertruck")
        };poses=[:];effects=[]
        effects=Set((next.manifest.controls ?? [:]).compactMap { name,paths in
            paths.contains{next.node(at:$0)?.isEnabledInHierarchy==true} ? name : nil
        })
        clipChoices=next.manifest.clips.filter { _,clip in clip.tracks.contains { t in
            guard let e=next.node(at:t.target) else {return false}
            return t.channel=="visible" ? e.parent?.isEnabledInHierarchy==true : e.isEnabledInHierarchy
        }}.keys.sorted()
        installCamera(prepared == .northlight ? next.photoCamera():next.parkedCamera(),home:true);invalidate()
    }
    /// Named views use the shipped camera, not a re-aimed home camera.
    /// The photographic look lights the subject of the view. Classic uses
    /// the original snapshot lighting.
    public func setView(_ name:String) async throws {
        guard let car else { throw VehicleError.invalid("Load a vehicle first") }
        let home=name==Self.home
        let mode=desiredLook
        let next=home ? (mode == .northlight ? car.photoCamera():car.parkedCamera()) : try car.camera(view:name)
        viewRequest += 1;let token=viewRequest
        if mode == .northlight {try await car.applyNorthlight(library:library,location:.forView(name),profile:.forView(name))}
        else if home { try await car.applyParkedAppearance() } else { try car.setLighting(view:name) }
        guard token==viewRequest,self.car===car else { throw CancellationError() }
        for (path,on) in roofOriginals { car.node(at:path)?.isEnabled=on };roofOriginals.removeAll()
        if name=="SNAPSHOT_TOPDOWN_FADE_ROOF" || name=="CLIMATE" {
            for path in car.manifest.roofFadeSurfaces ?? [] {
                if let e=car.node(at:path) { roofOriginals[path]=e.isEnabled;e.isEnabled=false }
            }
        }
        // Snapshot.gd scales the *vehicle* in its slot. Work in life-size
        // coordinates instead; uniformly rescale the optical center.
        if name.hasPrefix("SNAPSHOT_") { next.position /= Self.productScale(model) }
        view=name;look=mode;installCamera(next,home:home);invalidate()
    }
    /// Change the lighting and surfaces without resetting the camera, pose, wheels or paint.
    public func setLook(_ mode:VehicleLook) async throws {
        desiredLook=mode
        guard let car else{look=mode;return}
        viewRequest += 1;let token=viewRequest
        do{
            if mode == .northlight{try await car.applyNorthlight(library:library,location:location,profile:lightingProfile)}
            else if view==Self.home{try await car.applyParkedAppearance()}else{try car.setLighting(view:view)}
            guard token==viewRequest,self.car===car else{throw CancellationError()}
            let resetPreset=mode != look && view != Self.home && !handFramed
            look=mode;cameraEpoch &+= 1
            if resetPreset {
                let c=try car.camera(view:view)
                if view.hasPrefix("SNAPSHOT_"){c.position /= Self.productScale(model)}
                installCamera(c,home:false)
            }
            invalidate()
        }catch{if token==viewRequest{desiredLook=look};throw error}
    }
    static func productScale(_ model:String)->Float {
        switch model {case "cybertruck":0.875;case "semi":0.627;case "model_s","model_s_palladium":0.945
        case "model_x","model_x_palladium":0.93;case "model_y","bayberry","bayberry_e41","bayberry_e80":0.987;default:1}
    }
    private func installCamera(_ c:PerspectiveCamera,home:Bool) {
        cameraEpoch &+= 1
        camera.transform=c.transform;camera.camera=c.camera;baseFOV=c.camera.fieldOfViewInDegrees
        photographicLens=look == .northlight && !home;fitRatio=nil;handFramed=false
        let center:SIMD3<Float>=[0,model=="semi" ? 1.5 : 0.65,0]
        let forward=c.orientation.act([0,0,-1])
        target=home ? (look == .northlight ? car?.photoTarget ?? center:center) : c.position+forward*max(0.5,simd_dot(center-c.position,forward))
        if photographicLens,let fit=car?.cameraSubject?.fit(c,view:view,aspect:cameraAspect) {
            camera.position=fit.position;target=fit.target
            fitRatio=fit.tangent/tan(baseFOV * .pi/360)
        }
        fitAspect()
    }
    private func fitAspect() {
        let k:Float
        if let fitRatio{k=max(fitRatio.x/aspect,fitRatio.y)}
        else if photographicLens {k=camera.camera.fieldOfViewOrientation == .horizontal ? max(1,aspect/cameraAspect):max(1,cameraAspect/aspect)}
        else{k=view==Self.home ? max(1,1.6/aspect) : 1}
        camera.camera.fieldOfViewInDegrees=min(150,atan(tan(baseFOV * .pi/360)*k)*360 / .pi)
    }
    public func resize(aspect ratio:Float) {
        guard ratio.isFinite,ratio>0,abs(ratio-aspect)>0.0001 else{return}
        aspect=ratio;fitAspect();revision &+= 1
    }
    public func orbit(yaw:Float,pitch:Float) {
        guard yaw.isFinite,pitch.isFinite else{return}
        handFramed=true
        let d=camera.position-target,l=max(0.1,simd_length(d)),a=atan2(d.x,d.z)+yaw
        let e=min(1.50,max(0.035,asin(min(1,max(-1,d.y/l)))+pitch))
        camera.look(at:target,from:target+l*SIMD3(sin(a)*cos(e),sin(e),cos(a)*cos(e)),relativeTo:nil);revision &+= 1
    }
    public func zoom(by factor:Float) {
        guard factor.isFinite,factor>0 else{return}
        handFramed=true
        baseFOV=min(110,max(8,2*atan(tan(baseFOV * .pi/360)/factor)*180 / .pi));fitAspect();revision &+= 1
    }
    public func setPaint(_ name:String) throws {
        guard let car else {throw VehicleError.invalid("Load a vehicle first")}
        guard paintChoices.contains(name) else {throw VehicleError.invalid("No named body paint for this build")}
        try library.setPaint(name,on:car);paint=name;revision &+= 1
    }
    public func setKeyLight(_ angle:VehicleKeyLight)throws{
        guard keyLight != angle else{return};try car?.moveKey(angle);keyLight=angle;cameraEpoch &+= 1;invalidate()
    }
    public func setWheels(_ name:String,covers requested:Bool?=nil) async throws {
        guard let car else {throw VehicleError.invalid("Load a vehicle first")}
        guard wheelChoices.contains(name) else{throw VehicleError.invalid("Unavailable wheel on this build: \(name)")}
        let canSwitch=try library.supportsCovers(name,on:model)
        guard requested==nil || canSwitch else {throw VehicleError.invalid("This wheel has no alternate covers")}
        try await library.setWheels(name,caps:requested,on:car)
        guard self.car===car else {throw CancellationError()}
        wheel=name;covers=canSwitch ? (requested ?? !(library.models[model]!.cap_overrides[name]!.caps)) : nil;invalidate()
    }
    public func setEffect(_ name:String,on:Bool) throws {
        guard let car,let paths=car.manifest.controls?[name],!paths.isEmpty else {throw VehicleError.invalid("Unavailable effect: \(name)")}
        if on {effects.insert(name)} else {effects.remove(name)}
        let enabled=Set(effects.flatMap{car.manifest.controls?[$0] ?? []})
        for path in paths {guard let node=car.node(at:path) else {throw VehicleError.invalid(path)};node.isEnabled=enabled.contains(path)}
        invalidate()
    }
    public func seek(_ clip:String,to fraction:Float) throws {
        guard let car,clipChoices.contains(clip),fraction.isFinite else {throw VehicleError.invalid("Unavailable clip or progress: \(clip)")}
        animationTokens[clip]=nil
        let p=min(1,max(0,fraction));try car.seek(clip,progress:p);poses[clip]=p;invalidate()
    }
    public func animate(_ clip:String,to fraction:Float) async throws {
        guard let car,clipChoices.contains(clip),let source=car.manifest.clips[clip],fraction.isFinite else {throw VehicleError.invalid("Unavailable animation: \(clip)")}
        let dest=min(1,max(0,fraction)),start=poses[clip] ?? 0,token=UUID()
        animationTokens[clip]=token
        let duration=max(0.001,Double(abs(dest-start)*source.duration)),clock=ContinuousClock(),t0=clock.now
        repeat {
            try Task.checkCancellation()
            guard animationTokens[clip]==token,self.car===car else {throw CancellationError()}
            let elapsed=(clock.now-t0).components
            let t=Float(min(1,(Double(elapsed.seconds)+Double(elapsed.attoseconds)*1e-18)/duration))
            let p=start+(dest-start)*t;try car.seek(clip,progress:p);poses[clip]=p;invalidate()
            if t>=1 {animationTokens[clip]=nil;return}
            try await Task.sleep(for:.milliseconds(16))
        } while true
    }
}
