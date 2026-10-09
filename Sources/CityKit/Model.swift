// The four structs everything depends on: Commit (input), Building, District, City (output).
// The output side is the city.json schema shared by the CLI, the web viewer and the widget, so
// every field is plain JSON: integers that fit in a JS double, hex strings for 64-bit keys.

// MARK: - Input

public struct FileChange: Sendable, Equatable {
    public var path: String
    public var linesAdded: Int
    public var linesDeleted: Int
    /// Binary files report `-` in numstat; they count as touched but contribute no lines.
    public var isBinary: Bool

    public init(path: String, linesAdded: Int, linesDeleted: Int, isBinary: Bool = false) {
        self.path = path
        self.linesAdded = linesAdded
        self.linesDeleted = linesDeleted
        self.isBinary = isBinary
    }

    public var linesChanged: Int { linesAdded + linesDeleted }
}

public struct Commit: Sendable, Equatable {
    public var sha: String
    public var authorName: String
    public var authorEmail: String
    /// Author time, Unix seconds.
    public var authorTime: Int64
    /// The author's UTC offset at commit time. Streak days are counted in the author's local calendar.
    public var utcOffsetMinutes: Int
    public var subject: String
    public var files: [FileChange]

    public init(
        sha: String, authorName: String, authorEmail: String, authorTime: Int64,
        utcOffsetMinutes: Int, subject: String, files: [FileChange]
    ) {
        self.sha = sha
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorTime = authorTime
        self.utcOffsetMinutes = utcOffsetMinutes
        self.subject = subject
        self.files = files
    }

    /// Identity that survives rebases, amended SHAs and re-clones: everything a human would call
    /// "the same commit" except the hash. Layout never reads this; per-building detail does.
    public var contentKey: UInt64 {
        var hasher = StableHasher()
        hasher.combine(authorTime)
        hasher.combine(authorEmail)
        hasher.combine(subject)
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.combine(file.path)
            hasher.combine(file.linesAdded)
            hasher.combine(file.linesDeleted)
        }
        return hasher.finalize()
    }

    /// Day number (days since 1970-01-01) in the author's own time zone.
    public var localDay: Int64 {
        let local = authorTime + Int64(utcOffsetMinutes) * 60
        return local >= 0 ? local / 86_400 : (local - 86_399) / 86_400
    }
}

public enum Language: String, Codable, Sendable, CaseIterable {
    case swift, python, rust, javascript, typescript, go, c, cpp, java, kotlin, csharp, ruby, php
    case shell, web, markdown, config, other
}

public enum CommitType: String, Codable, Sendable, CaseIterable {
    case feat, fix, docs, refactor, perf, test, chore, style, build, ci, revert, other
}

public enum BuildingStyle: String, Codable, Sendable, CaseIterable {
    /// Swift, Kotlin: slender glass tower with mullions.
    case glassTower
    /// Python: low, wide block with floor bands.
    case lowBlock
    /// Rust, C, C++: sawtooth-roof factory with a chimney.
    case factory
    /// JavaScript, TypeScript, Go: setback tower.
    case steppedTower
    /// Java, C#, everything unclassified: plain slab with a window grid.
    case slab
    /// Ruby, PHP, shell, config, web: small gabled house.
    case gabled
    /// Markdown and docs commits: open lot with trees.
    case park
}

// MARK: - Output (city.json)

/// Integer coordinates: lot space for buildings, block space for blocks.
public struct GridPoint: Codable, Hashable, Sendable, Comparable {
    public var x: Int
    public var y: Int

    public init(_ x: Int, _ y: Int) {
        self.x = x
        self.y = y
    }

    public static func < (lhs: GridPoint, rhs: GridPoint) -> Bool {
        (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}

public struct CommitInfo: Codable, Sendable, Equatable {
    /// Position in the replayed history (0 = first commit of the district).
    public var index: Int
    /// `nil` in shape-only (private) districts.
    public var sha: String?
    public var subject: String?
    public var author: String?
    public var time: Int64
    public var type: CommitType
    public var linesChanged: Int
    public var filesTouched: Int
}

public struct Building: Codable, Sendable, Equatable {
    public var id: Int
    public var style: BuildingStyle
    public var language: Language
    /// Lot the footprint is centred on, in the district's local lot space.
    public var lot: GridPoint
    /// Footprint in lot units (a lot is 1×1; landmarks span most of a block).
    public var width: Double
    public var depth: Double
    public var floors: Int
    public var isLandmark: Bool
    /// Fraction of windows lit, from the author's daily streak when the building was founded.
    public var litWindows: Double
    public var neighborhood: Int
    public var bornAt: Int64
    /// 32-bit detail seed derived from the commit's content key.
    public var seed: UInt32
    /// Times of fix/revert commits that added a repair detail to this building.
    public var repairs: [Int64]
    /// Parks only: times trees were planted (the first is the park's founding).
    public var trees: [Int64]
    public var commit: CommitInfo
}

public struct Block: Codable, Sendable, Equatable {
    /// Block coordinates; the block's lots start at `at * District.blockPitch`.
    public var at: GridPoint
    public var neighborhood: Int
    public var claimedAt: Int64
    /// A block reserved for a single landmark.
    public var isPlaza: Bool
}

public struct Neighborhood: Codable, Sendable, Equatable {
    public var id: Int
    /// Folder the neighborhood grew from; `nil` in shape-only districts.
    public var name: String?
    public var lastActiveAt: Int64
}

public enum DistrictStatus: String, Codable, Sendable {
    case active
    case finished
}

public enum Visibility: String, Codable, Sendable {
    case full
    /// Private repos: geometry and timing only. No messages, authors, SHAs or folder names.
    case shape
}

public struct District: Codable, Sendable, Equatable {
    /// Lots per block side, and the lot pitch between block origins (block + one-lot road).
    public static let blockSize = 3
    public static let blockPitch = 4

    public var id: String
    public var name: String
    public var status: DistrictStatus
    public var visibility: Visibility
    /// Placement inside a merged personal city, in lots. Zero for a single-repo city.
    public var offset: GridPoint
    public var firstCommitAt: Int64
    public var lastCommitAt: Int64
    public var commitCount: Int
    public var longestStreakDays: Int
    public var neighborhoods: [Neighborhood]
    public var blocks: [Block]
    public var buildings: [Building]

    public init(
        id: String, name: String, status: DistrictStatus, visibility: Visibility, offset: GridPoint,
        firstCommitAt: Int64, lastCommitAt: Int64, commitCount: Int, longestStreakDays: Int,
        neighborhoods: [Neighborhood], blocks: [Block], buildings: [Building]
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.visibility = visibility
        self.offset = offset
        self.firstCommitAt = firstCommitAt
        self.lastCommitAt = lastCommitAt
        self.commitCount = commitCount
        self.longestStreakDays = longestStreakDays
        self.neighborhoods = neighborhoods
        self.blocks = blocks
        self.buildings = buildings
    }

    /// Inclusive lot-space bounds of every claimed block (local coordinates), or `nil` if empty.
    public var localLotBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        guard let first = blocks.first else { return nil }
        var minX = first.at.x, maxX = first.at.x, minY = first.at.y, maxY = first.at.y
        for block in blocks.dropFirst() {
            minX = min(minX, block.at.x)
            maxX = max(maxX, block.at.x)
            minY = min(minY, block.at.y)
            maxY = max(maxY, block.at.y)
        }
        let pitch = District.blockPitch
        let size = District.blockSize
        return (minX * pitch, minY * pitch, maxX * pitch + size - 1, maxY * pitch + size - 1)
    }
}

public struct City: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var name: String
    /// Unix seconds. Decay in the SVG is evaluated at this instant; the viewer re-evaluates live.
    public var generatedAt: Int64
    public var districts: [District]

    public init(name: String, generatedAt: Int64, districts: [District]) {
        self.schema = City.currentSchema
        self.name = name
        self.generatedAt = generatedAt
        self.districts = districts
    }

    public var buildingCount: Int { districts.reduce(0) { $0 + $1.buildings.count } }
    public var commitCount: Int { districts.reduce(0) { $0 + $1.commitCount } }
    public var firstCommitAt: Int64? { districts.filter { $0.commitCount > 0 }.map(\.firstCommitAt).min() }
    public var lastCommitAt: Int64? { districts.filter { $0.commitCount > 0 }.map(\.lastCommitAt).max() }
}
