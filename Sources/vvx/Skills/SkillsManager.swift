import Foundation

// MARK: - Catalog model

struct SkillsCatalog: Codable {
    let schemaVersion:  String
    let totalSkills:    Int
    let totalWorkflows: Int
    let skills:         [SkillEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion  = "schema_version"
        case totalSkills    = "total_skills"
        case totalWorkflows = "total_workflows"
        case skills
    }
}

struct SkillEntry: Codable {
    let slug:        String
    let title:       String
    let description: String
    let category:    String
    let keywords:    [String]
    let version:     String
    let frameworks:  [String]
    let files:       [String: String]
}

// MARK: - Installed manifest

struct InstalledManifest: Codable {
    var installed: [InstalledSkill]
}

struct InstalledSkill: Codable {
    let slug:       String
    let version:    String
    let framework:  String
    let path:       String
    let sourceURL:  String
    var installedOn: String
    var updatedOn:   String

    enum CodingKeys: String, CodingKey {
        case slug, version, framework, path
        case sourceURL   = "source_url"
        case installedOn = "installed_on"
        case updatedOn   = "updated_on"
    }
}

// MARK: - Framework detection

struct FrameworkMatch {
    let framework:   String
    let projectRoot: URL
    let signal:      String
}

// MARK: - SkillsManager

struct SkillsManager {

    // MARK: Paths

    static let catalogRemoteURL = URL(
        string: "https://raw.githubusercontent.com/videovortex-app/vvx-skills/main/skills-catalog.json"
    )!

    static var catalogCacheURL: URL {
        homeDir.appendingPathComponent(".vvx/skills-catalog.json")
    }

    static var manifestURL: URL {
        homeDir.appendingPathComponent(".vvx/installed-skills.json")
    }

    private static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static let maxCacheAge: TimeInterval = 24 * 3600

    // MARK: Catalog loading

    /// Loads the catalog from cache, auto-refreshing if stale or missing.
    static func loadCatalog() async throws -> SkillsCatalog {
        let fm = FileManager.default

        if fm.fileExists(atPath: catalogCacheURL.path),
           let data    = try? Data(contentsOf: catalogCacheURL),
           let catalog = try? JSONDecoder().decode(SkillsCatalog.self, from: data) {

            let attrs = try? fm.attributesOfItem(atPath: catalogCacheURL.path)
            let mod   = (attrs?[.modificationDate] as? Date) ?? .distantPast

            if Date().timeIntervalSince(mod) < maxCacheAge {
                return catalog
            }

            fputs("Updating skills catalog...\n", stderr)
            do {
                return try await fetchAndSave()
            } catch {
                fputs(
                    "Using cached catalog (last updated \(formattedAge(mod))). " +
                    "Run 'vvx skills update' when online.\n",
                    stderr
                )
                return catalog
            }

        } else if fm.fileExists(atPath: catalogCacheURL.path) {
            // File exists but is corrupt — attempt re-fetch.
            fputs("Fetching skills catalog...\n", stderr)
            do {
                return try await fetchAndSave()
            } catch {
                throw SkillsError.corruptCatalog
            }

        } else {
            fputs("Fetching skills catalog...\n", stderr)
            do {
                return try await fetchAndSave()
            } catch {
                throw SkillsError.noNetwork
            }
        }
    }

    /// Fetches the catalog from GitHub and writes it to the local cache.
    static func fetchAndSave() async throws -> SkillsCatalog {
        let (data, _) = try await URLSession.shared.data(from: catalogRemoteURL)
        let catalog   = try JSONDecoder().decode(SkillsCatalog.self, from: data)
        let dir       = catalogCacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: catalogCacheURL, options: .atomic)
        return catalog
    }

    // MARK: Framework detection

    /// Walks from `cwd` up toward $HOME (exclusive), returning the first framework signal found.
    static func detectFramework(from cwd: URL) -> FrameworkMatch? {
        let home = homeDir.standardized
        var dir  = cwd.standardized
        let fm   = FileManager.default

        while dir.path != home.path {
            if let m = checkAt(dir, fm: fm) { return m }
            let parent = dir.deletingLastPathComponent().standardized
            if parent.path == dir.path { break }   // filesystem root
            dir = parent
        }
        return nil
    }

    private static func checkAt(_ dir: URL, fm: FileManager) -> FrameworkMatch? {
        var isDir: ObjCBool = false

        // Priority 1: Cursor
        let cursorDir = dir.appendingPathComponent(".cursor")
        if fm.fileExists(atPath: cursorDir.path, isDirectory: &isDir), isDir.boolValue {
            return FrameworkMatch(framework: "cursor", projectRoot: dir, signal: ".cursor/ found")
        }

        // Priority 2: Claude Code
        let claudeDir = dir.appendingPathComponent(".claude")
        if fm.fileExists(atPath: claudeDir.path, isDirectory: &isDir), isDir.boolValue {
            return FrameworkMatch(framework: "claude-code", projectRoot: dir, signal: ".claude/ found")
        }
        let claudeMD = dir.appendingPathComponent("CLAUDE.md")
        if fm.fileExists(atPath: claudeMD.path) {
            return FrameworkMatch(framework: "claude-code", projectRoot: dir, signal: "CLAUDE.md found")
        }

        // Priority 3: Aider
        for name in [".aider.conf.yml", "aider.conf.yml"] {
            let f = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: f.path) {
                return FrameworkMatch(framework: "aider", projectRoot: dir, signal: "\(name) found")
            }
        }

        return nil
    }

    // MARK: Install paths

    static func installDirectory(framework: String, projectRoot: URL) -> URL {
        switch framework {
        case "cursor":      return projectRoot.appendingPathComponent(".cursor/skills")
        case "claude-code": return projectRoot.appendingPathComponent(".claude/skills")
        case "aider":       return projectRoot.appendingPathComponent(".aider/skills")
        default:            return homeDir.appendingPathComponent(".vvx/skills")
        }
    }

    /// Returns the parent directory that must already exist before installing (nil = no requirement).
    static func requiredParentDir(framework: String, projectRoot: URL) -> URL? {
        switch framework {
        case "cursor":      return projectRoot.appendingPathComponent(".cursor")
        case "claude-code": return projectRoot.appendingPathComponent(".claude")
        default:            return nil
        }
    }

    // MARK: Manifest I/O

    static func loadManifest() -> InstalledManifest {
        guard let data     = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(InstalledManifest.self, from: data)
        else { return InstalledManifest(installed: []) }
        return manifest
    }

    static func saveManifest(_ manifest: InstalledManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: manifestURL, options: .atomic)
    }

    // MARK: Cache metadata

    static func catalogModDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: catalogCacheURL.path))?[.modificationDate] as? Date
    }

    static func formattedAge(_ date: Date) -> String {
        let hours = Int(Date().timeIntervalSince(date) / 3600)
        if hours < 1  { return "less than an hour ago" }
        if hours == 1 { return "1 hour ago" }
        if hours < 24 { return "\(hours) hours ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}

// MARK: - Errors

enum SkillsError: Error, CustomStringConvertible {
    case noNetwork
    case corruptCatalog
    case slugNotFound(String)
    case noFileForFramework(String, String)
    case frameworkParentMissing(String)
    case invalidFramework(String)

    var description: String {
        switch self {
        case .noNetwork:
            return "Error: No skills catalog found and unable to reach GitHub. Run 'vvx skills update' when online."
        case .corruptCatalog:
            return "Error: Skills catalog is corrupt. Run 'vvx skills update'."
        case .slugNotFound(let s):
            return "Error: '\(s)' not found in catalog. Run 'vvx skills list' to see available skills."
        case .noFileForFramework(let s, let fw):
            return "Error: '\(s)' has no file for framework '\(fw)'. Run 'vvx skills info \(s)' to see available frameworks."
        case .frameworkParentMissing(let fw):
            let dir = frameworkDirName(fw)
            return "Error: \(dir) directory not found. Are you in a \(frameworkDisplayName(fw)) project?"
        case .invalidFramework(let fw):
            return "Error: Unknown framework '\(fw)'. Valid values: cursor, claude-code, aider."
        }
    }

    private func frameworkDirName(_ fw: String) -> String {
        switch fw {
        case "cursor":      return ".cursor/"
        case "claude-code": return ".claude/"
        default:            return ".\(fw)/"
        }
    }
}

// MARK: - Module-level helpers

func frameworkDisplayName(_ framework: String) -> String {
    switch framework {
    case "cursor":      return "Cursor"
    case "claude-code": return "Claude Code"
    case "aider":       return "Aider"
    default:            return framework
    }
}

// MARK: - stderr convenience

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
