import Foundation
import simd

/// Move the light while keeping the vehicle, camera and surrounding set still.
public enum VehicleKeyLight:String,CaseIterable,Sendable {case rake="Raking",overhead="Overhead",rim="Rim"}

/// Serialized with the HDR probes and the MaterialX quadrature, not a second
/// lighting preset. Length is the only scale factor in the physical lamp rig.
struct StudioMeter:Decodable {
    struct Key:Decodable{let offset,tint:SIMD3<Float>}
    let power,halfWidth,halfHeight:Float
    let roomHorizontal:SIMD3<Float>,keys:[String:Key],quadrature:[[Float]]
    /// Room-only diffuse luminance on +X, -X, +Y, -Y, +Z and -Z cards.
    let viewMeter: [Float]?
    init(directory:URL)throws{
        self=try JSONDecoder().decode(Self.self,from:Data(contentsOf:directory.appendingPathComponent("Transport.json")))
        guard power.isFinite,power>0,halfWidth>0,halfHeight>0,
              VehicleKeyLight.allCases.allSatisfy({keys[$0.rawValue] != nil}),
              quadrature.count==16,quadrature.allSatisfy({$0.count==5 && $0.allSatisfy(\.isFinite)}) else {
            throw VehicleError.invalid("Incomplete studio light measurement")
        }
        if let viewMeter, viewMeter.count != 6 || !viewMeter.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            throw VehicleError.invalid("Invalid directional studio light measurement")
        }
    }
    var samples:[SIMD4<Float>]{quadrature.flatMap{[SIMD4($0[0],$0[1],$0[2],$0[3]),SIMD4($0[4],0,0,0)]}}
}

/// One finite luminous bank in vehicle coordinates. The optical materials,
/// native fill/key setup, ground irradiance and shadow camera share this rig.
struct PhotographicLight {
    let center,axis,u,v,color,target:SIMD3<Float>
    let width,height,power:Float  // half extents in metres; scene-linear radiance
    let lower,upper:SIMD3<Float>
    let meter:StudioMeter
    private let incident: IncidentMeter?
    init(_ angle:VehicleKeyLight,subject:CameraSubject,meter:StudioMeter){
        self.meter=meter
        let lo=subject.body.reduce(SIMD3<Float>(repeating:.infinity),simd_min)
        let hi=subject.body.reduce(SIMD3<Float>(repeating: -.infinity),simd_max)
        lower=lo;upper=hi
        let length=hi.z-lo.z,h=hi.y-lo.y
        target=[(lo.x+hi.x)*0.5,lo.y+h*0.47,(lo.z+hi.z)*0.5]
        let setting=meter.keys[angle.rawValue]!,offset=length*setting.offset
        center=target+offset;axis=simd_normalize(offset)
        u=simd_normalize(simd_cross([0,1,0],axis));v=simd_cross(axis,u)
        width=length*meter.halfWidth;height=length*meter.halfHeight
        color=setting.tint;power=meter.power
        incident = IncidentMeter(meter: meter, offset: setting.offset, u: u, v: v, tint: color)
    }
    /// Meter the illuminated side of a neutral subject as the camera moves.
    /// No GPU readback, exposure history, or dependence on the selected paint.
    func viewExposure(eye: SIMD3<Float>) -> Float {
        incident?.compensation(direction: eye - target) ?? 0
    }
    var shadowRegion:SIMD4<Float>{[(lower.x+upper.x)*0.5,(lower.z+upper.z)*0.5,max(4.2,(upper.z-lower.z)*1.18),0]}
    var vectors:[SIMD4<Float>]{[SIMD4(center,width),SIMD4(u,height),SIMD4(v,power),SIMD4(color,0),SIMD4(lower,0),SIMD4(upper,0)]}
}

private struct IncidentMeter {
    private let positive, negative: SIMD3<Float>
    private let reference: Float

    init?(meter: StudioMeter, offset: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, tint: SIMD3<Float>) {
        guard let room = meter.viewMeter else { return nil }
        var positive = SIMD3(room[0], room[2], room[4])
        var negative = SIMD3(room[1], room[3], room[5])
        // Use the same area quadrature and emitter orientation as the surface
        // shaders. Offsets and half extents are all in vehicle lengths.
        let axis = simd_cross(u, v)
        let area = 4 * meter.halfWidth * meter.halfHeight
        let gain = area * meter.power / (Float.pi * Float(meter.quadrature.count))
        let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        for tap in meter.quadrature {
            let ray = offset + tap[0] * meter.halfWidth * u + tap[1] * meter.halfHeight * v
            let distance2 = simd_length_squared(ray)
            let direction = ray / sqrt(max(0.0001, distance2))
            let radiance = simd_dot(luma, tint * SIMD3(tap[2], tap[3], tap[4]))
            let energy = radiance * gain * max(0, simd_dot(direction, axis)) / max(0.0001, distance2)
            positive += energy * simd_max(direction, .zero)
            negative += energy * simd_max(-direction, .zero)
        }
        self.positive = positive
        self.negative = negative
        let sides = (positive.x + negative.x + positive.z + negative.z) / 4
        reference = 0.72 * sides + 0.28 * positive.y
    }

    func compensation(direction: SIMD3<Float>) -> Float {
        let length = simd_length(direction)
        guard length.isFinite, length > 0.0001 else { return 0 }
        let normal = direction / length
        let front = simd_max(normal, .zero), back = simd_max(-normal, .zero)
        // Squared cosine weights sum to one and remain continuous across axes.
        // Include the upward-facing bodywork even in a low side-on composition.
        let facing = simd_dot(front * front, positive) + simd_dot(back * back, negative)
        let metered = 0.72 * facing + 0.28 * positive.y
        let stops = 0.5 * log2(max(0.001, reference) / max(0.001, metered))
        return min(0.45, max(-0.45, stops))
    }
}
