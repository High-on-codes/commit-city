/// Renders a city as a self-contained blueprint SVG. No scripts, no external fonts, no filters:
/// GitHub's image proxy and every browser draw it the same.
public enum SVGRenderer {
    public enum Layout: Sendable, Equatable {
        /// README image: fixed width, height follows the city.
        case readme(width: Int)
        /// Share card: fixed 1200×630 frame with a large caption.
        case card
    }

    /// Above this many buildings windows are dropped so the file stays small and fast to decode.
    public static let reducedDetailThreshold = 2_500
    /// Above this many, blocks are drawn as massing volumes (see `DetailLevel.massing`).
    public static let massingThreshold = 12_000

    static let fontStack = "ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace"

    public static func render(
        city: City, theme: Theme = .carbon, at time: Int64? = nil, layout: Layout = .readme(width: 1200),
        detail: DetailLevel? = nil
    ) -> String {
        let instant = time ?? city.generatedAt
        let visibleBuildings = city.districts.reduce(0) { total, district in
            total + district.buildings.reduce(0) { $0 + ($1.bornAt <= instant ? 1 : 0) }
        }
        let level = detail ?? (visibleBuildings > massingThreshold ? .massing : visibleBuildings > reducedDetailThreshold ? .reduced : .full)
        let scene = Scene.build(city: city, at: instant, detail: level)

        let frame = Frame(layout: layout, sceneBounds: scene.bounds)
        var svg = SVGWriter(capacity: 64 * 1024 + scene.items.count * 900)
        svg.raw("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(frame.width)\" height=\"\(frame.height)\" viewBox=\"0 0 \(frame.width) \(frame.height)\" role=\"img\" aria-label=\"")
        svg.raw(Format.xmlEscaped("\(city.name): a city of \(scene.buildingCount) buildings grown from \(city.commitCount) commits"))
        svg.raw("\">\n<style>")
        // Hairlines stay hairlines: when a whole huge city is squeezed into the frame, line weights
        // thin with the scale so structure does not turn into a solid grey mat.
        let weight = min(1, max(0.4, frame.scale / 10))
        svg.raw(".o{fill:\(theme.background);stroke:none}")
        svg.raw(".f{fill:\(theme.background)}")
        for ink in Ink.allCases {
            let stroke = theme.stroke(ink)
            svg.raw(".k\(ink.rawValue){fill:none;stroke:\(theme.color(for: ink));stroke-opacity:\(Format.fixed2(stroke.alpha));stroke-width:\(Format.fixed2(stroke.width * weight))")
            if let dash = stroke.dash {
                svg.raw(";stroke-dasharray:\(dash.map { Format.fixed2($0 * weight) }.joined(separator: " "))")
            }
            svg.raw("}")
        }
        svg.raw("path,circle{stroke-linecap:round;stroke-linejoin:round}")
        svg.raw("text{font-family:\(fontStack);fill:\(theme.ink)}")
        svg.raw(".a{fill:\(theme.accent)}")
        svg.raw("</style>\n")
        svg.raw("<rect width=\"100%\" height=\"100%\" fill=\"\(theme.background)\"/>\n")

        drawScene(scene, frame: frame, into: &svg)
        drawCaption(city: city, scene: scene, theme: theme, instant: instant, frame: frame, layout: layout, into: &svg)
        svg.raw("</svg>\n")
        return svg.output
    }

    // MARK: Frame

    struct Frame {
        var width: Int
        var height: Int
        var scale: Double
        var originX: Double
        var originY: Double
        var captionTop: Double

        static let padding = 40.0
        static let captionHeight = 86.0

        init(layout: Layout, sceneBounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)?) {
            let bounds = sceneBounds ?? (-6, -4, 6, 4)
            let worldWidth = max(1, bounds.maxX - bounds.minX)
            let worldHeight = max(1, bounds.maxY - bounds.minY)
            switch layout {
            case let .readme(width):
                let usable = Double(max(480, width)) - 2 * Frame.padding
                // Small cities are not blown up into cartoons, huge ones do not become grey dust.
                var scale = min(26, usable / worldWidth)
                scale = min(scale, 900 / worldHeight)
                scale = max(scale, 1.5)
                self.width = max(480, width)
                let drawingHeight = worldHeight * scale
                height = Int((drawingHeight + 2 * Frame.padding + Frame.captionHeight).rounded(.up))
                self.scale = scale
                originX = (Double(self.width) - worldWidth * scale) / 2 - bounds.minX * scale
                originY = Frame.padding - bounds.minY * scale
                captionTop = Frame.padding + drawingHeight + 18
            case .card:
                width = 1200
                height = 630
                let areaWidth = 1200 - 2 * Frame.padding
                let areaHeight = 630 - 2 * Frame.padding - 70
                let scale = max(1.5, min(30, areaWidth / worldWidth, areaHeight / worldHeight))
                self.scale = scale
                originX = (1200 - worldWidth * scale) / 2 - bounds.minX * scale
                originY = Frame.padding + (areaHeight - worldHeight * scale) / 2 - bounds.minY * scale
                captionTop = 630 - Frame.padding - 52
            }
        }

        @inline(__always)
        func point(_ v: Vec3) -> (x: Double, y: Double) {
            let p = Blueprint.project(v)
            return (originX + p.x * scale, originY + p.y * scale)
        }
    }

    // MARK: Scene

    static func drawScene(_ scene: Scene, frame: Frame, into svg: inout SVGWriter) {
        // Strokes are emitted in runs: consecutive lines with the same ink share one <path>.
        var runInk: Ink?
        var runIsOccluder = false
        var runData = ""
        var runLook = BuildingLook(structureAlpha: 1, windowAlpha: 1, dashPattern: nil)

        func flush() {
            guard !runData.isEmpty else { return }
            if runIsOccluder {
                svg.raw("<path class=\"o\" d=\"\(runData)\"/>")
            } else if let ink = runInk {
                svg.raw("<path class=\"k\(ink.rawValue)\"")
                appendLookAttributes(runLook, ink: ink, into: &svg)
                svg.raw(" d=\"\(runData)\"/>")
            }
            runData = ""
            runInk = nil
        }

        // Absolute move, then relative segments between *already rounded* points: ~35% smaller
        // than absolute coordinates, and the rounding never accumulates into drift.
        func appendPath(_ points: [Vec3], closed: Bool) {
            var previous = (x: 0, y: 0)
            for (index, point) in points.enumerated() {
                let p = frame.point(point)
                let current = (x: Format.tenths(p.x), y: Format.tenths(p.y))
                if index == 0 {
                    runData += "M" + Format.decimal(tenths: current.x) + " " + Format.decimal(tenths: current.y)
                } else {
                    let dx = current.x - previous.x, dy = current.y - previous.y
                    runData += (index == 1 ? "l" : " ") + Format.decimal(tenths: dx)
                    runData += dy < 0 ? Format.decimal(tenths: dy) : " " + Format.decimal(tenths: dy)
                }
                previous = current
            }
            if closed { runData += "z" }
        }

        for item in scene.items {
            if item.look != runLook {
                flush()
                runLook = item.look
            }
            for primitive in item.primitives {
                switch primitive {
                case let .occluder(points):
                    if !runIsOccluder { flush() }
                    runIsOccluder = true
                    appendPath(points, closed: true)
                case let .line(points, ink, closed):
                    if runIsOccluder || runInk != ink { flush() }
                    runIsOccluder = false
                    runInk = ink
                    appendPath(points, closed: closed)
                case let .disc(center, radius, ink):
                    flush()
                    runIsOccluder = false
                    let p = frame.point(center)
                    svg.raw("<circle class=\"k\(ink.rawValue) f\" cx=\"\(Format.coordinate(p.x))\" cy=\"\(Format.coordinate(p.y))\" r=\"\(Format.coordinate(max(0.6, radius * frame.scale)))\"")
                    appendLookAttributes(item.look, ink: ink, into: &svg)
                    svg.raw("/>")
                }
            }
            flush()
            svg.raw("\n")
        }
        flush()
    }

    /// Decay is opacity and dash only. `opacity` multiplies the class's stroke-opacity and, unlike
    /// a presentation `stroke-opacity`, is not overridden by the stylesheet.
    static func appendLookAttributes(_ look: BuildingLook, ink: Ink, into svg: inout SVGWriter) {
        let multiplier = ink == .windowLit ? look.windowAlpha : look.structureAlpha
        if multiplier < 0.995 {
            svg.raw(" opacity=\"\(Format.fixed2(max(0, multiplier)))\"")
        }
        if let dash = look.dashPattern, ink != .windowLit, ink != .windowDark, ink != .road {
            svg.raw(" stroke-dasharray=\"\(dash.map(Format.fixed2).joined(separator: " "))\"")
        }
    }

    // MARK: Caption

    static func drawCaption(
        city: City, scene: Scene, theme: Theme, instant: Int64, frame: Frame, layout: Layout,
        into svg: inout SVGWriter
    ) {
        let left = Frame.padding
        let top = frame.captionTop
        let finishedCount = city.districts.filter { $0.status == .finished }.count
        let state: String
        if city.districts.count == 1, let district = city.districts.first {
            state = DecayState.evaluate(
                lastActiveAt: district.lastCommitAt, now: instant, finished: district.status == .finished
            ).label
        } else {
            state = "\(city.districts.count) districts" + (finishedCount > 0 ? " · \(finishedCount) finished" : "")
        }
        let commitsSoFar = city.districts.reduce(0) { total, district in
            total + district.buildings.filter { $0.bornAt <= instant }.reduce(0) {
                $0 + 1 + $1.repairs.filter { $0 <= instant }.count + max(0, $1.trees.filter { $0 <= instant }.count - 1)
            }
        }
        let stats = [
            "\(Format.grouped(instant >= city.generatedAt ? city.commitCount : commitsSoFar)) commits",
            "\(Format.grouped(scene.buildingCount)) buildings",
            "\(Format.grouped(city.districts.map(\.longestStreakDays).max() ?? 0))-day best streak",
        ].joined(separator: " · ").uppercased()
        let since = city.firstCommitAt.map { "since \(Format.date($0))" } ?? "no commits yet"
        let footer = "\(state) · \(since) · drawn \(Format.date(instant))".uppercased()

        let titleSize: Double = layout == .card ? 26 : 15
        let name = Format.xmlEscaped(city.name)
        // Monospace advance ≈ 0.6 em; size the rule to the longest line.
        let longest = max(Double(city.name.count) * titleSize * 0.6, Double(max(stats.count, footer.count)) * 9 * 0.62)
        let ruleWidth = min(Double(frame.width) - 2 * left, longest + 8)

        let accent = theme.accent
        svg.raw("<g>")
        svg.raw("<text class=\"a\" x=\"\(Format.coordinate(left))\" y=\"\(Format.coordinate(top))\" font-size=\"9\" letter-spacing=\"2.4\">COMMIT CITY</text>")
        svg.raw("<text x=\"\(Format.coordinate(left))\" y=\"\(Format.coordinate(top + titleSize + 8))\" font-size=\"\(Format.coordinate(titleSize))\" font-weight=\"500\">\(name)</text>")
        let ruleY = top + titleSize + 17
        svg.raw("<path d=\"M\(Format.coordinate(left)) \(Format.coordinate(ruleY))h\(Format.coordinate(ruleWidth))\" stroke=\"\(theme.ink)\" stroke-opacity=\"0.25\" stroke-width=\"0.6\"/>")
        svg.raw("<path d=\"M\(Format.coordinate(left)) \(Format.coordinate(ruleY))h18\" stroke=\"\(accent)\" stroke-width=\"1.2\"/>")
        svg.raw("<text x=\"\(Format.coordinate(left))\" y=\"\(Format.coordinate(ruleY + 15))\" font-size=\"9\" letter-spacing=\"0.9\" fill-opacity=\"0.62\">\(Format.xmlEscaped(stats))</text>")
        svg.raw("<text x=\"\(Format.coordinate(left))\" y=\"\(Format.coordinate(ruleY + 29))\" font-size=\"9\" letter-spacing=\"0.9\" fill-opacity=\"0.38\">\(Format.xmlEscaped(footer))</text>")
        if scene.buildingCount == 0 {
            let cx = Double(frame.width) / 2
            svg.raw("<text x=\"\(Format.coordinate(cx))\" y=\"\(Format.coordinate(Frame.padding + 80))\" font-size=\"10\" letter-spacing=\"1.6\" text-anchor=\"middle\" fill-opacity=\"0.45\">EMPTY LOT · THE FIRST COMMIT BREAKS GROUND</text>")
        }
        svg.raw("</g>\n")
    }
}

/// Append-only string builder; avoids interpolation temporaries in the hot loop.
struct SVGWriter {
    private(set) var output: String

    init(capacity: Int) {
        output = ""
        output.reserveCapacity(capacity)
    }

    mutating func raw(_ text: String) {
        output += text
    }
}
