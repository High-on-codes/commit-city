import CityKit
import Foundation

// commitcity — writes city.json, city.svg, badges and share cards. No dependencies, so the
// argument parsing is hand-rolled and strict: unknown flags are errors, not silently ignored.

let usage = """
    commitcity — a city that grows every time you commit.

    USAGE
      commitcity generate [--repo PATH] [--out DIR] [--name NAME] [--theme NAME] [--now TIME]
                          [--shape-only] [--allow-shallow]
          Reads the repository's history and writes DIR/city.json, DIR/city.svg and DIR/badge.svg.

      commitcity merge --out DIR [--name NAME] [--theme NAME] [--now TIME] CITY.json...
          Merges per-repo cities (one district each) into one personal city.

      commitcity render CITY.json --out FILE.svg [--theme NAME] [--at TIME] [--card] [--reduced|--massing]
          Re-renders an existing city. --at shows the city as it stood on that day;
          --card draws a 1200×630 share card.

      commitcity badge CITY.json --out FILE.svg [--theme NAME] [--link URL]
          Writes a README badge and prints the Markdown to paste.

      commitcity demo --out DIR [--theme NAME]
          Renders the built-in fake city (no repository needed).

    TIME is YYYY-MM-DD or Unix seconds. Themes: carbon (default), cyanotype, vellum.
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Arguments {
    var positional = [String]()
    var options = [String: String]()
    var flags = Set<String>()

    init(_ raw: ArraySlice<String>, valued: Set<String>, flags allowedFlags: Set<String>) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if valued.contains(name) {
                    guard let value = iterator.next() else { throw CLIError("--\(name) needs a value") }
                    options[name] = value
                } else if allowedFlags.contains(name) {
                    flags.insert(name)
                } else {
                    throw CLIError("unknown option --\(name)")
                }
            } else {
                positional.append(argument)
            }
        }
    }

    func theme() throws -> Theme {
        guard let name = options["theme"] else { return .carbon }
        guard let theme = Theme.named(name) else {
            throw CLIError("unknown theme \(name) (available: \(Theme.all.map(\.name).joined(separator: ", ")))")
        }
        return theme
    }

    func time(_ key: String) throws -> Int64? {
        guard let text = options[key] else { return nil }
        guard let time = Format.parseTime(text) else { throw CLIError("--\(key) must be YYYY-MM-DD or Unix seconds") }
        return time
    }
}

func currentTime() -> Int64 {
    Int64(Date().timeIntervalSince1970)
}

func directory(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Atomic write so a viewer polling city.json never reads half a file.
func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
}

func write(_ text: String, to url: URL) throws {
    try write(Data(text.utf8), to: url)
}

func loadCity(_ path: String) throws -> City {
    let url = URL(fileURLWithPath: path)
    guard let data = FileManager.default.contents(atPath: url.path) else { throw CLIError("cannot read \(path)") }
    return try City.decode(data)
}

func writeOutputs(_ city: City, theme: Theme, to out: URL) throws {
    try write(try city.jsonData(), to: out.appendingPathComponent("city.json"))
    try write(SVGRenderer.render(city: city, theme: theme), to: out.appendingPathComponent("city.svg"))
    try write(Badge.render(city: city, theme: theme), to: out.appendingPathComponent("badge.svg"))
}

func standardError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func run(_ argv: [String]) throws {
    guard argv.count >= 2 else {
        print(usage)
        return
    }
    let rest = argv.dropFirst(2)
    switch argv[1] {
    case "generate":
        let args = try Arguments(
            rest, valued: ["repo", "out", "name", "theme", "now"], flags: ["shape-only", "allow-shallow"])
        let repo = URL(fileURLWithPath: args.options["repo"] ?? ".", isDirectory: true).standardizedFileURL
        let out = try directory(args.options["out"] ?? "commit-city")
        var config = RepoConfig.load(repository: repo)
        for warning in config.warnings { standardError("warning: .commitcity \(warning)") }
        if args.flags.contains("shape-only") { config.visibility = .shape }
        let theme = try args.theme()
        let started = Date()
        let commits = try GitLog.read(repository: repo, allowShallow: args.flags.contains("allow-shallow"))
        let name = args.options["name"] ?? repo.lastPathComponent
        let city = CityGenerator.city(
            from: commits, name: name, config: config, generatedAt: try args.time("now") ?? currentTime())
        try writeOutputs(city, theme: theme, to: out)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        print("commitcity: \(commits.count) commits → \(city.buildingCount) buildings in \(out.path) (\(elapsed) ms)")

    case "merge":
        let args = try Arguments(rest, valued: ["out", "name", "theme", "now"], flags: [])
        guard let outPath = args.options["out"] else { throw CLIError("merge needs --out DIR") }
        guard !args.positional.isEmpty else { throw CLIError("merge needs at least one city.json") }
        // One broken or unreachable repo must not take the whole personal city down.
        var cities = [City]()
        for path in args.positional {
            do {
                cities.append(try loadCity(path))
            } catch {
                standardError("warning: skipping \(path): \(error)")
            }
        }
        guard !cities.isEmpty else { throw CLIError("none of the \(args.positional.count) inputs was a readable city.json") }
        let merged = CityMerger.merge(
            cities, name: args.options["name"] ?? "personal city", generatedAt: try args.time("now") ?? currentTime())
        try writeOutputs(merged, theme: try args.theme(), to: try directory(outPath))
        print("commitcity: merged \(merged.districts.count) districts, \(merged.buildingCount) buildings")

    case "render":
        let args = try Arguments(rest, valued: ["out", "theme", "at"], flags: ["card", "reduced", "massing"])
        guard args.positional.count == 1 else { throw CLIError("render needs exactly one city.json") }
        guard let outPath = args.options["out"] else { throw CLIError("render needs --out FILE.svg") }
        let city = try loadCity(args.positional[0])
        let svg = SVGRenderer.render(
            city: city, theme: try args.theme(), at: try args.time("at"),
            layout: args.flags.contains("card") ? .card : .readme(width: 1200),
            detail: args.flags.contains("massing") ? .massing : args.flags.contains("reduced") ? .reduced : nil)
        try write(svg, to: URL(fileURLWithPath: outPath))

    case "badge":
        let args = try Arguments(rest, valued: ["out", "theme", "link"], flags: [])
        guard args.positional.count == 1 else { throw CLIError("badge needs exactly one city.json") }
        guard let outPath = args.options["out"] else { throw CLIError("badge needs --out FILE.svg") }
        let city = try loadCity(args.positional[0])
        try write(Badge.render(city: city, theme: try args.theme()), to: URL(fileURLWithPath: outPath))
        print(Badge.markdown(imageURL: outPath, link: args.options["link"]))

    case "scene":
        // Debug/parity: dumps the painter-ordered primitive list the renderers consume.
        let args = try Arguments(rest, valued: ["at"], flags: ["reduced", "massing"])
        guard args.positional.count == 1 else { throw CLIError("scene needs exactly one city.json") }
        let city = try loadCity(args.positional[0])
        let level: DetailLevel = args.flags.contains("massing") ? .massing : args.flags.contains("reduced") ? .reduced : .full
        let scene = Scene.build(city: city, at: try args.time("at") ?? city.generatedAt, detail: level)
        FileHandle.standardOutput.write(SceneDump.json(scene))

    case "demo":
        let args = try Arguments(rest, valued: ["out", "theme"], flags: [])
        let out = try directory(args.options["out"] ?? "commit-city-demo")
        try writeOutputs(DemoCity.city(), theme: try args.theme(), to: out)
        print("commitcity: demo city written to \(out.path)")

    case "help", "--help", "-h":
        print(usage)

    default:
        throw CLIError("unknown command \(argv[1])\n\n\(usage)")
    }
}

do {
    try run(CommandLine.arguments)
} catch {
    standardError("commitcity: error: \(error)")
    exit(1)
}
