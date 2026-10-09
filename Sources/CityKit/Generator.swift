import Foundation

/// The deterministic city generator: a single left fold over the commit history.
///
/// Layout reads only the commit *order* and classification (folder, language, type, size); per
/// building detail (aspect ratio, which windows are lit) reads the content key. SHAs are never an
/// input, so a rebase that keeps content and order rebuilds the identical city, and the same repo
/// yields the same city on every machine. No `Hasher`, `Dictionary` iteration order or stdlib
/// random sampling is ever observable in the output.
public enum CityGenerator {
    /// Commits at or above either threshold become landmarks on a plaza of their own.
    public static let landmarkLines = 3_000
    public static let landmarkFiles = 150
    /// A park holds this many trees before the next docs commit opens a new one.
    public static let treesPerPark = 5
    /// Streak length at which every window of a new building is lit.
    public static let fullStreakDays = 14

    public static func district(
        from commits: [Commit], id: String, name: String, config: RepoConfig = RepoConfig()
    ) -> District {
        var state = State(seed: config.seed ?? commits.first?.contentKey ?? 0)
        for (index, commit) in commits.enumerated() {
            state.apply(commit, index: index)
        }
        let isShape = config.visibility == .shape
        // A shape-only id must not leak the repo name either; derive it from history instead.
        let districtID = isShape ? "private-" + String(SplitMix64.mix(state.seed).hex16.prefix(10)) : id
        var district = District(
            id: districtID,
            name: isShape ? (config.label ?? "private") : (config.label ?? name),
            status: config.status,
            visibility: config.visibility,
            offset: GridPoint(0, 0),
            firstCommitAt: commits.map(\.authorTime).min() ?? 0,
            lastCommitAt: commits.map(\.authorTime).max() ?? 0,
            commitCount: commits.count,
            longestStreakDays: state.longestStreak,
            neighborhoods: state.neighborhoods,
            blocks: state.blocks,
            buildings: state.buildings)
        if isShape {
            district = district.redactedToShape()
        }
        return district
    }

    public static func city(
        from commits: [Commit], name: String, config: RepoConfig = RepoConfig(), generatedAt: Int64
    ) -> City {
        let district = district(from: commits, id: slug(name), name: name, config: config)
        return City(name: district.name, generatedAt: generatedAt, districts: [district])
    }

    /// Lowercase ASCII slug for district ids: "My Repo!" → "my-repo".
    public static func slug(_ text: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in text.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return result.isEmpty ? "city" : result.lowercased()
    }

    // MARK: - Sizing (pure, shared with tests)

    /// Height grows with log(lines)^1.6: a typo is a hut, a thousand-line feature is a tower,
    /// and nothing short of a landmark scrapes the sky.
    public static func baseFloors(linesChanged: Int) -> Int {
        let logLines = log2(Double(max(0, linesChanged)) + 1)
        return min(40, 1 + Int(pow(logLines, 1.6) / 2.4))
    }

    public static func floors(for style: BuildingStyle, base: Int, isLandmark: Bool) -> Int {
        if isLandmark { return min(60, max(22, base + 8)) }
        switch style {
        case .glassTower: return base + 2
        case .lowBlock: return max(1, (base + 1) / 3)
        case .factory: return max(2, (base + 1) / 2)
        case .steppedTower: return max(2, base + 1)
        case .slab: return base
        case .gabled: return max(1, min(4, (base + 2) / 4))
        case .park: return 0
        }
    }

    /// Footprint side from files touched: one file ≈ half a lot, thirty files fill it.
    public static func footprintSide(filesTouched: Int) -> Double {
        let spread = min(1, log2(Double(max(0, filesTouched)) + 1) / 5)
        return 0.40 + 0.42 * spread
    }

    static func quantize(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    // MARK: - Fold state

    struct State {
        let seed: UInt64
        var neighborhoods = [Neighborhood]()
        var neighborhoodByName = [String: Int]()
        var neighborhoodNameHash = [UInt64]()
        /// Running block-coordinate sums per neighborhood, for centroid-seeking growth.
        var blockSums = [(x: Int, y: Int, count: Int)]()
        /// The neighborhood's block that still has free lots, if any.
        var openBlock = [Int?]()
        var blocks = [Block]()
        var lotsUsed = [Int]()
        var claimed = Set<GridPoint>()
        var frontier = Set<GridPoint>()
        var buildings = [Building]()
        var latestBuilding = [Int?]()
        var latestBuildingByLanguage = [[Language: Int]]()
        var latestPark = [Int?]()
        var lastDay: Int64?
        var streak = 0
        var longestStreak = 0

        init(seed: UInt64) {
            self.seed = seed
        }

        /// Lots inside a block, filled back-to-front so newer buildings stand in front.
        static let lotOrder: [GridPoint] = {
            let size = District.blockSize
            var lots = [GridPoint]()
            for j in 0..<size {
                for i in 0..<size { lots.append(GridPoint(i, j)) }
            }
            return lots.sorted { ($0.x + $0.y, $0.x) < ($1.x + $1.y, $1.x) }
        }()

        mutating func apply(_ commit: Commit, index: Int) {
            updateStreak(day: commit.localDay)

            let type = Classifier.commitType(subject: commit.subject)
            let language = Classifier.dominantLanguage(commit)
            let lines = Classifier.linesChanged(commit)
            let files = commit.files.count
            let time = commit.authorTime
            let neighborhood = neighborhoodIndex(Classifier.dominantNeighborhood(commit), time: time)

            let info = CommitInfo(
                index: index, sha: commit.sha, subject: commit.subject, author: commit.authorName,
                time: time, type: type, linesChanged: lines, filesTouched: files)
            let detailSeed = UInt32(truncatingIfNeeded: SplitMix64.mix(commit.contentKey ^ seed))

            if type == .fix || type == .revert, let target = repairTarget(neighborhood, language) {
                buildings[target].repairs.append(time)
                return
            }
            if type == .docs || language == .markdown {
                plantTree(neighborhood, info: info, seed: detailSeed, language: language)
                return
            }
            let isLandmark = lines >= CityGenerator.landmarkLines || files >= CityGenerator.landmarkFiles
            addBuilding(
                neighborhood, info: info, seed: detailSeed, language: language, isLandmark: isLandmark)
        }

        mutating func updateStreak(day: Int64) {
            guard let previous = lastDay else {
                lastDay = day
                streak = 1
                longestStreak = 1
                return
            }
            // Author dates can run backwards after a rebase or across time zones; such a commit
            // neither breaks nor extends the streak.
            if day == previous + 1 {
                streak += 1
                lastDay = day
            } else if day > previous + 1 {
                streak = 1
                lastDay = day
            }
            longestStreak = max(longestStreak, streak)
        }

        mutating func neighborhoodIndex(_ name: String, time: Int64) -> Int {
            if let existing = neighborhoodByName[name] {
                neighborhoods[existing].lastActiveAt = max(neighborhoods[existing].lastActiveAt, time)
                return existing
            }
            let index = neighborhoods.count
            neighborhoods.append(Neighborhood(id: index, name: name, lastActiveAt: time))
            neighborhoodByName[name] = index
            neighborhoodNameHash.append(StableHasher.hash(name))
            blockSums.append((0, 0, 0))
            openBlock.append(nil)
            latestBuilding.append(nil)
            latestBuildingByLanguage.append([:])
            latestPark.append(nil)
            return index
        }

        func repairTarget(_ neighborhood: Int, _ language: Language) -> Int? {
            latestBuildingByLanguage[neighborhood][language] ?? latestBuilding[neighborhood]
        }

        // MARK: Blocks

        /// Roads grow outward: a new block must touch the existing city (or be the origin), and
        /// among those the one closest to the neighborhood's centroid wins, so folders cluster.
        mutating func claimBlock(for neighborhood: Int, time: Int64, isPlaza: Bool) -> Int {
            let candidates: [GridPoint] = claimed.isEmpty ? [GridPoint(0, 0)] : Array(frontier)
            let sums = blockSums[neighborhood]
            var best: (score: Int, tie: UInt64, point: GridPoint)?
            for point in candidates {
                let score: Int
                if sums.count == 0 {
                    score = point.x * point.x + point.y * point.y
                } else {
                    let dx = point.x * sums.count - sums.x
                    let dy = point.y * sums.count - sums.y
                    score = dx * dx + dy * dy
                }
                var hasher = StableHasher(seed: seed)
                hasher.combine(neighborhoodNameHash[neighborhood])
                hasher.combine(point.x)
                hasher.combine(point.y)
                let tie = hasher.finalize()
                if let current = best {
                    if (score, tie, point) < (current.score, current.tie, current.point) {
                        best = (score, tie, point)
                    }
                } else {
                    best = (score, tie, point)
                }
            }
            let point = best!.point
            claimed.insert(point)
            frontier.remove(point)
            for neighbor in [
                GridPoint(point.x + 1, point.y), GridPoint(point.x - 1, point.y),
                GridPoint(point.x, point.y + 1), GridPoint(point.x, point.y - 1),
            ] where !claimed.contains(neighbor) {
                frontier.insert(neighbor)
            }
            blockSums[neighborhood] = (sums.x + point.x, sums.y + point.y, sums.count + 1)
            blocks.append(Block(at: point, neighborhood: neighborhood, claimedAt: time, isPlaza: isPlaza))
            lotsUsed.append(isPlaza ? District.blockSize * District.blockSize : 0)
            return blocks.count - 1
        }

        mutating func nextLot(for neighborhood: Int, time: Int64) -> GridPoint {
            let blockIndex: Int
            if let open = openBlock[neighborhood] {
                blockIndex = open
            } else {
                blockIndex = claimBlock(for: neighborhood, time: time, isPlaza: false)
            }
            let local = State.lotOrder[lotsUsed[blockIndex]]
            lotsUsed[blockIndex] += 1
            openBlock[neighborhood] = lotsUsed[blockIndex] < State.lotOrder.count ? blockIndex : nil
            let origin = blocks[blockIndex].at
            return GridPoint(
                origin.x * District.blockPitch + local.x, origin.y * District.blockPitch + local.y)
        }

        // MARK: Buildings

        func litFraction() -> Double {
            let progress = Double(max(0, streak - 1)) / Double(CityGenerator.fullStreakDays - 1)
            return quantize(min(1, 0.15 + 0.85 * progress))
        }

        mutating func addBuilding(
            _ neighborhood: Int, info: CommitInfo, seed detailSeed: UInt32, language: Language, isLandmark: Bool
        ) {
            let style = Classifier.style(for: language) == .park ? .slab : Classifier.style(for: language)
            let lot: GridPoint
            var width: Double
            var depth: Double
            let aspect = 0.85 + 0.30 * detailUnit(detailSeed, 0, 0)
            if isLandmark {
                let block = claimBlock(for: neighborhood, time: info.time, isPlaza: true)
                let origin = blocks[block].at
                lot = GridPoint(
                    origin.x * District.blockPitch + District.blockSize / 2,
                    origin.y * District.blockPitch + District.blockSize / 2)
                width = min(2.4, 2.2 * aspect)
                depth = min(2.4, 2.2 / aspect)
            } else {
                lot = nextLot(for: neighborhood, time: info.time)
                var side = CityGenerator.footprintSide(filesTouched: info.filesTouched)
                switch style {
                case .lowBlock: side *= 1.15
                case .glassTower: side *= 0.85
                case .gabled: side *= 0.9
                default: break
                }
                width = min(0.86, side * aspect)
                depth = min(0.86, side / aspect)
            }
            width = quantize(width)
            depth = quantize(depth)
            let floors = CityGenerator.floors(
                for: style, base: CityGenerator.baseFloors(linesChanged: info.linesChanged), isLandmark: isLandmark)
            let id = buildings.count
            buildings.append(
                Building(
                    id: id, style: style, language: language, lot: lot, width: width, depth: depth,
                    floors: floors, isLandmark: isLandmark, litWindows: litFraction(),
                    neighborhood: neighborhood, bornAt: info.time, seed: detailSeed, repairs: [], trees: [],
                    commit: info))
            latestBuilding[neighborhood] = id
            latestBuildingByLanguage[neighborhood][language] = id
        }

        mutating func plantTree(_ neighborhood: Int, info: CommitInfo, seed detailSeed: UInt32, language: Language) {
            if let park = latestPark[neighborhood], buildings[park].trees.count < CityGenerator.treesPerPark {
                buildings[park].trees.append(info.time)
                return
            }
            let lot = nextLot(for: neighborhood, time: info.time)
            let id = buildings.count
            buildings.append(
                Building(
                    id: id, style: .park, language: language, lot: lot, width: 0.84, depth: 0.84, floors: 0,
                    isLandmark: false, litWindows: litFraction(), neighborhood: neighborhood, bornAt: info.time,
                    seed: detailSeed, repairs: [], trees: [info.time], commit: info))
            latestPark[neighborhood] = id
        }
    }
}

extension District {
    /// Shape-only copy for private repos: geometry and timing survive, words do not.
    public func redactedToShape() -> District {
        var copy = self
        copy.visibility = .shape
        copy.neighborhoods = neighborhoods.map {
            Neighborhood(id: $0.id, name: nil, lastActiveAt: $0.lastActiveAt)
        }
        copy.buildings = buildings.map { building in
            var redacted = building
            redacted.commit.sha = nil
            redacted.commit.subject = nil
            redacted.commit.author = nil
            return redacted
        }
        return copy
    }
}
