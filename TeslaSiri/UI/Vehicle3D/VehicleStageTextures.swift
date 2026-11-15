import CoreGraphics
import RealityKit
import UIKit

/// Small procedural textures for the stage: the contact shadow under the car, the status
/// tire contact patches, the road pool that fades into the page, and soft glow sprites.
/// Each is an opaque grayscale mask (white = fully visible) used as an opacity texture,
/// so a material tint supplies the color.
@MainActor
enum VehicleStageTextures {
    /// Soft elliptical contact shadow, darkest under the body.
    static let contactShadow: TextureResource? = radial(size: 256, stops: [
        (0.0, 0.62), (0.45, 0.5), (0.72, 0.22), (1.0, 0)
    ])

    /// Road surface pool: opaque in the middle, dissolving to nothing at the edges.
    static let roadPool: TextureResource? = radial(size: 512, stops: [
        (0.0, 1), (0.42, 0.92), (0.7, 0.45), (1.0, 0)
    ])

    /// Soft round glow for light sprites such as the charge-port indicator.
    static let glow: TextureResource? = radial(size: 128, stops: [
        (0.0, 1), (0.25, 0.7), (0.6, 0.18), (1.0, 0)
    ])

    /// Lane-line dash with feathered ends so it fades rather than pops.
    static let dash: TextureResource? = linear(width: 8, height: 64, stops: [
        (0.0, 0), (0.12, 1), (0.88, 1), (1.0, 0)
    ])

    private static func radial(size: Int, stops: [(CGFloat, CGFloat)]) -> TextureResource? {
        draw(width: size, height: size) { context in
            let colors = stops.map { CGColor(gray: $0.1, alpha: 1) } as CFArray
            let locations = stops.map(\.0)
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
            let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size) / 2, options: [])
        }
    }

    private static func linear(width: Int, height: Int, stops: [(CGFloat, CGFloat)]) -> TextureResource? {
        draw(width: width, height: height) { context in
            let colors = stops.map { CGColor(gray: $0.1, alpha: 1) } as CFArray
            let locations = stops.map(\.0)
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [])
        }
    }

    private static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> TextureResource? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        body(context)
        guard let image = context.makeImage() else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .raw))
    }
}

extension UnlitMaterial {
    /// Unlit, alpha-blended material whose shape comes from a procedural opacity mask.
    /// The color's own alpha scales the mask.
    @MainActor
    static func stageSprite(_ mask: TextureResource?, color: UIColor) -> UnlitMaterial {
        let alpha = color.cgColor.alpha
        var material = UnlitMaterial(color: color.withAlphaComponent(1))
        if let mask {
            material.blending = .transparent(opacity: .init(scale: Float(alpha), texture: .init(mask)))
        } else {
            material.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
        }
        material.faceCulling = .none
        return material
    }
}

extension UnlitMaterial {
    /// Flat material for the floor reflection, culling front faces because the mirror's
    /// negative scale reverses winding.
    @MainActor
    static func reflection(_ color: UIColor, brightness: CGFloat) -> UnlitMaterial {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var material = UnlitMaterial(color: UIColor(red: red * brightness, green: green * brightness, blue: blue * brightness, alpha: 1))
        material.faceCulling = .front
        return material
    }
}
