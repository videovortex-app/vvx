import ArgumentParser
import Foundation
import VideoVortexCore

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Check or get help installing yt-dlp (the video extraction dependency).",
        subcommands: [Install.self, Update.self, Status.self]
    )

    // MARK: - vvx engine install

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Show instructions for installing yt-dlp on your system."
        )

        mutating func run() async throws {
            printInstallGuide()
        }
    }

    // MARK: - vvx engine update

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Show instructions for updating yt-dlp to the latest version."
        )

        mutating func run() async throws {
            printUpdateGuide()
        }
    }

    // MARK: - vvx engine status

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Print the installed yt-dlp version and path."
        )

        mutating func run() async throws {
            let resolver = EngineResolver.cliResolver
            if let url = resolver.resolvedYtDlpURL() {
                let storedVersion = UserDefaults.standard.string(forKey: EngineUpdater.versionDefaultsKey)
                CLIOutputFormatter.engineStatus(version: storedVersion, path: url.path)
            } else {
                CLIOutputFormatter.engineNotFound()
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - Install / update guide output

private func printInstallGuide() {
    print("""

    yt-dlp is required to fetch video content.
    vvx does not install it automatically — install it once with your package manager:

      macOS (Homebrew):  brew install yt-dlp
      All platforms:     pip install yt-dlp
      Direct binary:     https://github.com/yt-dlp/yt-dlp#installation

    After installing, run `vvx doctor` to verify your setup.

    """)
}

private func printUpdateGuide() {
    print("""

    yt-dlp is maintained by the community and updated frequently.
    Update it using the same package manager you used to install it:

      macOS (Homebrew):  brew upgrade yt-dlp
      All platforms:     pip install -U yt-dlp

    After updating, retry your command.

    """)
}
