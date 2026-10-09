import Foundation

public enum GitLogError: Error, CustomStringConvertible, Equatable {
    case gitFailed(status: Int32, stderr: String)
    case gitNotFound(String)
    case malformedRecord(index: Int, reason: String)
    case shallowRepository

    public var description: String {
        switch self {
        case let .gitFailed(status, stderr):
            "git exited with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .gitNotFound(reason):
            "could not launch git: \(reason)"
        case let .malformedRecord(index, reason):
            "malformed git log record #\(index): \(reason)"
        case .shallowRepository:
            "the repository is a shallow clone, so the city would be missing its history. "
                + "Fetch full history (actions/checkout with fetch-depth: 0) or pass --allow-shallow."
        }
    }
}

/// Reads history with one `git log` call and parses it without regexes or intermediate strings
/// per field. The format uses ASCII record/unit separators and `-z`, so subjects, names and
/// paths with tabs, quotes or non-ASCII bytes survive untouched.
public enum GitLog {
    static let recordSeparator: UInt8 = 0x1E
    static let unitSeparator: UInt8 = 0x1F

    public static let arguments: [String] = [
        "-c", "core.quotePath=false",
        "-c", "log.showSignature=false",
        "log",
        "--reverse",
        "--topo-order",
        "--no-merges",
        "--no-renames",
        "--no-color",
        "--no-ext-diff",
        "-z",
        "--numstat",
        "--format=%x1e%H%x1f%at%x1f%ai%x1f%an%x1f%ae%x1f%s",
    ]

    /// Reads the full history of `HEAD` in `repository`. An empty repository yields `[]`.
    public static func read(repository: URL, allowShallow: Bool = false) throws -> [Commit] {
        if try !hasCommits(repository: repository) { return [] }
        if !allowShallow {
            let shallow = try runGit(["rev-parse", "--is-shallow-repository"], in: repository)
            if String(decoding: shallow, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
                throw GitLogError.shallowRepository
            }
        }
        let output = try runGit(arguments, in: repository)
        return try parse(output)
    }

    static func hasCommits(repository: URL) throws -> Bool {
        do {
            _ = try runGit(["rev-parse", "--verify", "--quiet", "HEAD"], in: repository)
            return true
        } catch GitLogError.gitFailed(status: 1, stderr: _) {
            return false
        }
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> [Commit] {
        var commits = [Commit]()
        let bytes = [UInt8](data)
        var recordIndex = 0
        var cursor = 0
        // Skip anything before the first record separator (there is nothing in practice).
        while cursor < bytes.count, bytes[cursor] != recordSeparator { cursor += 1 }
        while cursor < bytes.count {
            let start = cursor + 1
            var end = start
            while end < bytes.count, bytes[end] != recordSeparator { end += 1 }
            commits.append(try parseRecord(bytes[start..<end], index: recordIndex))
            recordIndex += 1
            cursor = end
        }
        return commits
    }

    private static func parseRecord(_ record: ArraySlice<UInt8>, index: Int) throws -> Commit {
        guard let headerEnd = record.firstIndex(of: 0) else {
            throw GitLogError.malformedRecord(index: index, reason: "missing header terminator")
        }
        let fields = record[record.startIndex..<headerEnd]
            .split(separator: unitSeparator, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 6 else {
            throw GitLogError.malformedRecord(index: index, reason: "expected 6 header fields, got \(fields.count)")
        }
        guard let authorTime = Int64(fields[1]) else {
            throw GitLogError.malformedRecord(index: index, reason: "bad author time \(fields[1])")
        }
        let offsetMinutes = try parseOffset(fields[2], index: index)

        var files = [FileChange]()
        for entry in record[(headerEnd + 1)...].split(separator: 0) {
            // Each entry is "added\tdeleted\tpath", possibly preceded by the newline git emits
            // between the header and the first numstat line.
            let trimmed = entry.drop(while: { $0 == 0x0A })
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: 0x09, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                throw GitLogError.malformedRecord(index: index, reason: "bad numstat entry")
            }
            let path = String(decoding: parts[2], as: UTF8.self)
            let added = String(decoding: parts[0], as: UTF8.self)
            let deleted = String(decoding: parts[1], as: UTF8.self)
            if added == "-" || deleted == "-" {
                files.append(FileChange(path: path, linesAdded: 0, linesDeleted: 0, isBinary: true))
            } else if let added = Int(added), let deleted = Int(deleted), added >= 0, deleted >= 0 {
                files.append(FileChange(path: path, linesAdded: added, linesDeleted: deleted))
            } else {
                throw GitLogError.malformedRecord(index: index, reason: "bad numstat counts for \(path)")
            }
        }

        return Commit(
            sha: fields[0], authorName: fields[3], authorEmail: fields[4], authorTime: authorTime,
            utcOffsetMinutes: offsetMinutes, subject: fields[5], files: files)
    }

    /// `%ai` is "YYYY-MM-DD HH:MM:SS ±HHMM"; only the offset is needed.
    private static func parseOffset(_ isoDate: String, index: Int) throws -> Int {
        guard let token = isoDate.split(separator: " ").last, token.count == 5,
            let sign = token.first, sign == "+" || sign == "-",
            let hours = Int(token.dropFirst().prefix(2)), let minutes = Int(token.suffix(2))
        else {
            throw GitLogError.malformedRecord(index: index, reason: "bad author date \(isoDate)")
        }
        let magnitude = hours * 60 + minutes
        return sign == "-" ? -magnitude : magnitude
    }

    // MARK: Process

    /// Runs git and returns stdout. stderr goes to a temporary file rather than a second pipe, so a
    /// chatty stderr can never fill its pipe buffer and deadlock against our stdout read.
    static func runGit(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardInput = FileHandle.nullDevice

        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("commitcity-git-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw GitLogError.gitNotFound("cannot create temporary file at \(stderrURL.path)")
        }
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw GitLogError.gitNotFound(String(describing: error))
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw GitLogError.gitFailed(status: process.terminationStatus, stderr: stderr)
        }
        return output
    }
}

/// The optional one-file repo config. One line is enough: `status: finished`.
public struct RepoConfig: Sendable, Equatable {
    public var status: DistrictStatus = .active
    public var visibility: Visibility = .full
    /// Display name override (also what a shape-only district is called).
    public var label: String?
    public var seed: UInt64?
    public var warnings: [String] = []

    public init() {}

    public static let fileName = ".commitcity"

    public static func parse(_ text: String) -> RepoConfig {
        var config = RepoConfig()
        for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else {
                config.warnings.append("line \(lineNumber + 1): expected `key: value`")
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "status":
                if let status = DistrictStatus(rawValue: value.lowercased()) {
                    config.status = status
                } else {
                    config.warnings.append("line \(lineNumber + 1): status must be `active` or `finished`")
                }
            case "visibility":
                if let visibility = Visibility(rawValue: value.lowercased()) {
                    config.visibility = visibility
                } else {
                    config.warnings.append("line \(lineNumber + 1): visibility must be `full` or `shape`")
                }
            case "label", "name":
                config.label = value.isEmpty ? nil : value
            case "seed":
                if let seed = UInt64(value) {
                    config.seed = seed
                } else {
                    config.warnings.append("line \(lineNumber + 1): seed must be a non-negative integer")
                }
            default:
                config.warnings.append("line \(lineNumber + 1): unknown key `\(key)` ignored")
            }
        }
        return config
    }

    public static func load(repository: URL) -> RepoConfig {
        let url = repository.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return RepoConfig() }
        return parse(text)
    }
}
