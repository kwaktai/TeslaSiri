import CoreGraphics
import RealityKit
import simd

/// Integer, top-left raster regions and the lens used to render them. Off-axis
/// projection changes the sampled rays, not the eye position or view direction.
struct StudioWheelView {
    let width, height: Int
    let focal, near, far: Float
    static let margin = 6

    init(_ camera: PerspectiveCameraComponent, width: Int, height: Int) {
        self.width = width; self.height = height
        let axis = camera.fieldOfViewOrientation == .horizontal ? width : height
        focal = Float(axis) / (2*tan(camera.fieldOfViewInDegrees * .pi/360))
        near = camera.near; far = camera.far
    }

    var viewport: CGRect { CGRect(x:0,y:0,width:width,height:height) }

    func region(for b: BoundingBox) -> CGRect? {
        // Bounds are in camera space, looking down -Z. Clip before projecting,
        // including when a host moves the lens close enough to cross a wheel.
        let n = max(near,-b.max.z), f = min(far,-b.min.z)
        guard focal.isFinite, n > 0, n.isFinite, f.isFinite, n <= f else { return nil }
        let l = Float(width)/2 + focal*min(b.min.x/n,b.min.x/f)
        let r = Float(width)/2 + focal*max(b.max.x/n,b.max.x/f)
        let t = Float(height)/2 - focal*max(b.max.y/n,b.max.y/f)
        let d = Float(height)/2 - focal*min(b.min.y/n,b.min.y/f)
        guard l.isFinite, r.isFinite, t.isFinite, d.isFinite, r > l, d > t else { return nil }
        let box = CGRect(x:CGFloat(l),y:CGFloat(t),width:CGFloat(r-l),height:CGFloat(d-t))
        let rect = box.insetBy(dx:-CGFloat(Self.margin),dy:-CGFloat(Self.margin)).integral.intersection(viewport)
        return rect.isEmpty ? nil : rect
    }

    func projection(for rect: CGRect) -> simd_float4x4 {
        let w = Float(rect.width), h = Float(rect.height)
        let x = (2*Float(rect.minX)+w-Float(width))/w
        let y = (Float(height)-2*Float(rect.minY)-h)/h
        // RealityRenderer uses reverse Z. The parked lens defaults to an
        // infinite far plane; don't evaluate infinity / infinity for that case.
        let z: Float = far.isFinite ? near/(far-near) : 0
        return simd_float4x4(columns:([2*focal/w,0,0,0],[0,2*focal/h,0,0],[x,y,z,-1],[0,0,near*(1+z),0]))
    }

    static func merged(_ rectangles: [CGRect]) -> [CGRect] {
        var pending = rectangles, result = [CGRect]()
        while var rect = pending.popLast() {
            while let i = pending.firstIndex(where:{ $0.intersects(rect) }) {
                rect = rect.union(pending.remove(at:i))
            }
            result.append(rect)
        }
        return result
    }

    static func detailLevel(_ regions: [CGRect], above base: Int) -> Int? {
        let area = regions.reduce(0) { $0 + Int($1.width)*Int($1.height) }
        // Keep both passes bounded on mobile, even in a wheel-filling close-up.
        return [3,2,1].first { area > 0 && $0 > base && area*(1 << (2*$0)) <= 24_000_000 }
    }
}
