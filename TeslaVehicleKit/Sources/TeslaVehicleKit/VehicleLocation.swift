import Foundation
import RealityKit
import simd

/// The original camera families and their stable storage values.
public enum VehicleLocation:String,CaseIterable,Sendable {
    case dayroom="Dayroom",road="Open road",court="Arrival court",cabin="Cabin light"

    public static func forView(_ view:String)->Self {
        if view=="CLIMATE" || view=="SNAPSHOT_TOPDOWN_FADE_ROOF"{return .cabin}
        if view.hasPrefix("DRIVE") || view.contains("Lane") || view.contains("LaunchMode"){return .road}
        if view=="HOME" || view.hasPrefix("SNAPSHOT_"){return .dayroom}
        return .court
    }
    public var cameraGroup:String {switch self{case .dayroom:"Portrait & profiles";case .road:"Driving";case .court:"Parking & details";case .cabin:"Interior"}}
    var lux:Float {self == .cabin ? 1320:740}
}

/// Selects the lighting setup for the subject of a named camera. Each setup
/// has its own measured environment and movable Raking, Overhead and Rim lights.
public enum VehicleLightingProfile: String, CaseIterable, Sendable {
    case showroom, drive, rear, service, inspection, cabin, overhead

    public var displayName: String {
        switch self {
        case .showroom: "Showroom"
        case .drive: "Open road"
        case .rear: "Rear exterior"
        case .service: "Service bay"
        case .inspection: "Side inspection"
        case .cabin: "Cabin"
        case .overhead: "Overhead"
        }
    }

    public static func forView(_ view: String) -> Self {
        switch view {
        case "CLIMATE":
            return .cabin
        case "TOP_DOWN", "SNAPSHOT_TOPDOWN", "SNAPSHOT_TOPDOWN_FADE_ROOF":
            return .overhead
        case "DRIVE_REVERSE", "SNAPSHOT_REAR":
            return .rear
        case "SNAPSHOT_LEFTPROFILE", "SNAPSHOT_RIGHTPROFILE":
            return .inspection
        case "HOME", "SNAPSHOT_FRONT", "SNAPSHOT_PARKED", "SNAPSHOT_THREEQUARTER", "SNAPSHOT_WIDGET":
            return .showroom
        default:
            if view.contains("Suspension") { return .inspection }
            if view.hasPrefix("DRIVE") || view.contains("Lane") || view.contains("LaunchMode") { return .drive }
            return view.hasPrefix("SNAPSHOT_") ? .showroom : .service
        }
    }
}

/// Small support hulls of the actual visible geometry at rest. Do not refit
/// while a door opens or the user orbits: a camera shouldn't chase its subject.
struct CameraSubject:Decodable {
    let body,cabin:[SIMD3<Float>]
    struct Fit {
        let position,target:SIMD3<Float>
        let tangent:SIMD2<Float>  // required normalized horizontal/vertical half spans
    }
    @MainActor func fit(_ camera:PerspectiveCamera,view:String,aspect:Float)->Fit? {
        let parked=["AssetGen_Park","AssetGen_ParkExpanded","AssetGen_ParkRHD"].contains(view)
        guard view != "HOME",!view.hasPrefix("AssetGen_") || parked else{return nil}
        let points=view=="CLIMATE" ? cabin:body
        let margin:SIMD2<Float>
        switch view {
        case "CLIMATE":margin=[0.78,0.75] // include console, dash and a little sill around the seats
        case "DRIVE","DRIVE_REVERSE":margin=[0.76,0.76] // leave useful space for the lane
        default:margin=[0.89,0.85]
        }
        let q=camera.orientation,local=points.map{q.inverse.act($0)}
        let half=tan(camera.camera.fieldOfViewInDegrees * .pi/360)
        let tx=half*aspect*margin.x,ty=half*margin.y
        var lo=SIMD2<Float>(repeating:.infinity),hi = -lo
        for v in local{
            let xy=SIMD2(v.x,v.y),r=SIMD2(tx,ty)*v.z
            lo=simd_min(lo,xy-r);hi=simd_max(hi,xy+r)
        }
        let center=(hi+lo)*0.5,span=(hi-lo)*0.5
        let dist=max(span.x/tx,span.y/ty,(local.map(\.z).max() ?? 0)+0.4)
        var uv=SIMD2<Float>.zero
        for v in local{uv=simd_max(uv,abs(SIMD2(v.x,v.y)-center)/(dist-v.z)/margin)}
        let mid=((local.map(\.z).max() ?? 0)+(local.map(\.z).min() ?? 0))*0.5
        return Fit(position:q.act([center.x,center.y,dist]),target:q.act([center.x,center.y,mid]),tangent:uv)
    }
}
