/// Builds the personal city: every repo's district placed on one plan, oldest first, in rows.
/// Districts are never regenerated here; each keeps the exact geometry its own repo published,
/// so the generator lives in one place and a district looks identical alone and in the city.
public enum CityMerger {
    /// Empty lots between neighbouring districts. A multiple of the block pitch keeps every
    /// district's road grid aligned with its neighbours'.
    public static let districtGap = District.blockPitch * 2

    public static func merge(_ cities: [City], name: String, generatedAt: Int64) -> City {
        var districts = cities.flatMap(\.districts)

        // Ids must be unique for the viewer's hover and replay bookkeeping.
        var seen = [String: Int]()
        for index in districts.indices {
            let id = districts[index].id
            let count = seen[id, default: 0] + 1
            seen[id] = count
            if count > 1 { districts[index].id = "\(id)-\(count)" }
        }

        districts.sort { ($0.firstCommitAt, $0.id) < ($1.firstCommitAt, $1.id) }

        struct Footprint {
            var minX: Int, minY: Int, width: Int, height: Int
        }
        let footprints: [Footprint?] = districts.map { district in
            district.localLotBounds.map {
                Footprint(minX: $0.minX, minY: $0.minY, width: $0.maxX - $0.minX + 1, height: $0.maxY - $0.minY + 1)
            }
        }

        // Shelf packing toward a roughly square plan (in lot space; the isometric view turns the
        // square into the familiar diamond).
        let area = footprints.compactMap { $0 }.reduce(0) { $0 + ($1.width + districtGap) * ($1.height + districtGap) }
        let widest = footprints.compactMap { $0?.width }.max() ?? 0
        let rowLimit = max(widest, Int((Double(area).squareRoot() * 1.1).rounded(.up)))

        var cursorX = 0, cursorY = 0, rowHeight = 0
        for index in districts.indices {
            guard let footprint = footprints[index] else {
                districts[index].offset = GridPoint(0, 0)
                continue
            }
            if cursorX > 0, cursorX + footprint.width > rowLimit {
                cursorX = 0
                cursorY += alignUp(rowHeight + districtGap)
                rowHeight = 0
            }
            districts[index].offset = GridPoint(cursorX - footprint.minX, cursorY - footprint.minY)
            cursorX += alignUp(footprint.width + districtGap)
            rowHeight = max(rowHeight, footprint.height)
        }

        return City(name: name, generatedAt: generatedAt, districts: districts)
    }

    static func alignUp(_ value: Int) -> Int {
        let pitch = District.blockPitch
        return (value + pitch - 1) / pitch * pitch
    }
}
