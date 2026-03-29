import Foundation
import Testing
@testable import VideoVortexCore

// MARK: - EngineUpdater stub tests

@Suite("EngineUpdater stub")
struct EngineUpdaterStubTests {

    @Test("updateIfNewerAvailable always returns false")
    func updateIfNewerAvailableReturnsNoOp() async {
        let engineDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvx-test-\(UUID().uuidString)")
        let result = await EngineUpdater.shared.updateIfNewerAvailable(engineDirectory: engineDir)
        #expect(result == false)
    }

    @Test("forceInstallLatest throws usePackageManager")
    func forceInstallLatestThrows() async {
        let engineDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvx-test-\(UUID().uuidString)")
        do {
            _ = try await EngineUpdater.shared.forceInstallLatest(engineDirectory: engineDir)
            Issue.record("Expected forceInstallLatest to throw, but it returned successfully")
        } catch let error as EngineUpdater.EngineUpdateError {
            #expect(error == .usePackageManager)
        } catch {
            Issue.record("Expected EngineUpdateError.usePackageManager, got: \(error)")
        }
    }

    @Test("EngineUpdateError description contains brew and pip")
    func errorDescriptionContainsInstallOptions() {
        let error = EngineUpdater.EngineUpdateError.usePackageManager
        let description = error.errorDescription ?? ""
        #expect(description.contains("brew install yt-dlp"))
        #expect(description.contains("pip install yt-dlp"))
    }
}

// MARK: - Extractor error detection tests

@Suite("Extractor error detection")
struct ExtractorErrorDetectionTests {

    @Test("Detects ExtractorError signal")
    func detectsExtractorError() {
        let stderr = "ERROR: ExtractorError: Could not find player response"
        #expect(VideoSenser.looksLikeExtractorError(stderr) == true)
    }

    @Test("Detects nsig extraction failed")
    func detectsNsigFailure() {
        let stderr = "[youtube] nsig extraction failed: some message here"
        #expect(VideoSenser.looksLikeExtractorError(stderr) == true)
    }

    @Test("Detects ERROR: [youtube] prefix")
    func detectsYouTubeErrorPrefix() {
        let stderr = "ERROR: [youtube] dQw4w9WgXcQ: Sign in to confirm your age"
        #expect(VideoSenser.looksLikeExtractorError(stderr) == true)
    }

    @Test("Ignores ordinary network errors")
    func ignoresNetworkError() {
        let stderr = "ERROR: Unable to connect to the server. Network error."
        // "Unable to connect" does not match our extractor signals
        #expect(VideoSenser.looksLikeExtractorError(stderr) == false)
    }

    @Test("Ignores empty stderr")
    func ignoresEmptyStderr() {
        #expect(VideoSenser.looksLikeExtractorError("") == false)
    }

    @Test("guidedUpdateMessage contains brew and pip commands")
    func guidedUpdateMessageContainsCommands() {
        let msg = VideoSenser.guidedUpdateMessage
        #expect(msg.contains("brew upgrade yt-dlp"))
        #expect(msg.contains("pip install -U yt-dlp"))
    }

    @Test("VideoDownloader looksLikeExtractorError matches VideoSenser logic")
    func downloaderAndSenserAgree() {
        let stderrSamples = [
            "ExtractorError: something broke",
            "nsig extraction failed",
            "ERROR: [youtube] abc: Sign in to confirm",
            "normal download output",
        ]
        for sample in stderrSamples {
            let downloaderResult = VideoDownloader.looksLikeExtractorError(sample)
            let senserResult     = VideoSenser.looksLikeExtractorError(sample)
            #expect(downloaderResult == senserResult, "Mismatch for: \(sample)")
        }
    }
}

// MARK: - ENGINE_NOT_FOUND agentAction test

@Suite("VvxError agentAction")
struct VvxErrorAgentActionTests {

    @Test("ENGINE_NOT_FOUND agentAction mentions brew and pip")
    func engineNotFoundAgentAction() {
        let action = VvxError.defaultAgentAction(for: .engineNotFound)
        #expect(action.contains("brew install yt-dlp"))
        #expect(action.contains("pip install yt-dlp"))
    }

    @Test("PARSE_ERROR agentAction mentions upgrade commands")
    func parseErrorAgentAction() {
        let action = VvxError.defaultAgentAction(for: .parseError)
        #expect(action.contains("brew upgrade yt-dlp") || action.contains("pip install -U yt-dlp"))
    }
}
