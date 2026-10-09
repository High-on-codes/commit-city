/// A hard-coded fake history for tuning the look without a real repository, and for tests.
/// Fully deterministic: same seed, same commits, same city.
public enum DemoCity {
    struct Area {
        let folder: String
        let ext: String
        let weight: Int
    }

    static let areas: [Area] = [
        Area(folder: "Sources/CityKit", ext: "swift", weight: 9),
        Area(folder: "Sources/App", ext: "swift", weight: 6),
        Area(folder: "engine", ext: "rs", weight: 5),
        Area(folder: "web", ext: "ts", weight: 5),
        Area(folder: "scripts", ext: "py", weight: 3),
        Area(folder: "docs", ext: "md", weight: 2),
        Area(folder: "Sources/Server", ext: "java", weight: 2),
        Area(folder: "ops", ext: "sh", weight: 2),
    ]

    static let verbs = ["feat", "feat", "feat", "fix", "fix", "refactor", "perf", "chore", "test", "docs"]
    static let nouns = [
        "parser", "layout pass", "render loop", "cache", "district merge", "decay curve", "window lighting",
        "road growth", "replay scrubber", "badge", "widget timeline", "streak counter", "json schema",
    ]

    public static func commits(count: Int = 240, seed: UInt64 = 0xC0FF_EE00_C17E, start: Int64 = 1_704_067_200) -> [Commit] {
        var random = SplitMix64(seed: seed)
        func below(_ bound: Int) -> Int { Int(random.next() % UInt64(bound)) }

        var commits = [Commit]()
        var time = start
        let totalWeight = areas.reduce(0) { $0 + $1.weight }

        // The initial import: a landmark at the origin.
        commits.append(Commit(
            sha: "0000000000000000000000000000000000000000", authorName: "Demo", authorEmail: "demo@example.com",
            authorTime: time, utcOffsetMinutes: 60, subject: "feat: initial import",
            files: (0..<40).map { FileChange(path: "Sources/CityKit/File\($0).swift", linesAdded: 120, linesDeleted: 0) }))

        for index in 1..<count {
            // Bursts of daily streaks separated by quiet gaps.
            let gapDays = below(10) < 7 ? 1 : 2 + below(9)
            time += Int64(gapDays) * 86_400 + Int64(below(20_000))
            var ticket = below(totalWeight)
            var area = areas[0]
            for candidate in areas {
                if ticket < candidate.weight {
                    area = candidate
                    break
                }
                ticket -= candidate.weight
            }
            let verb = area.ext == "md" ? "docs" : verbs[below(verbs.count)]
            let fileCount = 1 + below(below(4) == 0 ? 24 : 5)
            let size = below(8) == 0 ? 400 + below(1600) : 2 + below(140)
            let files = (0..<fileCount).map { file in
                FileChange(
                    path: "\(area.folder)/\(nouns[(index + file) % nouns.count].replacingSpaces)\(file).\(area.ext)",
                    linesAdded: max(1, size / fileCount), linesDeleted: below(size / fileCount + 1))
            }
            commits.append(Commit(
                sha: String(repeating: "\(index % 10)", count: 40), authorName: "Demo", authorEmail: "demo@example.com",
                authorTime: time, utcOffsetMinutes: 60, subject: "\(verb): \(nouns[below(nouns.count)]) pass \(index)",
                files: files))
        }
        return commits
    }

    public static func city(generatedAt: Int64? = nil) -> City {
        let commits = commits()
        let now = generatedAt ?? (commits.last!.authorTime + 3 * 86_400)
        return CityGenerator.city(from: commits, name: "commit-city", generatedAt: now)
    }
}

private extension String {
    var replacingSpaces: String {
        String(map { $0 == " " ? "_" : $0 })
    }
}
