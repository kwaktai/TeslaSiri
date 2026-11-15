import CoreGraphics
import RealityKit
import simd

/// One source draw can contain both ends of the car. Bound each connected
/// lens independently so a narrow highlight doesn't supersample the whole car.
@MainActor struct LampCoverage {
    private var boxes = [ObjectIdentifier: [BoundingBox]]()
    private var triangleClusters = [ObjectIdentifier: [BoundingBox]]()

    mutating func islands(of mesh: MeshResource) -> [BoundingBox] {
        let id = ObjectIdentifier(mesh)
        if let cached = boxes[id] { return cached }
        let contents = mesh.contents
        var result = [BoundingBox]()
        for model in contents.models {
            let transforms = contents.instances.filter { $0.model == model.id }.map(\.transform)
            for part in model.parts {
                let positions = part.positions.elements
                guard let indices = part.triangleIndices?.elements, !indices.isEmpty else { continue }
                var parent = Array(positions.indices)
                func root(_ i: Int) -> Int {
                    var j = i
                    while parent[j] != j { parent[j] = parent[parent[j]]; j = parent[j] }
                    return j
                }
                // Reconnect duplicate vertices at UV and normal seams.
                var welded = [SIMD3<Float>: Int]()
                for (i, p) in positions.enumerated() {
                    if let j = welded[p] { parent[i] = j } else { welded[p] = i }
                }
                for i in stride(from: 0, to: indices.count, by: 3) {
                    let a = root(Int(indices[i])), b = root(Int(indices[i+1])), c = root(Int(indices[i+2]))
                    parent[b] = a; parent[c] = a
                }
                var islands = [Int: BoundingBox]()
                for i in positions.indices {
                    let key = root(i), p = positions[i]
                    islands[key, default: .empty].formUnion(BoundingBox(min: p, max: p))
                }
                for key in islands.keys.sorted() {
                    for transform in transforms.isEmpty ? [matrix_identity_float4x4] : transforms {
                        result.append(islands[key]!.transformed(by: transform))
                    }
                }
            }
        }
        boxes[id] = result
        return result
    }

    /// Cluster whole triangles once, so long curved lamps can use tighter
    /// screen-space work bounds while retaining the original island projection.
    mutating func clusters(of mesh: MeshResource) -> [BoundingBox] {
        let key = ObjectIdentifier(mesh)
        if let existing = triangleClusters[key] { return existing }
        let contents = mesh.contents
        var result = [BoundingBox]()
        for model in contents.models {
            let transforms = contents.instances.filter { $0.model == model.id }.map(\.transform)
            for part in model.parts {
                let points = part.positions.elements
                guard let indices = part.triangleIndices?.elements else { continue }
                var triangles = [BoundingBox]()
                for i in stride(from: 0, to: indices.count, by: 3) {
                    let a = points[Int(indices[i])], b = points[Int(indices[i+1])], c = points[Int(indices[i+2])]
                    triangles.append(BoundingBox(min: simd_min(a, simd_min(b, c)), max: simd_max(a, simd_max(b, c))))
                }
                func partition(_ boxes: [BoundingBox]) {
                    guard !boxes.isEmpty else { return }
                    let bounds = boxes.reduce(into: BoundingBox.empty) { $0.formUnion($1) }
                    if boxes.count <= 16 {
                        for transform in transforms.isEmpty ? [matrix_identity_float4x4] : transforms {
                            result.append(bounds.transformed(by: transform))
                        }
                        return
                    }
                    let ext = bounds.extents
                    let axis = ext.x >= max(ext.y, ext.z) ? 0 : (ext.y >= ext.z ? 1 : 2)
                    let sorted = boxes.sorted { $0.center[axis] < $1.center[axis] }
                    let middle = sorted.count / 2
                    partition(Array(sorted[..<middle]))
                    partition(Array(sorted[middle...]))
                }
                partition(triangles)
            }
        }
        triangleClusters[key] = result
        return result
    }

    static func patch(_ world: BoundingBox, camera: simd_float4x4, focal: Float, viewport: CGRect) -> CGRect? {
        let b = world.transformed(by: camera)
        let near = max(0.035, -b.max.z), far = -b.min.z
        guard far >= near else { return nil }
        let l = Float(viewport.midX) + focal * min(b.min.x / near, b.min.x / far)
        let r = Float(viewport.midX) + focal * max(b.max.x / near, b.max.x / far)
        let t = Float(viewport.midY) - focal * max(b.max.y / near, b.max.y / far)
        let d = Float(viewport.midY) - focal * min(b.min.y / near, b.min.y / far)
        let rect = CGRect(x: CGFloat(l), y: CGFloat(t), width: CGFloat(r-l), height: CGFloat(d-t))
            .insetBy(dx: -1, dy: -1).integral.intersection(viewport)
        return rect.isEmpty ? nil : rect
    }

    static func tiles(_ regions: [CGRect], within sensor: CGRect) -> [CGRect] {
        // A close-up may fill the sensor. Split large regions to bound the
        // transient Metal targets even for a full-resolution exported still.
        var tiles = [CGRect]()
        for area in StudioWheelView.merged(regions) {
            let region = area.intersection(sensor)
            guard !region.isEmpty else { continue }
            for y in stride(from: Int(region.minY), to: Int(region.maxY), by: 96) {
                for x in stride(from: Int(region.minX), to: Int(region.maxX), by: 128) {
                    tiles.append(CGRect(x: x, y: y, width: 128, height: 96).intersection(region))
                }
            }
        }
        return tiles
    }
}
