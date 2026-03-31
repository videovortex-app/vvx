import ArgumentParser
import Foundation
import VideoVortexCore

// MARK: - DoctorCommand

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the vvx environment and get recommended fixes.",
        discussion: """
        Checks that all vvx dependencies are installed, directories are writable,
        and the binary version matches its bundled documentation. On any error
        from another command, run `vvx doctor` first — it identifies exactly what
        is broken and tells you how to fix it.

        AI agents should call this tool automatically whenever sense, fetch, or
        any other vvx command returns an error. The `fixes` array in --json output
        contains exact commands to run.

        Examples:
          vvx doctor                     # human-readable diagnostic report
          vvx doctor --json              # structured JSON for agent pipelines
          vvx doctor --auto-fix          # automatically apply safe fixes
          vvx doctor --full              # also run a live connectivity test
          vvx doctor --quiet             # show only failures
        """
    )

    /// Named `jsonOutput` to avoid ArgumentParser conflicts with the identifier `json`.
    @Flag(name: .customLong("json"), help: "Output structured JSON instead of a human-readable report.")
    var jsonOutput: Bool = false

    @Flag(name: .long, help: "Only print failed checks (suppress passing checks in human mode).")
    var quiet: Bool = false

    @Flag(
        name: .long,
        help: "Automatically apply safe, vvx-owned fixes (config rebuild, chmod on vvx dirs). Does NOT install system packages like yt-dlp — those require manual install."
    )
    var autoFix: Bool = false

    @Flag(
        name: .long,
        help: "Run a live connectivity test by sensing a public video. Takes up to 15 seconds."
    )
    var full: Bool = false

    // MARK: - Entry point

    mutating func run() async throws {
        var checks = await runChecks()

        var appliedFixes: [String] = []

        if autoFix {
            appliedFixes = await applyAutoFixes(checks: checks)
            if !appliedFixes.isEmpty {
                // Re-run checks after fixes to show updated state
                checks = await runChecks()
            }
        }

        let result = await buildResult(checks: checks)

        if jsonOutput {
            outputJSON(result)
        } else {
            outputHuman(result, checks: checks, appliedFixes: appliedFixes)
        }

        // Non-zero exit if critical (engine missing — nothing will work)
        if result.status == "critical" {
            throw ExitCode(1)
        }
    }

    // MARK: - Platform install / upgrade commands

    private var installCommand: String {
#if os(macOS)
        return "brew install yt-dlp"
#else
        return "pip install yt-dlp"
#endif
    }

    private var upgradeCommand: String {
#if os(macOS)
        return "brew upgrade yt-dlp"
#else
        return "pip install -U yt-dlp"
#endif
    }

    // MARK: - Check runner

    private func runChecks() async -> [DoctorCheck] {
        let resolver = EngineResolver.cliResolver
        let config   = VvxConfig.load()

        var checks = [DoctorCheck]()

        checks.append(checkEngine(resolver: resolver))
        checks.append(checkFfmpeg(resolver: resolver))
        checks.append(checkPlatform(resolver: resolver))
        checks.append(checkConfig())
        checks.append(contentsOf: checkDirectories(config: config))
        checks.append(checkDocsVersion())
        if let dbCheck = await checkVortexDB() {
            checks.append(dbCheck)
        }

        if full {
            checks.append(await checkConnectivity(resolver: resolver, config: config))
        }

        // Skills checks are advisory: they never affect the exit code.
        checks.append(contentsOf: checkSkills())

        return checks
    }

    // MARK: - Individual checks

    private func checkEngine(resolver: EngineResolver) -> DoctorCheck {
        guard let url = resolver.resolvedYtDlpURL() else {
            return DoctorCheck(
                name: "engine",
                passed: false,
                detail: "yt-dlp not found on PATH. Install it with your system package manager.",
                fixCommand: installCommand,
                requiresManual: true
            )
        }

        let version  = resolveVersion(at: url) ?? "unknown"
        let modDate  = engineModificationDate(at: url)
        let days     = modDate.map { Int(Date().timeIntervalSince($0) / 86400) }
        let daysStr  = days.map { " (updated \($0) day\($0 == 1 ? "" : "s") ago)" } ?? ""
        let tilded   = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        return DoctorCheck(
            name: "engine",
            passed: true,
            detail: "yt-dlp \(version) at \(tilded)\(daysStr)"
        )
    }

    private func checkFfmpeg(resolver: EngineResolver) -> DoctorCheck {
        guard let url = resolver.resolvedFfmpegURL() else {
#if os(macOS)
            let fixCommand = "brew install ffmpeg"
#else
            let fixCommand = "apt-get install -y ffmpeg"
#endif
            return DoctorCheck(
                name: "ffmpeg",
                passed: false,
                detail: "ffmpeg not found. The 'clip' command is unavailable; sponsor-block removal and some format conversions will also fail.",
                fixCommand: fixCommand,
                requiresManual: true
            )
        }
        let tilded = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return DoctorCheck(
            name: "ffmpeg",
            passed: true,
            detail: "ffmpeg at \(tilded)"
        )
    }

    private func checkPlatform(resolver: EngineResolver) -> DoctorCheck {
#if os(macOS)
        return DoctorCheck(
            name: "platform",
            passed: true,
            detail: "macOS — native AVFoundation thumbnails and keychain fingerprint active"
        )
#else
        let ffmpegFound = resolver.resolvedFfmpegURL() != nil
        if ffmpegFound {
            return DoctorCheck(
                name: "platform",
                passed: true,
                detail: "Linux — thumbnails via ffmpeg fallback, device fingerprint via ~/.vvx/.device-id"
            )
        } else {
            return DoctorCheck(
                name: "platform",
                passed: false,
                detail: "Linux — ffmpeg not found; thumbnails unavailable",
                fixCommand: "apt-get install -y ffmpeg",
                requiresManual: true
            )
        }
#endif
    }

    private func checkConfig() -> DoctorCheck {
        let url = VvxConfig.configFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            return DoctorCheck(
                name: "config",
                passed: false,
                detail: "~/.vvx/config.json is missing.",
                fixCommand: "vvx doctor --auto-fix",
                requiresManual: false
            )
        }
        guard let data = try? Data(contentsOf: url),
              (try? JSONDecoder().decode(VvxConfig.self, from: data)) != nil
        else {
            return DoctorCheck(
                name: "config",
                passed: false,
                detail: "~/.vvx/config.json exists but is corrupt.",
                fixCommand: "rm ~/.vvx/config.json && vvx doctor --auto-fix",
                requiresManual: false
            )
        }
        let tilded = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return DoctorCheck(
            name: "config",
            passed: true,
            detail: "\(tilded) is valid"
        )
    }

    private func checkDirectories(config: VvxConfig) -> [DoctorCheck] {
        let dirs: [(String, URL)] = [
            ("transcriptsDir", config.resolvedTranscriptDirectory()),
            ("downloadsDir",   config.resolvedDownloadDirectory()),
            ("archiveDir",     config.resolvedArchiveDirectory()),
        ]

        return dirs.map { (name, url) in
            let tilded = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            if isWritable(url) {
                return DoctorCheck(
                    name: name,
                    passed: true,
                    detail: "\(tilded) is writable"
                )
            } else if FileManager.default.fileExists(atPath: url.path) {
                return DoctorCheck(
                    name: name,
                    passed: false,
                    detail: "\(tilded) exists but is not writable (permission denied).",
                    fixCommand: "chmod 755 \(url.path)",
                    requiresManual: false
                )
            } else {
                return DoctorCheck(
                    name: name,
                    passed: false,
                    detail: "\(tilded) does not exist.",
                    fixCommand: "mkdir -p \(url.path)",
                    requiresManual: false
                )
            }
        }
    }

    /// Opens `~/.vvx/vortex.db` (if it exists) and runs integrity + engagement-column checks.
    /// Returns `nil` when the database file is absent so the check is omitted from output.
    private func checkVortexDB() async -> DoctorCheck? {
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/vortex.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        let tilded = dbURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        guard let db = try? VortexDB(path: dbURL) else {
            return DoctorCheck(
                name: "vortexDB",
                passed: false,
                detail: "\(tilded) exists but could not be opened.",
                fixCommand: "rm ~/.vvx/vortex.db && vvx reindex",
                requiresManual: false
            )
        }

        let ok      = (try? await db.integrity()) ?? false
        let hasEngg = (try? await db.hasEngagementColumns()) ?? false

        if !ok {
            return DoctorCheck(
                name: "vortexDB",
                passed: false,
                detail: "\(tilded): integrity check failed — database is corrupt.",
                fixCommand: "rm ~/.vvx/vortex.db && vvx reindex",
                requiresManual: false
            )
        }

        let count   = (try? await db.videoCount()) ?? 0
        let engSuffix = hasEngg ? "" : " (engagement columns missing — run: vvx reindex)"
        return DoctorCheck(
            name: "vortexDB",
            passed: hasEngg,
            detail: "\(tilded): ok, \(count) video\(count == 1 ? "" : "s") indexed\(engSuffix)",
            fixCommand: hasEngg ? nil : "vvx reindex",
            requiresManual: false
        )
    }

    // MARK: - Skills checks (advisory only)

    private func checkSkills() -> [DoctorCheck] {
        [checkSkillsCatalog(), checkSkillsDirectory(), checkSkillsInstalled()]
    }

    private func checkSkillsCatalog() -> DoctorCheck {
        let cacheURL = SkillsManager.catalogCacheURL
        let fm       = FileManager.default

        guard fm.fileExists(atPath: cacheURL.path) else {
            return DoctorCheck(
                name: "skillsCatalog",
                passed: false,
                detail: "No catalog cached. Run 'vvx skills update'.",
                fixCommand: "vvx skills update",
                requiresManual: true
            )
        }

        guard let data    = try? Data(contentsOf: cacheURL),
              let catalog = try? JSONDecoder().decode(SkillsCatalog.self, from: data)
        else {
            return DoctorCheck(
                name: "skillsCatalog",
                passed: false,
                detail: "Catalog is corrupt. Run 'vvx skills update'.",
                fixCommand: "vvx skills update",
                requiresManual: true
            )
        }

        guard let mod = SkillsManager.catalogModDate() else {
            return DoctorCheck(name: "skillsCatalog", passed: true,
                               detail: "\(catalog.totalSkills) skills cached")
        }

        let age = Date().timeIntervalSince(mod)
        if age > SkillsManager.maxCacheAge {
            let days = Int(age / 86400)
            return DoctorCheck(
                name: "skillsCatalog",
                passed: false,
                detail: "Stale (\(days) day\(days == 1 ? "" : "s")). Run 'vvx skills update'.",
                fixCommand: "vvx skills update",
                requiresManual: true
            )
        }

        let ageStr = SkillsManager.formattedAge(mod)
        return DoctorCheck(
            name: "skillsCatalog",
            passed: true,
            detail: "\(catalog.totalSkills) skill\(catalog.totalSkills == 1 ? "" : "s") cached (updated \(ageStr))"
        )
    }

    private func checkSkillsDirectory() -> DoctorCheck {
        let vvxDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vvx")
        let tilded = "~/.vvx/"
        let fm     = FileManager.default

        guard fm.fileExists(atPath: vvxDir.path) else {
            return DoctorCheck(
                name: "skillsDir",
                passed: false,
                detail: "\(tilded) not found — will be created on first install."
            )
        }

        guard fm.isWritableFile(atPath: vvxDir.path) else {
            return DoctorCheck(
                name: "skillsDir",
                passed: false,
                detail: "\(tilded) exists but is not writable.",
                fixCommand: "chmod 755 \(vvxDir.path)",
                requiresManual: true
            )
        }

        return DoctorCheck(name: "skillsDir", passed: true, detail: "\(tilded) is writable")
    }

    private func checkSkillsInstalled() -> DoctorCheck {
        let manifest = SkillsManager.loadManifest()
        let count    = manifest.installed.count

        guard count > 0 else {
            return DoctorCheck(name: "skillsInstalled", passed: true, detail: "No skills installed.")
        }

        let missing = manifest.installed.filter {
            !FileManager.default.fileExists(atPath: $0.path)
        }

        if missing.isEmpty {
            return DoctorCheck(
                name: "skillsInstalled",
                passed: true,
                detail: "\(count) installed, all files present"
            )
        }

        let first  = missing[0]
        let tilded = first.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let extra  = missing.count > 1 ? " (and \(missing.count - 1) more)" : ""
        return DoctorCheck(
            name: "skillsInstalled",
            passed: false,
            detail: "\(first.slug) file not found at \(tilded)\(extra)"
        )
    }

    private func checkDocsVersion() -> DoctorCheck {
        let v = vvxDocsVersion
        return DoctorCheck(
            name: "docsVersion",
            passed: true,
            detail: "binary v\(v) matches bundled docs v\(v)"
        )
    }

    private func checkConnectivity(resolver: EngineResolver, config: VvxConfig) async -> DoctorCheck {
        guard let ytDlpURL = resolver.resolvedYtDlpURL() else {
            return DoctorCheck(
                name: "connectivity",
                passed: false,
                detail: "Skipped — yt-dlp not installed."
            )
        }

        let testURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        let outDir  = config.resolvedTranscriptDirectory()
        let senseConfig = SenseConfig(
            url: testURL,
            outputDirectory: outDir,
            ytDlpPath: ytDlpURL
        )

        let start  = Date()
        var passed = false

        // Race: sense vs 15-second timeout
        let senseTask = Task {
            let senser = VideoSenser()
            for await event in senser.sense(config: senseConfig) {
                switch event {
                case .completed: return true
                case .failed:    return false
                default: continue
                }
            }
            return false
        }

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            senseTask.cancel()
        }

        passed = await senseTask.value
        timeoutTask.cancel()

        let elapsed = Date().timeIntervalSince(start)

        if passed {
            return DoctorCheck(
                name: "connectivity",
                passed: true,
                detail: String(format: "Public video sensed in %.1fs", elapsed)
            )
        } else {
            return DoctorCheck(
                name: "connectivity",
                passed: false,
                detail: "Connectivity test failed. Network or extractor issue.",
                fixCommand: upgradeCommand,
                requiresManual: true
            )
        }
    }

    // MARK: - Auto-fix

    private func applyAutoFixes(checks: [DoctorCheck]) async -> [String] {
        var applied: [String] = []

        for check in checks where !check.passed && check.requiresManual == false {
            guard let fix = check.fixCommand else { continue }

            switch check.name {

            case "engine":
                fputs("  [manual action required] yt-dlp is not installed.\n", stderr)
                fputs("  Install it with:\n", stderr)
                fputs("    macOS (Homebrew):  brew install yt-dlp\n", stderr)
                fputs("    All platforms:     pip install yt-dlp\n", stderr)
                fputs("    https://github.com/yt-dlp/yt-dlp#installation\n", stderr)

            case "config":
                fputs("  [auto-fix] Recreating config...\n", stderr)
                VvxConfig().save()
                fputs("  ✓ Config recreated at ~/.vvx/config.json\n", stderr)
                applied.append(fix)

            case "transcriptsDir", "downloadsDir", "archiveDir":
                let config = VvxConfig.load()
                let url: URL
                switch check.name {
                case "transcriptsDir": url = config.resolvedTranscriptDirectory()
                case "downloadsDir":   url = config.resolvedDownloadDirectory()
                default:               url = config.resolvedArchiveDirectory()
                }
                fputs("  [auto-fix] Fixing permissions on \(url.lastPathComponent)...\n", stderr)
                do {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    }
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                    fputs("  ✓ Fixed: \(url.path)\n", stderr)
                    applied.append(fix)
                } catch {
                    fputs("  ✗ Could not fix \(url.path): \(error.localizedDescription)\n", stderr)
                }

            case "connectivity":
                fputs("  [manual action required] yt-dlp may be outdated.\n", stderr)
                fputs("  Update it with:\n", stderr)
                fputs("    macOS (Homebrew):  brew upgrade yt-dlp\n", stderr)
                fputs("    All platforms:     pip install -U yt-dlp\n", stderr)

            default:
                break
            }
        }

        return applied
    }

    // MARK: - Result builder

    private func buildResult(checks: [DoctorCheck]) async -> DoctorResult {
        let engineFailed = checks.first { $0.name == "engine" }?.passed == false
        let anyFailed    = checks.contains { !$0.passed }

        let status: String
        if engineFailed { status = "critical" }
        else if anyFailed { status = "degraded" }
        else { status = "ok" }

        let resolver   = EngineResolver.cliResolver
        let engineURL  = resolver.resolvedYtDlpURL()
        let modDate    = engineURL.flatMap { engineModificationDate(at: $0) }
        let daysAgo    = modDate.map { Int(Date().timeIntervalSince($0) / 86400) }
        let isoDate    = modDate.map { ISO8601DateFormatter().string(from: $0) }

        let fixes = checks.compactMap { check -> DoctorFix? in
            guard !check.passed, let cmd = check.fixCommand, let manual = check.requiresManual else {
                return nil
            }
            return DoctorFix(command: cmd, requiresManual: manual)
        }

        let archive = await DoctorArchiveInfo.loadFromDefaultDB()

        return DoctorResult(
            status: status,
            binaryVersion: vvxDocsVersion,
            binaryVersionMatchesDocs: true,
            lastEngineUpdate: isoDate,
            daysSinceEngineUpdate: daysAgo,
            checks: checks,
            fixes: fixes,
            archive: archive
        )
    }

    // MARK: - Output

    private func outputJSON(_ result: DoctorResult) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result),
              let str  = String(data: data, encoding: .utf8)
        else { print("{}"); return }
        print(str)
    }

    private func outputHuman(_ result: DoctorResult, checks: [DoctorCheck], appliedFixes: [String]) {
        let divider = String(repeating: "─", count: 47)
        fputs("\(divider)\n", stdout)

        for check in checks {
            guard !quiet || !check.passed else { continue }
            let icon   = check.passed ? "✓" : "✗"
            let label  = checkLabel(check.name).padding(toLength: 18, withPad: " ", startingAt: 0)
            let status = check.passed ? check.detail : "\(check.detail)"
            fputs("\(icon)  \(label)  \(status)\n", stdout)
        }

        fputs("\n", stdout)

        if !appliedFixes.isEmpty {
            fputs("Applied \(appliedFixes.count) auto-fix(es):\n", stdout)
            for fix in appliedFixes {
                fputs("  ✓ \(fix)\n", stdout)
            }
            fputs("\n", stdout)
        }

        let manualFixes = result.fixes.filter { $0.requiresManual }
        let autoFixes   = result.fixes.filter { !$0.requiresManual }

        if result.status == "ok" && appliedFixes.isEmpty {
            fputs("All checks passed. vvx is ready.\n", stdout)
        } else if !result.fixes.isEmpty {
            let issueCount = result.fixes.count
            fputs("\(issueCount) issue\(issueCount == 1 ? "" : "s") found.\n", stdout)

            if !autoFixes.isEmpty && !autoFix {
                fputs("\nAuto-fixable (run: vvx doctor --auto-fix):\n", stdout)
                for (i, fix) in autoFixes.enumerated() {
                    fputs("  [\(i + 1)] \(fix.command)\n", stdout)
                }
            }
            if !manualFixes.isEmpty {
                fputs("\nRequires manual action:\n", stdout)
                for (i, fix) in manualFixes.enumerated() {
                    fputs("  [\(i + 1)] \(fix.command)\n", stdout)
                }
            }
        }

        fputs("\(divider)\n", stdout)
    }

    // MARK: - Helpers

    private func checkLabel(_ name: String) -> String {
        switch name {
        case "engine":         return "Engine (yt-dlp)"
        case "ffmpeg":         return "ffmpeg"
        case "platform":       return "Platform"
        case "config":         return "Config"
        case "transcriptsDir": return "Transcripts dir"
        case "downloadsDir":   return "Downloads dir"
        case "archiveDir":     return "Archive dir"
        case "docsVersion":      return "Docs version"
        case "connectivity":     return "Connectivity"
        case "vortexDB":         return "Archive DB"
        case "skillsCatalog":    return "Skills catalog"
        case "skillsDir":        return "Skills dir"
        case "skillsInstalled":  return "Skills installed"
        default:                 return name
        }
    }

    private func resolveVersion(at url: URL) -> String? {
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

    private func engineModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func isWritable(_ url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return false }
        return fm.isWritableFile(atPath: url.path)
    }
}

// MARK: - Output structs

struct DoctorCheck: Encodable {
    let name:          String
    let passed:        Bool
    let detail:        String
    var fixCommand:    String?
    var requiresManual: Bool?

    // Omit nil optional keys from JSON output
    private enum CodingKeys: String, CodingKey {
        case name, passed, detail, fixCommand, requiresManual
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,   forKey: .name)
        try c.encode(passed, forKey: .passed)
        try c.encode(detail, forKey: .detail)
        if let fixCommand    { try c.encode(fixCommand,    forKey: .fixCommand)    }
        if let requiresManual { try c.encode(requiresManual, forKey: .requiresManual) }
    }
}

struct DoctorFix: Encodable {
    let command:       String
    let requiresManual: Bool
}

struct DoctorResult: Encodable {
    let status:                  String   // "ok" | "degraded" | "critical"
    let binaryVersion:           String
    let binaryVersionMatchesDocs: Bool
    let lastEngineUpdate:        String?
    let daysSinceEngineUpdate:   Int?
    let checks:                  [DoctorCheck]
    let fixes:                   [DoctorFix]
    /// Present when `~/.vvx/vortex.db` exists; otherwise omitted from JSON.
    let archive:                 DoctorArchiveInfo?
}

// MARK: - stdout/stderr convenience

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
