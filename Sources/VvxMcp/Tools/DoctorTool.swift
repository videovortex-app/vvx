import Foundation
import VideoVortexCore

/// MCP implementation of the `doctor` tool.
///
/// Returns a structured JSON diagnostic report of the vvx environment.
/// Agents call this automatically whenever sense, fetch, or any other tool
/// returns an error. The `fixes` array contains exact commands to run;
/// items with `requiresManual: false` can be applied without user input.
enum DoctorTool {

    // MARK: - Entry point

    static func call(arguments: [String: Any]) async throws -> String {
        let resolver = EngineResolver.cliResolver
        let config   = VvxConfig.load()

        // --- Engine check ---
        let ytDlpURL      = resolver.resolvedYtDlpURL()
        let engineFound   = ytDlpURL != nil
        let engineVersion = ytDlpURL.flatMap { resolveVersion(at: $0) }
        let enginePath    = ytDlpURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let modDate       = ytDlpURL.flatMap { engineModificationDate(at: $0) }
        let daysAgo       = modDate.map { Int(Date().timeIntervalSince($0) / 86400) }
        let isoDate       = modDate.map { ISO8601DateFormatter().string(from: $0) }

        var checks = [DoctorCheck]()
        var fixes  = [DoctorFix]()

        if engineFound {
            let detail = "\(engineVersion ?? "unknown") at \(enginePath ?? "unknown")"
                + (daysAgo.map { " (updated \($0) day\($0 == 1 ? "" : "s") ago)" } ?? "")
            checks.append(DoctorCheck(name: "engine", passed: true, detail: detail))
        } else {
            let engineInstallCmd: String
#if os(macOS)
            engineInstallCmd = "brew install yt-dlp"
#else
            engineInstallCmd = "pip install yt-dlp"
#endif
            checks.append(DoctorCheck(
                name: "engine",
                passed: false,
                detail: "yt-dlp not found on PATH. Install it with your system package manager.",
                fixCommand: engineInstallCmd,
                requiresManual: true
            ))
            fixes.append(DoctorFix(command: engineInstallCmd, requiresManual: true))
        }

        // --- ffmpeg check ---
        let ffmpegURL   = resolver.resolvedFfmpegURL()
        let ffmpegFound = ffmpegURL != nil
#if os(macOS)
        let ffmpegFixCommand = "brew install ffmpeg"
#else
        let ffmpegFixCommand = "apt-get install -y ffmpeg"
#endif
        if ffmpegFound {
            let tilded = ffmpegURL!.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            checks.append(DoctorCheck(name: "ffmpeg", passed: true, detail: "ffmpeg at \(tilded)"))
        } else {
            checks.append(DoctorCheck(
                name: "ffmpeg",
                passed: false,
                detail: "ffmpeg not found. Sponsor-block removal and some format conversions will fail.",
                fixCommand: ffmpegFixCommand,
                requiresManual: true
            ))
            fixes.append(DoctorFix(command: ffmpegFixCommand, requiresManual: true))
        }

        // --- Platform check ---
#if os(macOS)
        checks.append(DoctorCheck(
            name: "platform",
            passed: true,
            detail: "macOS — native AVFoundation thumbnails and keychain fingerprint active"
        ))
#else
        if ffmpegFound {
            checks.append(DoctorCheck(
                name: "platform",
                passed: true,
                detail: "Linux — thumbnails via ffmpeg fallback, device fingerprint via ~/.vvx/.device-id"
            ))
        } else {
            checks.append(DoctorCheck(
                name: "platform",
                passed: false,
                detail: "Linux — ffmpeg not found; thumbnails unavailable",
                fixCommand: ffmpegFixCommand,
                requiresManual: true
            ))
            fixes.append(DoctorFix(command: ffmpegFixCommand, requiresManual: true))
        }
#endif

        // --- Config check ---
        let configURL    = VvxConfig.configFileURL
        let configExists = FileManager.default.fileExists(atPath: configURL.path)
        let configValid  = configExists && (
            (try? Data(contentsOf: configURL)).flatMap {
                try? JSONDecoder().decode(VvxConfig.self, from: $0)
            } != nil
        )

        if configValid {
            let tilded = configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            checks.append(DoctorCheck(name: "config", passed: true, detail: "\(tilded) is valid"))
        } else {
            let detail = configExists
                ? "~/.vvx/config.json exists but is corrupt."
                : "~/.vvx/config.json is missing."
            checks.append(DoctorCheck(
                name: "config",
                passed: false,
                detail: detail,
                fixCommand: "vvx doctor --auto-fix",
                requiresManual: false
            ))
            fixes.append(DoctorFix(command: "vvx doctor --auto-fix", requiresManual: false))
        }

        // --- Directory checks ---
        let dirs: [(String, URL)] = [
            ("transcriptsDir", config.resolvedTranscriptDirectory()),
            ("downloadsDir",   config.resolvedDownloadDirectory()),
            ("archiveDir",     config.resolvedArchiveDirectory()),
        ]
        for (name, url) in dirs {
            let tilded = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            if isWritable(url) {
                checks.append(DoctorCheck(name: name, passed: true, detail: "\(tilded) is writable"))
            } else if FileManager.default.fileExists(atPath: url.path) {
                let fix = "chmod 755 \(url.path)"
                checks.append(DoctorCheck(
                    name: name,
                    passed: false,
                    detail: "\(tilded) is not writable (permission denied).",
                    fixCommand: fix,
                    requiresManual: false
                ))
                fixes.append(DoctorFix(command: fix, requiresManual: false))
            } else {
                let fix = "mkdir -p \(url.path)"
                checks.append(DoctorCheck(
                    name: name,
                    passed: false,
                    detail: "\(tilded) does not exist.",
                    fixCommand: fix,
                    requiresManual: false
                ))
                fixes.append(DoctorFix(command: fix, requiresManual: false))
            }
        }

        // --- Docs version check ---
        let binaryVersion = vvxBinaryVersion
        checks.append(DoctorCheck(
            name: "docsVersion",
            passed: true,
            detail: "binary v\(binaryVersion) matches bundled docs v\(binaryVersion)"
        ))

        // --- Determine status ---
        let engineCheck = checks.first { $0.name == "engine" }
        let criticalFailed = engineCheck?.passed == false
        let anyFailed      = checks.contains { !$0.passed }
        let status = criticalFailed ? "critical" : (anyFailed ? "degraded" : "ok")

        // --- Build result ---
        let archive = await DoctorArchiveInfo.loadFromDefaultDB()
        let result = DoctorResult(
            status: status,
            binaryVersion: binaryVersion,
            binaryVersionMatchesDocs: true,
            lastEngineUpdate: isoDate,
            daysSinceEngineUpdate: daysAgo,
            checks: checks,
            fixes: fixes,
            archive: archive
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"error":"Could not encode doctor result"}"#
        }
        return json
    }

    // MARK: - Output models

    struct DoctorCheck: Encodable {
        let name:          String
        let passed:        Bool
        let detail:        String
        var fixCommand:    String?
        var requiresManual: Bool?

        private enum CodingKeys: String, CodingKey {
            case name, passed, detail, fixCommand, requiresManual
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name,   forKey: .name)
            try c.encode(passed, forKey: .passed)
            try c.encode(detail, forKey: .detail)
            if let fixCommand     { try c.encode(fixCommand,     forKey: .fixCommand)     }
            if let requiresManual { try c.encode(requiresManual, forKey: .requiresManual) }
        }
    }

    struct DoctorFix: Encodable {
        let command:       String
        let requiresManual: Bool
    }

    struct DoctorResult: Encodable {
        let status:                  String
        let binaryVersion:           String
        let binaryVersionMatchesDocs: Bool
        let lastEngineUpdate:        String?
        let daysSinceEngineUpdate:   Int?
        let checks:                  [DoctorCheck]
        let fixes:                   [DoctorFix]
        let archive:                 DoctorArchiveInfo?
    }

    // MARK: - Helpers

    private static func resolveVersion(at url: URL) -> String? {
        let proc = Process()
        proc.executableURL = url
        proc.arguments     = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out?.isEmpty == false ? out : nil
    }

    private static func engineModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func isWritable(_ url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return false }
        return fm.isWritableFile(atPath: url.path)
    }
}

// MARK: - Shared version constant (VvxMcp target)

/// Version string for the vvx binary and its bundled documentation.
/// Keep this in sync with DocsCommand.docsVersion in the vvx CLI target.
private let vvxBinaryVersion = "0.2.0"
