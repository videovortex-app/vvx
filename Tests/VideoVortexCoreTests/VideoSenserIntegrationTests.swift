import Foundation
import Testing
@testable import VideoVortexCore

// MARK: - Fake yt-dlp fixture

/// Creates a temp directory containing an executable `fake-yt-dlp` that mimics argv shape
/// from `VideoSenser.buildArguments` without touching production code.
private func makeFakeYtDlpFixture() throws -> (tempDir: URL, ytDlpURL: URL) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vvx-senser-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let scriptURL = tempDir.appendingPathComponent("fake-yt-dlp")
    let script = """
    #!/usr/bin/env bash
    set -euo pipefail
    for arg in "$@"; do
      case "$arg" in
        *timeout_test_url*) exec sleep 10 ;;
      esac
    done
    line='{"title":"dummy","extractor_key":"youtube"}'
    for ((i=0; i<2600; i++)); do
      printf '%s\\n' "$line"
    done
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: scriptURL.path
    )

    return (tempDir, scriptURL)
}

private func collectSenseTermination(
    from senser: VideoSenser,
    config: SenseConfig
) async -> SenseTermination {
    var lastFailed: VvxError?
    var completed: SenseResult?
    for await event in senser.sense(config: config) {
        switch event {
        case .completed(let result):
            completed = result
        case .failed(let error):
            lastFailed = error
        case .preparing, .milestone, .retrying:
            break
        }
    }
    if let completed {
        return .completed(completed)
    }
    if let lastFailed {
        return .failed(lastFailed)
    }
    return .none
}

private enum SenseTermination {
    case completed(SenseResult)
    case failed(VvxError)
    case none
}

// MARK: - Suite

@Suite("VideoSenser integration")
struct VideoSenserIntegrationTests {

    @Test("Pipe buffer stress: large stdout parses and completes without hanging")
    func pipeBufferStress() async throws {
        let (tempDir, fakeYtDlp) = try makeFakeYtDlpFixture()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = SenseConfig(
            url: "https://example.com/watch?v=pipe-stress",
            outputDirectory: tempDir.appendingPathComponent("out", isDirectory: true),
            ytDlpPath: fakeYtDlp,
            timeoutSeconds: 120
        )

        let senser = VideoSenser()
        let termination = await collectSenseTermination(from: senser, config: config)

        guard case .completed(let result) = termination else {
            if case .failed(let err) = termination {
                Issue.record("Expected completion, got failure: \(err.message) detail: \(err.detail ?? "")")
            } else {
                Issue.record("Expected completion, got no terminal event")
            }
            return
        }

        #expect(result.success)
        #expect(result.title == "dummy")
        #expect(result.platform == "YouTube")
    }

    @Test("Timeout: slow fake yields failed with timed-out detail")
    func timeoutKillsProcess() async throws {
        let (tempDir, fakeYtDlp) = try makeFakeYtDlpFixture()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = SenseConfig(
            url: "https://example.com/timeout_test_url",
            outputDirectory: tempDir.appendingPathComponent("out", isDirectory: true),
            ytDlpPath: fakeYtDlp,
            timeoutSeconds: 1
        )

        let start = ContinuousClock.now
        let senser = VideoSenser()
        let termination = await collectSenseTermination(from: senser, config: config)
        let elapsed = ContinuousClock.now - start

        guard case .failed(let error) = termination else {
            if case .completed(let r) = termination {
                Issue.record("Expected failure, got completion: \(r.title)")
            } else {
                Issue.record("Expected failure, got no terminal event")
            }
            return
        }

        let detail = error.detail ?? ""
        #expect(detail.localizedStandardContains("timed out"))
        #expect(elapsed < .seconds(4))
    }
}
