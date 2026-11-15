import RealityKit

/// A smoked cover over separate, opaque reflector and emitter geometry. These
/// source materials have a uniform neutral tint and an independently set alpha.
struct LampLens {
    let substrate: Float
    let roughness: Float
    // Representative automotive optical polycarbonate, not an APK constant.
    static let indexOfRefraction: Float = 1.585

    init?(material: PhysicallyBasedMaterial) {
        guard let name = material.name?.lowercased(),
              name.hasPrefix("glass_lights_"),
              case .transparent(let opacity) = material.blending,
              opacity.texture == nil, material.baseColor.texture == nil,
              material.roughness.texture == nil else { return nil }

        // Match the source's face-on transmission, then solve for the internal
        // attenuation of a sheet with two reflecting interfaces.
        let pass = 1 - min(1, max(0, Float(material.baseColor.tint.cgColor.alpha) * opacity.scale))
        substrate = Self.substrate(normalTransmission: pass)
        roughness = material.roughness.scale
    }

    static func substrate(normalTransmission pass: Float) -> Float {
        let ior = indexOfRefraction
        let r = (ior - 1) / (ior + 1)
        let f = r * r
        let direct = (1 - f) * (1 - f)
        return min(1, 2 * pass / (direct + sqrt(direct * direct + 4 * f * f * pass * pass)))
    }
}
