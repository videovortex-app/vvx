import Foundation

/// Represents the current license/trial state of the macOS app.
/// In CLI/server contexts this is always treated as `.licensed` (no gating).
public enum AppState: Equatable, Sendable {
    case loading
    case trial(daysLeft: Int)
    case expired
    case licensed

    public var isRestricted: Bool {
        self == .expired
    }

    public var isTrial: Bool {
        if case .trial = self { return true }
        return false
    }

    public var daysLeft: Int? {
        if case .trial(let days) = self { return days }
        return nil
    }

    public var displayLabel: String {
        switch self {
        case .loading:             return "Loading..."
        case .trial(let days):     return "Trial: \(days) day\(days == 1 ? "" : "s") left"
        case .expired:             return "Trial Expired"
        case .licensed:            return "Pro"
        }
    }
}
