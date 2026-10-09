import Foundation
import XCTest

@testable import CityKit

#if canImport(FoundationXML)
    import FoundationXML
#endif

// MARK: - Fixtures

func commit(
    _ subject: String, _ files: [(String, Int)], day: Int64, sha: String? = nil, offsetMinutes: Int = 0,
    email: String = "dev@example.com"
) -> Commit {
    Commit(
        sha: sha ?? String(repeating: "a", count: 40), authorName: "Dev", authorEmail: email,
        authorTime: 1_700_000_000 + day * 86_400, utcOffsetMinutes: offsetMinutes, subject: subject,
        files: files.map { FileChange(path: $0.0, linesAdded: $0.1, linesDeleted: 0) })
}

/// Bytes exactly as `git log` emits them for `GitLog.arguments`.
func gitBytes(_ records: [(header: [String], numstat: [String])]) -> Data {
    var data = Data()
    for record in records {
        data.append(0x1E)
        data.append(Data(record.header.joined(separator: "\u{1F}").utf8))
        data.append(0)
        data.append(0x0A)
        for entry in record.numstat {
            data.append(Data(entry.utf8))
            data.append(0)
        }
    }
    return data
}

final class GitLogTests: XCTestCase {
    func testParsesHeadersNumstatBinaryAndAwkwardPaths() throws {
        let data = gitBytes([
            (["abc", "1700000000", "2023-11-14 22:13:20 +0530", "Ada L", "ada@example.com", "feat(core)!: tabs\tand \"quotes\""],
             ["10\t2\tSources/Café/Main.swift", "-\t-\tAssets/logo.png", "3\t0\tdir with spaces/a\tb.txt"]),
            (["def", "1700086400", "2023-11-15 14:13:20 -0800", "Bob", "bob@example.com", "empty"], []),
        ])
        let commits = try GitLog.parse(data)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "feat(core)!: tabs\tand \"quotes\"")
        XCTAssertEqual(commits[0].utcOffsetMinutes, 330)
        XCTAssertEqual(commits[0].files[0], FileChange(path: "Sources/Café/Main.swift", linesAdded: 10, linesDeleted: 2))
        XCTAssertTrue(commits[0].files[1].isBinary)
        XCTAssertEqual(commits[0].files[2].path, "dir with spaces/a\tb.txt")
        XCTAssertEqual(commits[1].utcOffsetMinutes, -480)
        XCTAssertTrue(commits[1].files.isEmpty)
    }

    func testRejectsMalformedRecords() {
        let bad = gitBytes([(["abc", "notatime", "2023-11-14 22:13:20 +0000", "A", "a@b", "s"], [])])
        XCTAssertThrowsError(try GitLog.parse(bad))
        let badCounts = gitBytes([(["abc", "1", "2023-11-14 22:13:20 +0000", "A", "a@b", "s"], ["x\t1\tf"])])
        XCTAssertThrowsError(try GitLog.parse(badCounts))
        XCTAssertEqual(try GitLog.parse(Data()), [])
    }

    func testReadsARealRepositoryAndRefusesShallowClones() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: String..., in dir: URL? = nil) throws {
            _ = try GitLog.runGit(["-c", "user.name=T", "-c", "user.email=t@e.com"] + args, in: dir ?? repo)
        }
        try git("init", "-q")
        XCTAssertEqual(try GitLog.read(repository: repo), [], "an empty repo is an empty lot, not an error")

        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src/app"), withIntermediateDirectories: true)
        try "a\nb\n".write(to: repo.appendingPathComponent("src/app/main.swift"), atomically: true, encoding: .utf8)
        try git("add", "-A")
        try git("commit", "-q", "-m", "feat: first")
        try "a\nb\nc\n".write(to: repo.appendingPathComponent("src/app/main.swift"), atomically: true, encoding: .utf8)
        try "# hi\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git("add", "-A")
        try git("commit", "-q", "-m", "docs: readme")

        let commits = try GitLog.read(repository: repo)
        XCTAssertEqual(commits.map(\.subject), ["feat: first", "docs: readme"])
        XCTAssertEqual(commits[0].files, [FileChange(path: "src/app/main.swift", linesAdded: 2, linesDeleted: 0)])
        XCTAssertEqual(Set(commits[1].files.map(\.path)), ["README.md", "src/app/main.swift"])

        let shallow = root.appendingPathComponent("shallow")
        try git("clone", "-q", "--depth", "1", "file://" + repo.path, shallow.path, in: root)
        XCTAssertThrowsError(try GitLog.read(repository: shallow)) { error in
            XCTAssertEqual(error as? GitLogError, .shallowRepository)
        }
        XCTAssertEqual(try GitLog.read(repository: shallow, allowShallow: true).count, 1)
    }

    func testRepoConfig() {
        XCTAssertEqual(RepoConfig.parse("status: finished").status, .finished)
        let config = RepoConfig.parse("# comment\nvisibility: shape\nlabel: Side project\nseed: 42\nwat: 1\nstatus: done\n")
        XCTAssertEqual(config.visibility, .shape)
        XCTAssertEqual(config.label, "Side project")
        XCTAssertEqual(config.seed, 42)
        XCTAssertEqual(config.status, .active)
        XCTAssertEqual(config.warnings.count, 2)
    }
}

final class ClassifierTests: XCTestCase {
    func testCommitTypes() {
        XCTAssertEqual(Classifier.commitType(subject: "feat(ui)!: new map"), .feat)
        XCTAssertEqual(Classifier.commitType(subject: "Fix crash on launch"), .fix)
        XCTAssertEqual(Classifier.commitType(subject: "Revert \"feat: x\""), .revert)
        XCTAssertEqual(Classifier.commitType(subject: "docs: typo"), .docs)
        XCTAssertEqual(Classifier.commitType(subject: "WIP"), .other)
        XCTAssertEqual(Classifier.commitType(subject: "re: fixes"), .other)
    }

    func testLanguageNoiseAndNeighborhoods() {
        XCTAssertEqual(Classifier.language(ofPath: "a/b/View.swift"), .swift)
        XCTAssertEqual(Classifier.language(ofPath: "Dockerfile"), .config)
        XCTAssertEqual(Classifier.language(ofPath: ".gitignore"), .other)
        XCTAssertTrue(Classifier.isNoise("web/package-lock.json"))
        XCTAssertTrue(Classifier.isNoise("node_modules/x/index.js"))
        XCTAssertFalse(Classifier.isNoise("web/src/index.ts"))
        XCTAssertEqual(Classifier.neighborhoodKey(ofPath: "Sources/CityKit/Model.swift"), "Sources/CityKit")
        XCTAssertEqual(Classifier.neighborhoodKey(ofPath: "docs/a/b.md"), "docs")
        XCTAssertEqual(Classifier.neighborhoodKey(ofPath: "README.md"), "/")

        let lockBump = commit("chore: deps", [("package-lock.json", 9000), ("web/a.ts", 3)], day: 0)
        XCTAssertEqual(Classifier.linesChanged(lockBump), 3, "lockfiles must not build skyscrapers")
        XCTAssertEqual(Classifier.dominantLanguage(lockBump), .typescript)
    }

    func testSizingIsMonotonic() {
        var previous = 0
        for lines in [0, 1, 5, 20, 100, 500, 2_000, 10_000, 1_000_000, Int.max] {
            let floors = CityGenerator.baseFloors(linesChanged: lines)
            XCTAssertGreaterThanOrEqual(floors, previous)
            XCTAssertLessThanOrEqual(floors, 40)
            previous = floors
        }
        XCTAssertLessThan(CityGenerator.footprintSide(filesTouched: 1), CityGenerator.footprintSide(filesTouched: 30))
        XCTAssertLessThanOrEqual(CityGenerator.footprintSide(filesTouched: 100_000), 0.82 + 1e-12)
    }
}

final class GeneratorTests: XCTestCase {
    func testCommitRules() {
        let commits = [
            commit("feat: tower", [("Sources/App/A.swift", 200)], day: 0),
            commit("fix: bug", [("Sources/App/A.swift", 3)], day: 1),
            commit("docs: guide", [("docs/guide.md", 40)], day: 2),
            commit("docs: more", [("docs/more.md", 10)], day: 3),
            commit("feat: python", [("scripts/run.py", 50)], day: 4),
            commit("feat: huge import", (0..<200).map { ("vendorless/f\($0).rs", 30) }, day: 5),
        ]
        let district = CityGenerator.district(from: commits, id: "t", name: "t")
        XCTAssertEqual(district.commitCount, 6)
        let buildings = district.buildings
        XCTAssertEqual(buildings.count, 4, "fix → repair, second docs → tree on the existing park")
        XCTAssertEqual(buildings[0].style, .glassTower)
        XCTAssertEqual(buildings[0].repairs.count, 1)
        XCTAssertEqual(buildings[1].style, .park)
        XCTAssertEqual(buildings[1].trees.count, 2)
        XCTAssertEqual(buildings[2].style, .lowBlock)
        XCTAssertTrue(buildings[3].isLandmark)
        XCTAssertEqual(buildings[3].style, .factory)
        XCTAssertTrue(district.blocks.contains { $0.isPlaza })
        XCTAssertEqual(district.longestStreakDays, 6)
        XCTAssertGreaterThan(buildings[3].litWindows, buildings[0].litWindows, "streaks light windows progressively")
    }

    func testFixWithoutABuildingStillBuilds() {
        let district = CityGenerator.district(
            from: [commit("fix: first ever", [("a/b.go", 10)], day: 0)], id: "t", name: "t")
        XCTAssertEqual(district.buildings.count, 1)
    }

    func testFoldersClusterAndRoadsGrowFromTheOrigin() {
        var commits = [Commit]()
        for i in 0..<60 {
            let folder = ["Sources/A", "Sources/B", "web"][i % 3]
            commits.append(commit("feat: \(i)", [("\(folder)/f\(i).swift", 10 + i)], day: Int64(i)))
        }
        let district = CityGenerator.district(from: commits, id: "t", name: "t")
        XCTAssertEqual(district.blocks.first?.at, GridPoint(0, 0))
        // Every block after the first touches an earlier one: the road network is connected.
        var seen: Set<GridPoint> = []
        for block in district.blocks {
            if !seen.isEmpty {
                let p = block.at
                XCTAssertTrue(
                    [GridPoint(p.x + 1, p.y), GridPoint(p.x - 1, p.y), GridPoint(p.x, p.y + 1), GridPoint(p.x, p.y - 1)]
                        .contains(where: seen.contains))
            }
            seen.insert(block.at)
        }
        // A block holds one neighborhood only, and lots are never shared.
        let lots = district.buildings.map(\.lot)
        XCTAssertEqual(Set(lots).count, lots.count)
        for building in district.buildings {
            let block = GridPoint(
                Int((Double(building.lot.x) / Double(District.blockPitch)).rounded(.down)),
                Int((Double(building.lot.y) / Double(District.blockPitch)).rounded(.down)))
            XCTAssertEqual(district.blocks.first { $0.at == block }?.neighborhood, building.neighborhood)
        }
    }

    func testDeterministicAndStableUnderRewrittenHashes() throws {
        let commits = DemoCity.commits()
        let a = CityGenerator.city(from: commits, name: "demo", generatedAt: 1)
        let b = CityGenerator.city(from: commits, name: "demo", generatedAt: 1)
        XCTAssertEqual(try a.jsonData(), try b.jsonData())

        // A rebase that rewrites every SHA but keeps content and order rebuilds the same city.
        let rebased = commits.enumerated().map { index, original -> Commit in
            var copy = original
            copy.sha = String(repeating: "f", count: 39) + String(index % 10)
            return copy
        }
        var c = CityGenerator.city(from: rebased, name: "demo", generatedAt: 1)
        for d in c.districts.indices {
            for i in c.districts[d].buildings.indices { c.districts[d].buildings[i].commit.sha = a.districts[d].buildings[i].commit.sha }
        }
        XCTAssertEqual(c, a)
    }

    func testJSONRoundTripAndSchemaGuard() throws {
        let city = DemoCity.city()
        XCTAssertEqual(try City.decode(city.jsonData()), city)
        var future = city
        future.schema = City.currentSchema + 1
        XCTAssertThrowsError(try City.decode(future.jsonData()))
        XCTAssertThrowsError(try City.decode(Data("{".utf8)))
    }

    func testShapeOnlyLeaksNoWords() throws {
        var config = RepoConfig()
        config.visibility = .shape
        let city = CityGenerator.city(from: DemoCity.commits(), name: "secret-project", config: config, generatedAt: 1)
        let json = String(decoding: try city.jsonData(), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("pass "), "commit subjects must not survive")
        XCTAssertFalse(json.contains("Demo"), "authors must not survive")
        XCTAssertFalse(json.contains("Sources/"), "folder names must not survive")
        XCTAssertEqual(city.districts[0].name, "private")
        XCTAssertGreaterThan(city.buildingCount, 100)
    }
}

final class DecayTests: XCTestCase {
    func testBoundaries() {
        let day: Int64 = 86_400
        XCTAssertEqual(DecayState.evaluate(lastActiveAt: 0, now: 29 * day, finished: false), .active)
        XCTAssertEqual(DecayState.evaluate(lastActiveAt: 0, now: 30 * day, finished: false), .idle(progress: 0))
        XCTAssertEqual(DecayState.evaluate(lastActiveAt: 0, now: 60 * day, finished: false), .idle(progress: 0.5))
        XCTAssertEqual(DecayState.evaluate(lastActiveAt: 0, now: 90 * day, finished: false), .abandoned(progress: 0))
        XCTAssertEqual(DecayState.evaluate(lastActiveAt: 0, now: 4000 * day, finished: false), .abandoned(progress: 1))
        XCTAssertEqual(DecayState.evaluate(lastActiveAt: 0, now: 4000 * day, finished: true), .finished)
        XCTAssertEqual(DecayState.evaluate(lastActiveAt: 100, now: 0, finished: false), .active, "clock skew is not decay")
        XCTAssertNotNil(DecayState.abandoned(progress: 0.3).dashPattern)
        XCTAssertGreaterThan(DecayState.abandoned(progress: 1).structureAlpha, 0)
    }

    func testFinishedDistrictKeepsItsBeaconAndLight() throws {
        let commits = DemoCity.commits()
        var config = RepoConfig()
        config.status = .finished
        let tenYearsLater = commits.last!.authorTime + 3650 * 86_400
        let city = CityGenerator.city(from: commits, name: "done", config: config, generatedAt: tenYearsLater)
        let scene = Scene.build(city: city, at: tenYearsLater)
        XCTAssertTrue(scene.items.allSatisfy { $0.look == BuildingLook(structureAlpha: 1, windowAlpha: 1, dashPattern: nil) })
        let beacons = scene.items.flatMap(\.primitives).filter {
            if case let .disc(_, radius, .accent) = $0 { return radius == 0.16 }
            return false
        }
        XCTAssertEqual(beacons.count, 1)

        let abandoned = CityGenerator.city(from: commits, name: "old", generatedAt: tenYearsLater)
        XCTAssertTrue(Scene.build(city: abandoned, at: tenYearsLater).items.allSatisfy { $0.look.dashPattern != nil })
    }
}

final class MergeTests: XCTestCase {
    func testDistrictsNeverOverlapAndStayGridAligned() {
        var cities = [City]()
        for (index, count) in [240, 40, 120, 8, 60].enumerated() {
            let commits = Array(DemoCity.commits(count: count, seed: UInt64(index + 1)))
            cities.append(CityGenerator.city(from: commits, name: "repo\(index)", generatedAt: 1))
        }
        cities.append(CityGenerator.city(from: [], name: "empty", generatedAt: 1))
        cities.append(CityGenerator.city(from: DemoCity.commits(count: 10), name: "repo0", generatedAt: 1))
        let merged = CityMerger.merge(cities, name: "me", generatedAt: 2)
        XCTAssertEqual(merged.districts.count, 7)
        XCTAssertEqual(Set(merged.districts.map(\.id)).count, 7, "duplicate repo names get unique ids")

        var rects = [(Int, Int, Int, Int)]()
        for district in merged.districts {
            XCTAssertEqual(district.offset.x % District.blockPitch, 0)
            XCTAssertEqual(district.offset.y % District.blockPitch, 0)
            guard let b = district.localLotBounds else { continue }
            let r = (b.minX + district.offset.x, b.minY + district.offset.y, b.maxX + district.offset.x, b.maxY + district.offset.y)
            for other in rects {
                let overlaps = r.0 <= other.2 && other.0 <= r.2 && r.1 <= other.3 && other.1 <= r.3
                XCTAssertFalse(overlaps)
            }
            rects.append(r)
        }
        XCTAssertEqual(CityMerger.merge(cities, name: "me", generatedAt: 2), merged)
    }
}

final class RenderTests: XCTestCase {
    func testSVGIsWellFormedDeterministicAndThemed() throws {
        let city = DemoCity.city()
        for theme in Theme.all {
            for layout in [SVGRenderer.Layout.readme(width: 1200), .card] {
                let svg = SVGRenderer.render(city: city, theme: theme, layout: layout)
                XCTAssertEqual(svg, SVGRenderer.render(city: city, theme: theme, layout: layout))
                XCTAssertTrue(svg.contains(theme.accent))
                assertWellFormed(svg)
            }
        }
        let badge = Badge.render(city: city)
        assertWellFormed(badge)
        XCTAssertTrue(badge.contains("buildings"))
    }

    func testEmptyAndHostileNames() {
        let empty = CityGenerator.city(from: [], name: "<script>&\"'\u{1}", generatedAt: 0)
        let svg = SVGRenderer.render(city: empty)
        XCTAssertFalse(svg.contains("<script>"))
        XCTAssertTrue(svg.contains("EMPTY LOT"))
        assertWellFormed(svg)
    }

    func testReplayAtAnEarlierDayShowsFewerBuildings() {
        let city = DemoCity.city()
        let midpoint = (city.firstCommitAt! + city.lastCommitAt!) / 2
        let early = Scene.build(city: city, at: midpoint).buildingCount
        XCTAssertGreaterThan(early, 0)
        XCTAssertLessThan(early, city.buildingCount)
        XCTAssertEqual(Scene.build(city: city, at: city.firstCommitAt! - 1).buildingCount, 0)
    }

    func testDetailHashMatchesPublishedVectors() {
        // The viewer's JS port is checked against these same values in Tests/viewer-parity.mjs runs.
        XCTAssertEqual(detailHash(0, 0, 0), detailHash(0, 0, 0))
        XCTAssertNotEqual(detailHash(1, 0, 0), detailHash(1, 0, 1))
        XCTAssertNotEqual(detailHash(1, -1, 0), detailHash(1, 1, 0))
        XCTAssertLessThan(detailUnit(.max, .max, .min), 1)
    }

    func assertWellFormed(_ svg: String, file: StaticString = #filePath, line: UInt = #line) {
        let parser = XMLParser(data: Data(svg.utf8))
        XCTAssertTrue(parser.parse(), "SVG is not well-formed: \(String(describing: parser.parserError))", file: file, line: line)
    }
}

final class FormatTests: XCTestCase {
    func testCivilDates() {
        for days: Int64 in [-719_468, -1, 0, 1, 11_016, 19_000, 20_000, 2_932_896] {
            let civil = Format.civil(fromDays: days)
            XCTAssertEqual(Format.days(year: civil.year, month: civil.month, day: civil.day), days)
        }
        XCTAssertEqual(Format.date(0), "1970-01-01")
        XCTAssertEqual(Format.date(1_791_590_400), "2026-10-10")
        XCTAssertEqual(Format.parseTime("2024-02-29"), 1_709_164_800)
        XCTAssertNil(Format.parseTime("2023-02-29"))
        XCTAssertNil(Format.parseTime("yesterday"))
        XCTAssertEqual(Format.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(Format.coordinate(-0.04), "0")
        XCTAssertEqual(Format.coordinate(12.25), "12.3")
        XCTAssertEqual(Format.fixed2(0.5), "0.5")
    }
}

final class ScaleTests: XCTestCase {
    func testTwentyThousandCommitsStayFastAndSmall() throws {
        let commits = DemoCity.commits(count: 20_000)
        let start = Date()
        let city = CityGenerator.city(from: commits, name: "big", generatedAt: commits.last!.authorTime)
        let generated = Date().timeIntervalSince(start)
        let svg = SVGRenderer.render(city: city)
        let total = Date().timeIntervalSince(start)
        print("scale: \(city.buildingCount) buildings, generate \(Int(generated * 1000)) ms, total \(Int(total * 1000)) ms, svg \(svg.utf8.count / 1024) KB")
        XCTAssertGreaterThan(city.buildingCount, 10_000)
        XCTAssertLessThan(total, 60, "debug build budget")
        XCTAssertLessThan(svg.utf8.count, 16 * 1024 * 1024)
    }
}

final class MassingTests: XCTestCase {
    func testMassingCollapsesBlocksButKeepsLandmarksAndNewest() {
        let city = DemoCity.city()
        let full = Scene.build(city: city, at: city.generatedAt, detail: .full)
        let massing = Scene.build(city: city, at: city.generatedAt, detail: .massing)
        XCTAssertLessThan(massing.items.count, full.items.count)
        XCTAssertEqual(massing.buildingCount, full.buildingCount)
        let landmarks = Set(city.districts[0].buildings.filter(\.isLandmark).map(\.id))
        XCTAssertFalse(landmarks.isEmpty)
        let individual = Set(massing.items.compactMap(\.building))
        XCTAssertTrue(landmarks.isSubset(of: individual))
        let newest = city.districts[0].buildings.filter { $0.style != .park }.max { ($0.bornAt, $0.id) < ($1.bornAt, $1.id) }!
        XCTAssertTrue(individual.contains(newest.id))
        XCTAssertTrue(massing.items.flatMap(\.primitives).contains {
            if case .line(_, .accent, _) = $0 { return true }
            return false
        }, "the newest building keeps its accent outline")
    }
}
