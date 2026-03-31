import ArgumentParser
import Foundation

// MARK: - SkillsCommand

struct SkillsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skills",
        abstract: "Browse, install, and manage AI workflow skills.",
        discussion: """
        Skills are workflow .md files fetched from the vvx-skills repository
        and installed into your AI framework project.

        Examples:
          vvx skills update                        # refresh the skills catalog
          vvx skills list                          # show all available skills
          vvx skills list --category competitive-intel
          vvx skills search "competitor"           # search by keyword
          vvx skills info competitor-x-ray         # skill details
          vvx skills install competitor-x-ray      # install (auto-detects framework)
          vvx skills install competitor-x-ray --framework cursor
          vvx skills installed                     # list installed skills
          vvx skills update competitor-x-ray       # re-fetch an installed skill
        """,
        subcommands: [
            Update.self,
            List.self,
            Search.self,
            Info.self,
            Install.self,
            Installed.self,
        ]
    )

    // MARK: - vvx skills update [slug]

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Refresh the skills catalog, or re-fetch an installed skill by slug."
        )

        @Argument(help: "Slug of an installed skill to re-fetch. Omit to refresh the catalog.")
        var slug: String?

        mutating func run() async throws {
            if let slug { try await rereFetchSkill(slug) }
            else        { try await refreshCatalog()      }
        }

        private func refreshCatalog() async throws {
            do {
                let c = try await SkillsManager.fetchAndSave()
                print(
                    "Fetched \(c.totalSkills) skill\(c.totalSkills == 1 ? "" : "s") " +
                    "(\(c.totalWorkflows) framework variant\(c.totalWorkflows == 1 ? "" : "s")) " +
                    "from vvx-skills v\(c.schemaVersion)"
                )
            } catch {
                fputs("\(SkillsError.noNetwork.description)\n", stderr)
                throw ExitCode.failure
            }
        }

        private func rereFetchSkill(_ slug: String) async throws {
            var manifest = SkillsManager.loadManifest()
            guard let idx = manifest.installed.firstIndex(where: { $0.slug == slug }) else {
                fputs("Error: '\(slug)' is not installed. Run 'vvx skills install \(slug)' first.\n", stderr)
                throw ExitCode.failure
            }

            let entry = manifest.installed[idx]
            guard let sourceURL = URL(string: entry.sourceURL) else {
                fputs("Error: recorded source URL for '\(slug)' is invalid.\n", stderr)
                throw ExitCode.failure
            }

            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(from: sourceURL)
            } catch {
                fputs("Error: unable to reach GitHub. Check connectivity and retry.\n", stderr)
                throw ExitCode.failure
            }

            guard let newContent = String(data: data, encoding: .utf8) else {
                fputs("Error: downloaded content for '\(slug)' is not valid UTF-8.\n", stderr)
                throw ExitCode.failure
            }

            let destURL = URL(fileURLWithPath: entry.path)
            if let existing = try? String(contentsOf: destURL, encoding: .utf8), existing == newContent {
                print("\(slug) is already up to date.")
                return
            }

            try newContent.write(to: destURL, atomically: true, encoding: .utf8)
            let now = ISO8601DateFormatter().string(from: Date())
            manifest.installed[idx].updatedOn = now
            try SkillsManager.saveManifest(manifest)

            let tilded = destURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            print("Updated \(slug) at \(tilded)")
        }
    }

    // MARK: - vvx skills list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all available skills from the local catalog."
        )

        @Option(name: .long, help: "Filter by category slug.")
        var category: String?

        @Flag(name: .customLong("json"), help: "Output raw JSON.")
        var jsonOutput: Bool = false

        mutating func run() async throws {
            let catalog = try await skillsLoadCatalog()
            let skills  = category.map { c in catalog.skills.filter { $0.category == c } } ?? catalog.skills
            if jsonOutput { skillsPrintJSON(skills) } else { skillsPrintTable(skills) }
        }
    }

    // MARK: - vvx skills search

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search skills by title, description, or keywords."
        )

        @Argument(help: "Search query (case-insensitive).")
        var query: String

        @Flag(name: .customLong("json"), help: "Output raw JSON.")
        var jsonOutput: Bool = false

        mutating func run() async throws {
            let catalog = try await skillsLoadCatalog()
            let q       = query.lowercased()

            let ranked = catalog.skills
                .compactMap { skill -> (SkillEntry, Int)? in
                    var score = 0
                    if skill.title.lowercased().contains(q)                                { score += 3 }
                    if skill.description.lowercased().contains(q)                          { score += 2 }
                    if skill.keywords.contains(where: { $0.lowercased().contains(q) })    { score += 1 }
                    return score > 0 ? (skill, score) : nil
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }

            if ranked.isEmpty { print("No skills match '\(query)'."); return }
            if jsonOutput { skillsPrintJSON(ranked) } else { skillsPrintTable(ranked) }
        }
    }

    // MARK: - vvx skills info

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show full metadata for a skill."
        )

        @Argument(help: "Skill slug.")
        var slug: String

        mutating func run() async throws {
            let catalog = try await skillsLoadCatalog()
            guard let skill = catalog.skills.first(where: { $0.slug == slug }) else {
                fputs("\(SkillsError.slugNotFound(slug).description)\n", stderr)
                throw ExitCode.failure
            }

            print("Slug:        \(skill.slug)")
            print("Title:       \(skill.title)")
            print("Version:     \(skill.version)")
            print("Category:    \(skill.category)")
            print("Frameworks:  \(skill.frameworks.joined(separator: ", "))")
            print("Keywords:    \(skill.keywords.joined(separator: ", "))")
            print("Description: \(skill.description)")
            print("Files:")
            for (fw, url) in skill.files.sorted(by: { $0.key < $1.key }) {
                print("  \(fw): \(url)")
            }
        }
    }

    // MARK: - vvx skills install

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Download and install a skill into the detected AI framework."
        )

        @Argument(help: "Skill slug to install.")
        var slug: String

        @Option(name: .long, help: "Target framework: cursor, claude-code, aider.")
        var framework: String?

        mutating func run() async throws {
            if let fw = framework, !["cursor", "claude-code", "aider"].contains(fw) {
                fputs("\(SkillsError.invalidFramework(fw).description)\n", stderr)
                throw ExitCode.failure
            }

            let catalog = try await skillsLoadCatalog()
            guard let skill = catalog.skills.first(where: { $0.slug == slug }) else {
                fputs("\(SkillsError.slugNotFound(slug).description)\n", stderr)
                throw ExitCode.failure
            }

            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let (resolvedFW, projectRoot, note) = try resolveFramework(override: framework, cwd: cwd)

            // Validate the framework's parent directory exists before attempting install.
            if let parent = SkillsManager.requiredParentDir(framework: resolvedFW, projectRoot: projectRoot) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    fputs("\(SkillsError.frameworkParentMissing(resolvedFW).description)\n", stderr)
                    throw ExitCode.failure
                }
            }

            guard let sourceURLStr = skill.files[resolvedFW] ?? skill.files["generic"] else {
                fputs("\(SkillsError.noFileForFramework(slug, resolvedFW).description)\n", stderr)
                throw ExitCode.failure
            }
            guard let sourceURL = URL(string: sourceURLStr) else {
                fputs("Error: invalid source URL in catalog for '\(slug)'.\n", stderr)
                throw ExitCode.failure
            }

            if !note.isEmpty { print(note) }

            let installDir = SkillsManager.installDirectory(framework: resolvedFW, projectRoot: projectRoot)
            let destURL    = installDir.appendingPathComponent("\(slug).md")

            if !FileManager.default.fileExists(atPath: installDir.path) {
                try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
            }

            print("Installing \(slug) for \(frameworkDisplayName(resolvedFW))...")

            let data: Data
            do {
                (data, _) = try await URLSession.shared.data(from: sourceURL)
            } catch {
                fputs("Error: unable to reach GitHub. Check connectivity and retry.\n", stderr)
                throw ExitCode.failure
            }

            guard let content = String(data: data, encoding: .utf8) else {
                fputs("Error: downloaded content is not valid UTF-8.\n", stderr)
                throw ExitCode.failure
            }

            if let existing = try? String(contentsOf: destURL, encoding: .utf8), existing == content {
                print("\(slug) is already installed and up to date.")
                return
            }

            try content.write(to: destURL, atomically: true, encoding: .utf8)
            let tilded = destURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            print("Installed to \(tilded)")

            // Upsert the manifest entry.
            var manifest = SkillsManager.loadManifest()
            let now      = ISO8601DateFormatter().string(from: Date())
            let existIdx = manifest.installed.firstIndex { $0.slug == slug && $0.framework == resolvedFW }
            let entry    = InstalledSkill(
                slug:        slug,
                version:     skill.version,
                framework:   resolvedFW,
                path:        destURL.path,
                sourceURL:   sourceURLStr,
                installedOn: existIdx.map { manifest.installed[$0].installedOn } ?? now,
                updatedOn:   now
            )
            if let i = existIdx { manifest.installed[i] = entry }
            else                { manifest.installed.append(entry) }
            try SkillsManager.saveManifest(manifest)
        }

        private func resolveFramework(
            override: String?,
            cwd: URL
        ) throws -> (fw: String, root: URL, note: String) {
            if let fw = override {
                return (fw, cwd, "Using: \(frameworkDisplayName(fw)) (--framework)")
            }

            if let match = SkillsManager.detectFramework(from: cwd) {
                let note = "Detected: \(frameworkDisplayName(match.framework)) (\(match.signal))"
                return (match.framework, match.projectRoot, note)
            }

            // No framework found — prompt interactively or fall back to generic.
            if isatty(STDIN_FILENO) != 0 {
                print("No AI framework detected in the current directory tree.")
                print("Select framework:")
                print("  [1] cursor")
                print("  [2] claude-code")
                print("  [3] aider")
                print("  [4] generic")
                print("Choice [1-4]: ", terminator: "")
                let choice = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                let fw: String
                switch choice {
                case "1": fw = "cursor"
                case "2": fw = "claude-code"
                case "3": fw = "aider"
                case "4": fw = "generic"
                default:
                    fputs("Invalid choice. Valid options: 1, 2, 3, 4.\n", stderr)
                    throw ExitCode.failure
                }
                return (fw, cwd, "Using: \(frameworkDisplayName(fw)) (manual selection)")
            } else {
                fputs("No framework detected. Installing to ~/.vvx/skills/\n", stderr)
                return ("generic", FileManager.default.homeDirectoryForCurrentUser, "")
            }
        }
    }

    // MARK: - vvx skills installed

    struct Installed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "installed",
            abstract: "List all installed skills."
        )

        mutating func run() async throws {
            let manifest = SkillsManager.loadManifest()
            guard !manifest.installed.isEmpty else {
                print("No skills installed.")
                return
            }

            let entries = manifest.installed
            let slugW   = max(entries.map { $0.slug.count      }.max()!, 4)
            let fwW     = max(entries.map { $0.framework.count }.max()!, 9)
            let verW    = max(entries.map { $0.version.count   }.max()!, 7)

            let header = skillsCol("SLUG", slugW) + "  " +
                         skillsCol("FRAMEWORK", fwW) + "  " +
                         skillsCol("VERSION", verW) + "  PATH"
            print(header)
            print(String(repeating: "─", count: min(header.count + 20, 120)))

            for s in entries {
                let tilded = s.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                print(
                    skillsCol(s.slug, slugW) + "  " +
                    skillsCol(s.framework, fwW) + "  " +
                    skillsCol(s.version, verW) + "  " +
                    tilded
                )
            }
        }
    }
}

// MARK: - File-private helpers

private func skillsLoadCatalog() async throws -> SkillsCatalog {
    do {
        return try await SkillsManager.loadCatalog()
    } catch let err as SkillsError {
        fputs("\(err.description)\n", stderr)
        throw ExitCode.failure
    } catch {
        fputs("Error loading catalog: \(error.localizedDescription)\n", stderr)
        throw ExitCode.failure
    }
}

private func skillsPrintTable(_ skills: [SkillEntry]) {
    guard !skills.isEmpty else { print("No skills found."); return }
    let slugW = max(skills.map { $0.slug.count }.max()!, 4)
    let catW  = max(skills.map { $0.category.count }.max()!, 8)
    let fwW   = max(skills.map { $0.frameworks.joined(separator: ",").count }.max()!, 10)

    let header = skillsCol("SLUG", slugW) + "  " +
                 skillsCol("CATEGORY", catW) + "  " +
                 skillsCol("FRAMEWORKS", fwW) + "  DESCRIPTION"
    print(header)
    print(String(repeating: "─", count: min(header.count, 120)))

    for skill in skills {
        let fw   = skill.frameworks.joined(separator: ",")
        let desc = skill.description.count > 55
            ? String(skill.description.prefix(52)) + "..."
            : skill.description
        print(
            skillsCol(skill.slug, slugW) + "  " +
            skillsCol(skill.category, catW) + "  " +
            skillsCol(fw, fwW) + "  " +
            desc
        )
    }
}

private func skillsPrintJSON(_ skills: [SkillEntry]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    if let data = try? encoder.encode(skills), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

private func skillsCol(_ s: String, _ width: Int) -> String {
    s.padding(toLength: max(s.count, width), withPad: " ", startingAt: 0)
}

private func fputs(_ string: String, _ stream: UnsafeMutablePointer<FILE>) {
    Foundation.fputs(string, stream)
}
