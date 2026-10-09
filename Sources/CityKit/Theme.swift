/// A palette is a background, one neutral ink and one accent. Everything else is alpha and weight.
public struct Theme: Sendable, Equatable {
    public struct Stroke: Sendable, Equatable {
        public var useAccent: Bool
        public var alpha: Double
        public var width: Double
        public var dash: [Double]? = nil
    }

    public var name: String
    /// "#RRGGBB"
    public var background: String
    public var ink: String
    public var accent: String
    public var isPremium: Bool

    /// Weights are in output pixels at scale; hairline structure, heavier landmarks.
    public func stroke(_ ink: Ink) -> Stroke {
        switch ink {
        case .structure: Stroke(useAccent: false, alpha: 0.80, width: 0.8)
        case .detail: Stroke(useAccent: false, alpha: 0.34, width: 0.55)
        case .windowLit: Stroke(useAccent: true, alpha: 0.95, width: 1.0)
        case .windowDark: Stroke(useAccent: false, alpha: 0.085, width: 0.9)
        case .ground: Stroke(useAccent: false, alpha: 0.16, width: 0.6)
        case .landmark: Stroke(useAccent: false, alpha: 0.96, width: 1.35)
        case .accent: Stroke(useAccent: true, alpha: 1.0, width: 1.1)
        case .road: Stroke(useAccent: false, alpha: 0.22, width: 0.6, dash: [1.5, 3.5])
        }
    }

    public func color(for ink: Ink) -> String {
        stroke(ink).useAccent ? accent : self.ink
    }

    /// Carbon black, warm white linework, butter accent. Free.
    public static let carbon = Theme(
        name: "carbon", background: "#111111", ink: "#ECE8DD", accent: "#E9D58B", isPremium: false)
    /// Classic cyanotype.
    public static let cyanotype = Theme(
        name: "cyanotype", background: "#0E2238", ink: "#D8E4F0", accent: "#E9D58B", isPremium: true)
    /// Ink on drafting paper; the butter darkens so it still reads on a light ground.
    public static let vellum = Theme(
        name: "vellum", background: "#F1EDE3", ink: "#1D1D1B", accent: "#A8862A", isPremium: true)

    public static let all: [Theme] = [.carbon, .cyanotype, .vellum]

    public static func named(_ name: String) -> Theme? {
        all.first { $0.name == name.lowercased() }
    }
}
