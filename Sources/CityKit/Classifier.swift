/// Pure functions that turn a raw commit into the facts the generator needs.
public enum Classifier {
    // MARK: Paths

    private static let ignoredFileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "Cargo.lock", "Package.resolved",
        "Podfile.lock", "Gemfile.lock", "poetry.lock", "composer.lock", "go.sum", "Pipfile.lock", "uv.lock",
        "mix.lock", "flake.lock",
    ]

    private static let ignoredDirectories: Set<String> = [
        "node_modules", "vendor", "Pods", "Carthage", ".build", "DerivedData", "dist", "build", "target",
        "__pycache__", ".venv", "venv", "third_party", "third-party",
    ]

    private static let ignoredSuffixes = [".min.js", ".min.css", ".map", ".snap", ".pbxproj"]

    /// Generated, vendored and lock files would turn every dependency bump into a skyscraper.
    /// They still count as files touched, but never as lines changed.
    public static func isNoise(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let fileName = components.last else { return true }
        if ignoredFileNames.contains(String(fileName)) { return true }
        for directory in components.dropLast() where ignoredDirectories.contains(String(directory)) {
            return true
        }
        let lowered = fileName.lowercased()
        return ignoredSuffixes.contains { lowered.hasSuffix($0) }
    }

    /// Lines changed, excluding noise. Saturating, so a pathological numstat cannot overflow.
    public static func linesChanged(_ commit: Commit) -> Int {
        var total = 0
        for file in commit.files where !file.isBinary && !isNoise(file.path) {
            let (sum, overflow) = total.addingReportingOverflow(file.linesChanged)
            total = overflow ? Int.max : sum
        }
        return total
    }

    // MARK: Language

    private static let extensionLanguages: [String: Language] = [
        "swift": .swift,
        "py": .python, "pyi": .python, "ipynb": .python,
        "rs": .rust,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "go": .go,
        "c": .c, "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "m": .c, "mm": .cpp,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "cs": .csharp,
        "rb": .ruby, "erb": .ruby,
        "php": .php,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "ps1": .shell,
        "html": .web, "htm": .web, "css": .web, "scss": .web, "sass": .web, "less": .web, "vue": .web,
        "svelte": .web, "astro": .web,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown, "rst": .markdown, "adoc": .markdown,
        "json": .config, "yml": .config, "yaml": .config, "toml": .config, "xml": .config, "plist": .config,
        "ini": .config, "cfg": .config, "conf": .config, "lock": .config, "gradle": .config, "cmake": .config,
    ]

    private static let fileNameLanguages: [String: Language] = [
        "Dockerfile": .config, "Makefile": .config, "Package.swift": .swift, "Gemfile": .ruby,
        "Rakefile": .ruby, "Podfile": .ruby, "LICENSE": .markdown, "README": .markdown,
    ]

    public static func language(ofPath path: String) -> Language {
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        if let known = fileNameLanguages[fileName] { return known }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return .other }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return extensionLanguages[ext] ?? .other
    }

    /// Language with the most changed lines; falls back to file count when no lines changed
    /// (binary-only or rename-only commits). Ties resolve by declaration order of `Language`.
    public static func dominantLanguage(_ commit: Commit) -> Language {
        var lines = [Language: Int]()
        var files = [Language: Int]()
        for file in commit.files {
            let language = language(ofPath: file.path)
            files[language, default: 0] += 1
            if !file.isBinary && !isNoise(file.path) {
                lines[language, default: 0] += file.linesChanged
            }
        }
        let weights = lines.values.contains(where: { $0 > 0 }) ? lines : files
        var best = Language.other
        var bestWeight = 0
        for language in Language.allCases {
            let weight = weights[language] ?? 0
            if weight > bestWeight {
                best = language
                bestWeight = weight
            }
        }
        return best
    }

    // MARK: Commit type

    private static let typeAliases: [String: CommitType] = [
        "feat": .feat, "feature": .feat, "fix": .fix, "bugfix": .fix, "hotfix": .fix, "docs": .docs,
        "doc": .docs, "refactor": .refactor, "perf": .perf, "test": .test, "tests": .test, "chore": .chore,
        "style": .style, "build": .build, "ci": .ci, "revert": .revert,
    ]

    /// Conventional Commits (`type(scope)!: subject`), plus the common unprefixed forms
    /// ("Fix crash…", "Revert \"…\"", "Update README").
    public static func commitType(subject: String) -> CommitType {
        let trimmed = subject.drop(while: { $0 == " " })
        if let colon = trimmed.firstIndex(of: ":") {
            var head = trimmed[..<colon]
            if head.hasSuffix("!") { head = head.dropLast() }
            if let paren = head.firstIndex(of: "(") { head = head[..<paren] }
            if let type = typeAliases[head.lowercased()] { return type }
        }
        let firstWord = trimmed.prefix(while: { $0.isLetter }).lowercased()
        switch firstWord {
        case "fix", "fixes", "fixed", "bugfix", "hotfix": return .fix
        case "revert": return .revert
        case "add", "adds", "added", "implement", "implements", "introduce": return .feat
        case "doc", "docs", "document": return .docs
        default: return .other
        }
    }

    // MARK: Neighborhoods

    /// Conventional container folders whose children are the real neighborhoods
    /// (`Sources/CityKit`, `packages/web`, `src/parser`).
    private static let containerFolders: Set<String> = [
        "src", "Sources", "Tests", "lib", "libs", "packages", "apps", "app", "cmd", "internal", "pkg",
        "crates", "modules", "services", "test", "tests", "Packages",
    ]

    public static func neighborhoodKey(ofPath path: String) -> String {
        let folders = path.split(separator: "/", omittingEmptySubsequences: true).dropLast().map(String.init)
        guard let first = folders.first else { return "/" }
        if containerFolders.contains(first), folders.count >= 2 {
            return first + "/" + folders[1]
        }
        return first
    }

    /// The folder holding most of the commit's changed lines (files when no lines changed).
    /// Ties break lexicographically so the answer never depends on numstat order.
    public static func dominantNeighborhood(_ commit: Commit) -> String {
        guard !commit.files.isEmpty else { return "/" }
        var weights = [String: (lines: Int, files: Int)]()
        for file in commit.files {
            let key = neighborhoodKey(ofPath: file.path)
            let lines = (file.isBinary || isNoise(file.path)) ? 0 : file.linesChanged
            let current = weights[key, default: (0, 0)]
            weights[key] = (current.lines + lines, current.files + 1)
        }
        return weights.max { lhs, rhs in
            if lhs.value.lines != rhs.value.lines { return lhs.value.lines < rhs.value.lines }
            if lhs.value.files != rhs.value.files { return lhs.value.files < rhs.value.files }
            return lhs.key > rhs.key
        }!.key
    }

    // MARK: Style

    public static func style(for language: Language) -> BuildingStyle {
        switch language {
        case .swift, .kotlin: .glassTower
        case .python: .lowBlock
        case .rust, .c, .cpp: .factory
        case .javascript, .typescript, .go: .steppedTower
        case .java, .csharp, .other: .slab
        case .ruby, .php, .shell, .config, .web: .gabled
        case .markdown: .park
        }
    }
}
