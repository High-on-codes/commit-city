/// How time treats a district: alpha and dash only, never a new colour.
public enum DecayState: Equatable, Sendable {
    /// Commits in the last 30 days.
    case active
    /// 30–90 days without commits; `progress` runs 0 → 1 across that window.
    case idle(progress: Double)
    /// 90+ days; `progress` runs 0 → 1 over the following nine months, then holds.
    case abandoned(progress: Double)
    /// Marked `status: finished`. Never decays.
    case finished

    public static let idleAfterDays = 30.0
    public static let abandonedAfterDays = 90.0
    public static let ghostAfterDays = 365.0

    public static func evaluate(lastActiveAt: Int64, now: Int64, finished: Bool) -> DecayState {
        if finished { return .finished }
        let days = max(0, Double(now - lastActiveAt) / 86_400)
        if days < idleAfterDays { return .active }
        if days < abandonedAfterDays {
            return .idle(progress: (days - idleAfterDays) / (abandonedAfterDays - idleAfterDays))
        }
        return .abandoned(progress: min(1, (days - abandonedAfterDays) / (ghostAfterDays - abandonedAfterDays)))
    }

    /// Multiplier for structural linework.
    public var structureAlpha: Double {
        switch self {
        case .active, .idle, .finished: 1
        case let .abandoned(progress): 0.72 - 0.50 * progress
        }
    }

    /// Multiplier for lit windows.
    public var windowAlpha: Double {
        switch self {
        case .active, .finished: 1
        case let .idle(progress): 1 - 0.85 * progress
        case let .abandoned(progress): 0.15 * (1 - progress)
        }
    }

    /// Abandoned linework is dashed; the gaps open up as it fades toward a ghost outline.
    public var dashPattern: [Double]? {
        guard case let .abandoned(progress) = self else { return nil }
        let gap = 1.5 + 2.5 * progress
        return [3, gap]
    }

    public var label: String {
        switch self {
        case .active: "active"
        case .idle: "idle"
        case .abandoned: "abandoned"
        case .finished: "finished"
        }
    }
}

/// The resolved look of one building at one instant: district decay, plus neglected
/// neighborhoods inside a living district dimming their windows ("decay on neglected areas").
public struct BuildingLook: Equatable, Sendable {
    public var structureAlpha: Double
    public var windowAlpha: Double
    public var dashPattern: [Double]?

    public static func resolve(district: District, neighborhood: Int, now: Int64) -> BuildingLook {
        let finished = district.status == .finished
        let districtState = DecayState.evaluate(
            lastActiveAt: district.lastCommitAt, now: now, finished: finished)
        var windowAlpha = districtState.windowAlpha
        if !finished, district.neighborhoods.indices.contains(neighborhood) {
            let area = DecayState.evaluate(
                lastActiveAt: district.neighborhoods[neighborhood].lastActiveAt, now: now, finished: false)
            // Areas only ever dim windows; a district stays structurally whole while anyone works in it.
            switch area {
            case .active, .finished: break
            case let .idle(progress): windowAlpha = min(windowAlpha, 1 - 0.6 * progress)
            case .abandoned: windowAlpha = min(windowAlpha, 0.4)
            }
        }
        return BuildingLook(
            structureAlpha: districtState.structureAlpha, windowAlpha: windowAlpha,
            dashPattern: districtState.dashPattern)
    }
}
