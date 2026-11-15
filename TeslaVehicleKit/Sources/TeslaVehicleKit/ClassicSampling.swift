import CoreGraphics

/// Each pixel integrates complete, independently shaded rays. Keep the common
/// viewport in one draw and divide large exports into identical off-axis tiles.
struct ClassicSampling {
    let grid: Int
    let tileWidth: Int
    let tileHeight: Int
    let tiles: [CGRect]

    init(width: Int, height: Int) {
        let pixelBudget = 10_000_000
        let sideLimit = 4096
        let longest = max(width, height)
        grid = [4, 3].first { longest * $0 <= sideLimit && width * height * $0 * $0 <= pixelBudget } ?? 2
        // Split both axes of a large frame evenly. A partially visible final
        // row/column still uses the same texture allocation and sample phase.
        var columns = (width * grid + sideLimit - 1) / sideLimit
        var rows = (height * grid + sideLimit - 1) / sideLimit
        var w = (width + columns - 1) / columns
        var h = (height + rows - 1) / rows
        while w * h * grid * grid > pixelBudget {
            if w >= h {
                columns += 1
                w = (width + columns - 1) / columns
            } else {
                rows += 1
                h = (height + rows - 1) / rows
            }
        }
        tileWidth = w
        tileHeight = h
        tiles = (0..<rows).flatMap { row in
            (0..<columns).map { column in CGRect(x: column*w, y: row*h, width: w, height: h) }
        }
    }
}
