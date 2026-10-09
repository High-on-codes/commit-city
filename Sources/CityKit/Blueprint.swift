import Foundation

// The blueprint geometry: every line the city is drawn with, in world space, before projection.
// The SVG renderer and the SwiftUI widget both consume this; the web viewer carries a line-for-line
// JavaScript port (viewer/index.html, `geometry`), kept honest by Tests/CityKitTests/ViewerParityTests.
// Any change here must be mirrored there.
//
// World space: x and y in lot units on the ground, z up. The viewer looks from +x, +y, +z, so the
// visible faces of a box are its top, its +x face and its +y face.

public struct Vec3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Line classes. Colours, weights and base alphas come from the theme; decay only scales alpha.
public enum Ink: Int, Sendable, CaseIterable {
    case structure = 0
    case detail = 1
    case windowLit = 2
    case windowDark = 3
    case ground = 4
    case landmark = 5
    case accent = 6
    /// Dashed road centreline between two claimed blocks.
    case road = 7
}

public enum Primitive: Sendable, Equatable {
    /// Filled with the background colour and never stroked: hidden-line removal for the painter's
    /// algorithm, not a visible fill.
    case occluder([Vec3])
    case line([Vec3], Ink, closed: Bool)
    /// A screen-space circle (tree canopies, beacons). Occludes, then strokes.
    case disc(Vec3, radius: Double, Ink)
}

public enum DetailLevel: Sendable {
    case full
    /// No windows, mullions or floor bands: for large cities and tiny widgets.
    case reduced
    /// Huge cities: each block is drawn as one massing volume at its typical height, with sparse
    /// lit bands. Landmarks, the newest building and finished beacons are still drawn individually.
    /// At the scale such a city is shown whole, a single building is a pixel or two anyway.
    case massing
}

public enum Blueprint {
    public static let floorHeight = 0.16
    static let windowCellWidth = 0.16
    static let maxRepairsDrawn = 6

    public static let cos30 = 0.866_025_403_784_438_6

    /// Isometric projection to unscaled screen space (y down).
    @inlinable
    public static func project(_ point: Vec3) -> (x: Double, y: Double) {
        ((point.x - point.y) * cos30, (point.x + point.y) * 0.5 - point.z)
    }

    // MARK: Building geometry

    /// Primitives for one building as of `time` (repairs and trees planted later are omitted).
    public static func primitives(
        for building: Building, offset: GridPoint, time: Int64, detail: DetailLevel, isNewest: Bool = false
    ) -> [Primitive] {
        var out = [Primitive]()
        let cx = Double(building.lot.x + offset.x) + 0.5
        let cy = Double(building.lot.y + offset.y) + 0.5
        let x0 = cx - building.width / 2, x1 = cx + building.width / 2
        let y0 = cy - building.depth / 2, y1 = cy + building.depth / 2
        let height = Double(building.floors) * floorHeight
        let structure: Ink = isNewest ? .accent : (building.isLandmark ? .landmark : .structure)
        let windows = detail == .full

        switch building.style {
        case .park:
            out.append(.line([Vec3(x0, y0, 0), Vec3(x1, y0, 0), Vec3(x1, y1, 0), Vec3(x0, y1, 0)], .ground, closed: true))
            var trees = [(x: Double, y: Double, index: Int)]()
            for (index, planted) in building.trees.enumerated() where planted <= time {
                let u = 0.18 + 0.64 * detailUnit(building.seed, 7, index)
                let v = 0.18 + 0.64 * detailUnit(building.seed, 8, index)
                trees.append((x0 + u * building.width, y0 + v * building.depth, index))
            }
            trees.sort { ($0.x + $0.y, $0.index) < ($1.x + $1.y, $1.index) }
            for tree in trees {
                out.append(.line([Vec3(tree.x, tree.y, 0), Vec3(tree.x, tree.y, 0.16)], structure, closed: false))
                out.append(.disc(Vec3(tree.x, tree.y, 0.25), radius: 0.09, structure))
            }
            return out

        case .glassTower:
            box(&out, x0, x1, y0, y1, 0, height, structure)
            let columnsX = max(2, Int(building.width / 0.14))
            let columnsY = max(2, Int(building.depth / 0.14))
            if windows {
                for k in 1..<columnsY {
                    let y = y0 + building.depth * Double(k) / Double(columnsY)
                    out.append(.line([Vec3(x1, y, 0), Vec3(x1, y, height)], .detail, closed: false))
                }
                for k in 1..<columnsX {
                    let x = x0 + building.width * Double(k) / Double(columnsX)
                    out.append(.line([Vec3(x, y1, 0), Vec3(x, y1, height)], .detail, closed: false))
                }
                windowGrid(&out, building, face: .east(x1), from: y0, to: y1, z0: 0, floors: building.floors, columns: columnsY, faceID: 0)
                windowGrid(&out, building, face: .south(y1), from: x0, to: x1, z0: 0, floors: building.floors, columns: columnsX, faceID: 1)
            }
            if building.floors >= 14 && !building.isLandmark {
                out.append(.line([Vec3(cx, cy, height), Vec3(cx, cy, height + 0.35)], .detail, closed: false))
            }

        case .lowBlock:
            box(&out, x0, x1, y0, y1, 0, height, structure)
            if windows {
                for floor in 1..<max(1, building.floors) {
                    let z = Double(floor) * floorHeight
                    out.append(.line([Vec3(x1, y0, z), Vec3(x1, y1, z), Vec3(x0, y1, z)], .detail, closed: false))
                }
                windowGrid(&out, building, face: .east(x1), from: y0, to: y1, z0: 0, floors: building.floors, columns: cells(building.depth), faceID: 0)
                windowGrid(&out, building, face: .south(y1), from: x0, to: x1, z0: 0, floors: building.floors, columns: cells(building.width), faceID: 1)
            }

        case .factory:
            box(&out, x0, x1, y0, y1, 0, height, structure)
            if windows {
                windowGrid(&out, building, face: .south(y1), from: x0, to: x1, z0: 0, floors: building.floors, columns: cells(building.width), faceID: 1)
                windowGrid(&out, building, face: .east(x1), from: y0, to: y1, z0: 0, floors: building.floors, columns: cells(building.depth), faceID: 0)
            }
            let chimneySide = min(0.12, building.width * 0.22)
            box(&out, x0 + 0.05, x0 + 0.05 + chimneySide, y0 + 0.05, y0 + 0.05 + chimneySide, height, height + 0.42 + 0.02 * Double(building.floors), structure)
            let teeth = max(2, Int(building.width / 0.2))
            let toothWidth = building.width / Double(teeth)
            let toothHeight = 0.14
            for k in 0..<teeth {
                let xa = x0 + toothWidth * Double(k)
                let xb = xa + toothWidth
                let top = height + toothHeight
                out.append(.occluder([Vec3(xa, y0, height), Vec3(xb, y0, top), Vec3(xb, y1, top), Vec3(xa, y1, height)]))
                out.append(.occluder([Vec3(xb, y0, height), Vec3(xb, y0, top), Vec3(xb, y1, top), Vec3(xb, y1, height)]))
                // Slope outline (valley, both rakes, ridge), then the vertical glazing face.
                out.append(.line([Vec3(xa, y0, height), Vec3(xb, y0, top), Vec3(xb, y1, top), Vec3(xa, y1, height)], structure, closed: true))
                out.append(.line([Vec3(xb, y0, top), Vec3(xb, y0, height), Vec3(xb, y1, height), Vec3(xb, y1, top)], structure, closed: false))
            }

        case .steppedTower:
            let tiers: [Int]
            if building.floors >= 6 {
                let first = (building.floors + 1) / 2
                let second = max(1, (building.floors * 3 + 9) / 10)
                tiers = [first, second, max(1, building.floors - first - second)]
            } else {
                tiers = [building.floors]
            }
            let inset = min(building.width, building.depth) * 0.14
            var base = 0.0
            for (tier, tierFloors) in tiers.enumerated() {
                let shrink = inset * Double(tier)
                let top = base + Double(tierFloors) * floorHeight
                let tx0 = x0 + shrink, tx1 = x1 - shrink, ty0 = y0 + shrink, ty1 = y1 - shrink
                box(&out, tx0, tx1, ty0, ty1, base, top, structure)
                if windows {
                    windowGrid(&out, building, face: .east(tx1), from: ty0, to: ty1, z0: base, floors: tierFloors, columns: cells(ty1 - ty0), faceID: tier * 2)
                    windowGrid(&out, building, face: .south(ty1), from: tx0, to: tx1, z0: base, floors: tierFloors, columns: cells(tx1 - tx0), faceID: tier * 2 + 1)
                }
                base = top
            }

        case .slab:
            box(&out, x0, x1, y0, y1, 0, height, structure)
            if windows {
                windowGrid(&out, building, face: .east(x1), from: y0, to: y1, z0: 0, floors: building.floors, columns: cells(building.depth), faceID: 0)
                windowGrid(&out, building, face: .south(y1), from: x0, to: x1, z0: 0, floors: building.floors, columns: cells(building.width), faceID: 1)
            }
            if building.floors >= 10 {
                let mw = building.width * 0.35, md = building.depth * 0.35
                box(&out, cx - mw / 2, cx + mw / 2, cy - md / 2, cy + md / 2, height, height + 0.12, .detail)
            }

        case .gabled:
            box(&out, x0, x1, y0, y1, 0, height, structure)
            if windows {
                windowGrid(&out, building, face: .east(x1), from: y0, to: y1, z0: 0, floors: building.floors, columns: cells(building.depth), faceID: 0)
                windowGrid(&out, building, face: .south(y1), from: x0, to: x1, z0: 0, floors: building.floors, columns: cells(building.width), faceID: 1)
            }
            let ym = (y0 + y1) / 2
            let ridge = height + building.depth * 0.35
            out.append(.occluder([Vec3(x0, y0, height), Vec3(x1, y0, height), Vec3(x1, ym, ridge), Vec3(x0, ym, ridge)]))
            out.append(.occluder([Vec3(x0, ym, ridge), Vec3(x1, ym, ridge), Vec3(x1, y1, height), Vec3(x0, y1, height)]))
            out.append(.occluder([Vec3(x1, y0, height), Vec3(x1, ym, ridge), Vec3(x1, y1, height)]))
            out.append(.line([Vec3(x0, y1, height), Vec3(x0, ym, ridge), Vec3(x0, y0, height), Vec3(x1, y0, height)], structure, closed: false))
            out.append(.line([Vec3(x0, ym, ridge), Vec3(x1, ym, ridge)], structure, closed: false))
            out.append(.line([Vec3(x1, y0, height), Vec3(x1, ym, ridge), Vec3(x1, y1, height), Vec3(x0, y1, height)], structure, closed: false))
        }

        // Fixes leave scaffolding: one braced bay per repair along the +y face.
        let repairs = min(maxRepairsDrawn, building.repairs.reduce(0) { $0 + ($1 <= time ? 1 : 0) })
        if repairs > 0 {
            let bay = min(0.12, building.width / Double(maxRepairsDrawn))
            let top = min(height, 0.34)
            for k in 0..<repairs {
                let xa = x0 + building.width * (Double(k) + 0.5) / Double(maxRepairsDrawn) - bay / 2
                let xb = xa + bay
                out.append(.line([Vec3(xa, y1, 0), Vec3(xa, y1, top), Vec3(xb, y1, top), Vec3(xb, y1, 0)], .detail, closed: false))
                out.append(.line([Vec3(xa, y1, 0), Vec3(xb, y1, top)], .detail, closed: false))
                out.append(.line([Vec3(xb, y1, 0), Vec3(xa, y1, top)], .detail, closed: false))
            }
        }

        if building.isLandmark {
            let top = buildingTop(building)
            out.append(.line([Vec3(cx, cy, top), Vec3(cx, cy, top + 1.2)], .landmark, closed: false))
            out.append(.disc(Vec3(cx, cy, top + 1.2), radius: 0.05, .accent))
        }
        return out
    }

    /// Roof height of the building's highest part.
    public static func buildingTop(_ building: Building) -> Double {
        let height = Double(building.floors) * floorHeight
        switch building.style {
        case .gabled: return height + building.depth * 0.35
        case .factory: return height + 0.14
        default: return height
        }
    }

    /// Permanent lit mark for finished districts, mounted on its tallest building.
    public static func finishedBeacon(on building: Building, offset: GridPoint) -> [Primitive] {
        let cx = Double(building.lot.x + offset.x) + 0.5
        let cy = Double(building.lot.y + offset.y) + 0.5
        let top = buildingTop(building) + (building.isLandmark ? 1.2 : 0)
        return [
            .line([Vec3(cx, cy, top), Vec3(cx, cy, top + 0.6)], .accent, closed: false),
            .disc(Vec3(cx, cy, top + 0.6), radius: 0.16, .accent),
            .disc(Vec3(cx, cy, top + 0.6), radius: 0.07, .accent),
        ]
    }

    /// Curb outline of a block; plazas get an inner ring around their landmark. A road centreline
    /// runs along the east/south edge when the neighbouring block exists, so roads appear exactly
    /// where the city has grown.
    public static func blockPrimitives(
        _ block: Block, offset: GridPoint, eastClaimed: Bool, southClaimed: Bool
    ) -> [Primitive] {
        let ox = Double(block.at.x * District.blockPitch + offset.x)
        let oy = Double(block.at.y * District.blockPitch + offset.y)
        let size = Double(District.blockSize)
        let road = (Double(District.blockPitch) + size) / 2
        var out: [Primitive] = [rectangle(ox - 0.15, oy - 0.15, ox + size + 0.15, oy + size + 0.15, .ground)]
        if block.isPlaza {
            out.append(rectangle(ox + 0.1, oy + 0.1, ox + size - 0.1, oy + size - 0.1, .ground))
        }
        if eastClaimed {
            out.append(.line([Vec3(ox + road, oy - 0.5, 0), Vec3(ox + road, oy + size + 0.5, 0)], .road, closed: false))
        }
        if southClaimed {
            out.append(.line([Vec3(ox - 0.5, oy + road, 0), Vec3(ox + size + 0.5, oy + road, 0)], .road, closed: false))
        }
        return out
    }

    /// One massing volume for a block: 75th-percentile roof height of what stands on it.
    public static func massingPrimitives(
        blockAt at: GridPoint, offset: GridPoint, tops: [Double], litWindows: Double
    ) -> [Primitive] {
        guard !tops.isEmpty else { return [] }
        let sorted = tops.sorted()
        let height = sorted[(sorted.count * 3) / 4]
        let ox = Double(at.x * District.blockPitch + offset.x)
        let oy = Double(at.y * District.blockPitch + offset.y)
        let size = Double(District.blockSize)
        let x0 = ox + 0.15, x1 = ox + size - 0.15, y0 = oy + 0.15, y1 = oy + size - 0.15
        var out = [Primitive]()
        box(&out, x0, x1, y0, y1, 0, height, .structure)
        let seed = detailHash(0x5EED, at.x, at.y)
        let rows = Int(height / (3 * floorHeight))
        for row in 0..<rows {
            let z = (Double(row) * 3 + 1.5) * floorHeight
            for column in 0..<4 {
                let start = Double(column) * 0.66 + 0.3
                if detailUnit(seed, row, column) < litWindows {
                    out.append(.line([Vec3(x1, y0 + start, z), Vec3(x1, y0 + start + 0.3, z)], .windowLit, closed: false))
                }
                if detailUnit(seed, 4096 + row, column) < litWindows {
                    out.append(.line([Vec3(x0 + start, y1, z), Vec3(x0 + start + 0.3, y1, z)], .windowLit, closed: false))
                }
            }
        }
        return out
    }

    static func rectangle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ ink: Ink) -> Primitive {
        .line([Vec3(x0, y0, 0), Vec3(x1, y0, 0), Vec3(x1, y1, 0), Vec3(x0, y1, 0)], ink, closed: true)
    }

    // MARK: Pieces

    /// An axis-aligned box: occluding silhouette, then its nine visible edges.
    static func box(
        _ out: inout [Primitive], _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, _ z0: Double,
        _ z1: Double, _ ink: Ink
    ) {
        out.append(.occluder([
            Vec3(x0, y0, z1), Vec3(x1, y0, z1), Vec3(x1, y0, z0), Vec3(x1, y1, z0), Vec3(x0, y1, z0), Vec3(x0, y1, z1),
        ]))
        out.append(.line([Vec3(x0, y0, z1), Vec3(x1, y0, z1), Vec3(x1, y1, z1), Vec3(x0, y1, z1)], ink, closed: true))
        out.append(.line([Vec3(x0, y1, z1), Vec3(x0, y1, z0), Vec3(x1, y1, z0), Vec3(x1, y0, z0), Vec3(x1, y0, z1)], ink, closed: false))
        out.append(.line([Vec3(x1, y1, z0), Vec3(x1, y1, z1)], ink, closed: false))
    }

    enum Face {
        /// The +x face at the given x.
        case east(Double)
        /// The +y face at the given y.
        case south(Double)
    }

    static func cells(_ length: Double) -> Int {
        max(1, Int(length / windowCellWidth))
    }

    /// One short horizontal tick per window; lit ones are chosen by a stable hash against the
    /// building's streak-derived lit fraction, so they light up progressively, never randomly.
    static func windowGrid(
        _ out: inout [Primitive], _ building: Building, face: Face, from a0: Double, to a1: Double, z0: Double,
        floors: Int, columns: Int, faceID: Int
    ) {
        guard floors > 0, columns > 0, a1 > a0 else { return }
        let cell = (a1 - a0) / Double(columns)
        for floor in 0..<floors {
            let z = z0 + (Double(floor) + 0.45) * floorHeight
            for column in 0..<columns {
                let start = a0 + cell * (Double(column) + 0.28)
                let end = a0 + cell * (Double(column) + 0.72)
                let lit = detailUnit(building.seed, faceID * 4096 + floor, column) < building.litWindows
                let ink: Ink = lit ? .windowLit : .windowDark
                switch face {
                case let .east(x): out.append(.line([Vec3(x, start, z), Vec3(x, end, z)], ink, closed: false))
                case let .south(y): out.append(.line([Vec3(start, y, z), Vec3(end, y, z)], ink, closed: false))
                }
            }
        }
    }
}

// MARK: - Scene

@inlinable
func floorDivide(_ value: Int, _ divisor: Int) -> Int {
    value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
}

/// Everything to draw, already in painter's order.
public struct Scene: Sendable {
    public struct Item: Sendable {
        public var district: Int
        /// `nil` for ground items (blocks).
        public var building: Int?
        public var look: BuildingLook
        public var primitives: [Primitive]
    }

    public var items: [Item]
    public var buildingCount: Int

    /// Projected bounds (unscaled), or `nil` for an empty scene.
    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func include(_ point: Vec3, _ pad: Double = 0) {
            let p = Blueprint.project(point)
            minX = min(minX, p.x - pad)
            maxX = max(maxX, p.x + pad)
            minY = min(minY, p.y - pad)
            maxY = max(maxY, p.y + pad)
        }
        for item in items {
            for primitive in item.primitives {
                switch primitive {
                case let .occluder(points), let .line(points, _, _): points.forEach { include($0) }
                case let .disc(center, radius, _): include(center, radius)
                }
            }
        }
        return minX.isFinite ? (minX, minY, maxX, maxY) : nil
    }

    /// Builds the scene as it stood at `time` (pass `city.generatedAt` for "now"). Decay is
    /// evaluated at the same instant, so a replay shows each moment as it looked then.
    public static func build(city: City, at time: Int64, detail: DetailLevel = .full) -> Scene {
        var ground = [Item]()
        var standing = [(key: (Double, Double, Int, Int), item: Item)]()
        var newest: (time: Int64, district: Int, id: Int)?

        for (districtIndex, district) in city.districts.enumerated() {
            for building in district.buildings where building.bornAt <= time && building.style != .park {
                let candidate = (building.bornAt, districtIndex, building.id)
                if newest == nil || candidate > (newest!.time, newest!.district, newest!.id) {
                    newest = candidate
                }
            }
        }

        var buildingCount = 0
        for (districtIndex, district) in city.districts.enumerated() {
            let groundLook = BuildingLook.resolve(district: district, neighborhood: -1, now: time)
            var claimed = Set<GridPoint>()
            for block in district.blocks where block.claimedAt <= time {
                claimed.insert(block.at)
            }
            for block in district.blocks where block.claimedAt <= time {
                let east = claimed.contains(GridPoint(block.at.x + 1, block.at.y))
                let south = claimed.contains(GridPoint(block.at.x, block.at.y + 1))
                ground.append(Item(
                    district: districtIndex, building: nil, look: groundLook,
                    primitives: Blueprint.blockPrimitives(
                        block, offset: district.offset, eastClaimed: east, southClaimed: south)))
            }

            let visible = district.buildings.filter { $0.bornAt <= time }
            buildingCount += visible.count
            // The finished beacon crowns the tallest building (ties: the oldest).
            var beaconHost: Int?
            if district.status == .finished {
                beaconHost = visible.filter { $0.style != .park }.max {
                    (Blueprint.buildingTop($0), -$0.id) < (Blueprint.buildingTop($1), -$1.id)
                }?.id
            }
            var massed = [GridPoint: (tops: [Double], lit: Double, neighborhood: Int)]()
            for building in visible {
                let isNewest = newest.map { $0.district == districtIndex && $0.id == building.id } ?? false
                if detail == .massing, !isNewest, !building.isLandmark, building.id != beaconHost {
                    if building.style == .park { continue }
                    let block = GridPoint(
                        floorDivide(building.lot.x, District.blockPitch), floorDivide(building.lot.y, District.blockPitch))
                    var entry = massed[block] ?? ([], 0, building.neighborhood)
                    entry.tops.append(Blueprint.buildingTop(building))
                    entry.lit += building.litWindows
                    massed[block] = entry
                    continue
                }
                var primitives = Blueprint.primitives(
                    for: building, offset: district.offset, time: time, detail: detail, isNewest: isNewest)
                if building.id == beaconHost {
                    primitives += Blueprint.finishedBeacon(on: building, offset: district.offset)
                }
                let cx = Double(building.lot.x + district.offset.x) + 0.5
                let cy = Double(building.lot.y + district.offset.y) + 0.5
                let item = Item(
                    district: districtIndex, building: building.id,
                    look: BuildingLook.resolve(district: district, neighborhood: building.neighborhood, now: time),
                    primitives: primitives)
                standing.append(((cx + cy, cx, districtIndex, building.id), item))
            }
            for (block, entry) in massed {
                let cx = Double(block.x * District.blockPitch + district.offset.x) + 1.5
                let cy = Double(block.y * District.blockPitch + district.offset.y) + 1.5
                let item = Item(
                    district: districtIndex, building: nil,
                    look: BuildingLook.resolve(district: district, neighborhood: entry.neighborhood, now: time),
                    primitives: Blueprint.massingPrimitives(
                        blockAt: block, offset: district.offset, tops: entry.tops,
                        litWindows: entry.lit / Double(entry.tops.count)))
                // -1 sorts a block volume before the individual building on its centre lot.
                standing.append(((cx + cy, cx, districtIndex, -1), item))
            }
        }
        standing.sort { $0.key < $1.key }
        return Scene(items: ground + standing.map(\.item), buildingCount: buildingCount)
    }
}
