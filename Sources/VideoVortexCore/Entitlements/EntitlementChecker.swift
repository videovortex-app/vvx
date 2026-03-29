import Foundation

// MARK: - Pro features

/// Named Pro-tier features. Adding a case here is the only change needed to
/// gate a new feature — no `if pro` sprawl in individual commands.
public enum ProFeature: String, Sendable, Codable {
    case gather
    case nleExport
}

// MARK: - Entitlement checker

/// Single source of truth for Pro-feature access.
///
/// **Public Beta:** all features are allowed by default.
/// Set `VVX_FORCE_PRO_DENIED=1` in the environment to simulate denial
/// (test and CI use only — not a real billing gate).
///
/// **Step 11 (billing):** wire Lemon Squeezy or equivalent here by replacing
/// `canUse` with a cached remote-config lookup.
///
/// **Offline contract (mandatory, non-negotiable):**
/// Any network call added in Step 11 MUST be wrapped in a `do/catch` or
/// `catch` that returns `true` on timeout, network error, or malformed
/// response. Local workflows and agent pipelines must never be bricked by a
/// billing dependency.
// TODO: Step 12 — when wiring billing, any timeout or network failure in
// canUse MUST be caught and return true to preserve the offline fail-open policy.
public enum EntitlementChecker {

    /// Returns `true` when `feature` may proceed.
    ///
    /// Beta default: always `true`.
    /// Test override: set `VVX_FORCE_PRO_DENIED=1` to return `false` for all features.
    public static func canUse(_ feature: ProFeature) async -> Bool {
        if ProcessInfo.processInfo.environment["VVX_FORCE_PRO_DENIED"] == "1" {
            return false
        }
        // TODO: Step 12 — replace with cached remote license/config check here.
        // IMPORTANT: catch ALL errors from the network call and return true
        // (fail-open). Example:
        //   do { return try await RemoteLicense.check(feature) }
        //   catch { return true }
        return true
    }

    /// Throws `VvxError(code: .proRequired, …)` when `feature` is not allowed.
    ///
    /// Call this as the **first** statement in any Pro-gated command `run()`.
    public static func requirePro(_ feature: ProFeature) async throws {
        guard await canUse(feature) else {
            throw VvxError(
                code: .proRequired,
                message: "'\(feature.rawValue)' requires a VVX Pro license."
            )
        }
    }
}
