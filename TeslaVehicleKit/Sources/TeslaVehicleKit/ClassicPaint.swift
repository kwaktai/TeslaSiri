import RealityKit

@MainActor enum ClassicPaint {
    /// RGB is the source GLES2 albedo coefficient. Named finishes supply it
    /// directly, while the public color picker decodes its sRGB input once.
    static func apply(to graph: inout ShaderGraphMaterial, rgb: SIMD3<Float>,
                      metallic: Float, roughness: Float, deepenUltraRed: Bool) throws {
        try graph.setParameter(name: "PaintRGB", value: .simd3Float(rgb))
        try graph.setParameter(name: "Metallic", value: .float(metallic))
        try graph.setParameter(name: "Roughness", value: .float(roughness))
        if graph.parameterNames.contains("DeepenUltraRed") {
            try graph.setParameter(name: "DeepenUltraRed", value: .float(deepenUltraRed ? 1 : 0))
        }
    }
}
