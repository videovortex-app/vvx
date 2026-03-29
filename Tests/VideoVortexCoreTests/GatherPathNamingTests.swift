import Foundation
import Testing
import VideoVortexCore

@Suite("GatherPathNaming")
struct GatherPathNamingTests {

    @Test("sanitizeFolderQuery collapses, underscores spaces, empty → gather")
    func sanitizeFolderQuery() {
        #expect(GatherPathNaming.sanitizeFolderQuery("hello world") == "hello_world")
        #expect(GatherPathNaming.sanitizeFolderQuery("") == "gather")
        #expect(GatherPathNaming.sanitizeFolderQuery("   ") == "gather")
    }

    @Test("filenameSnippet is first five words, deterministic")
    func filenameSnippet() {
        let s = GatherPathNaming.filenameSnippet(from: "artificial general intelligence is here today")
        #expect(!s.isEmpty)
        #expect(s != "snippet")
        #expect(GatherPathNaming.filenameSnippet(from: "") == "snippet")
        #expect(GatherPathNaming.filenameSnippet(from: "   \n\t  ") == "snippet")
    }

    @Test("filenameSnippet strips shell-unsafe chars (apostrophes, parens, exclamation)")
    func filenameSnippetShellSafe() {
        let s = GatherPathNaming.filenameSnippet(from: "and that's cool")
        #expect(!s.contains("'"))
        let s2 = GatherPathNaming.filenameSnippet(from: "(baaaaaaaaaaahhh!!)")
        #expect(!s2.contains("("))
        #expect(!s2.contains(")"))
        #expect(!s2.contains("!"))
    }

    @Test("uploaderToken produces shell-safe name or Unknown")
    func uploaderToken() {
        #expect(GatherPathNaming.uploaderToken("jawed") == "jawed")
        #expect(GatherPathNaming.uploaderToken("Lex Fridman") == "Lex_Fridman")
        #expect(GatherPathNaming.uploaderToken(nil) == "Unknown")
        #expect(GatherPathNaming.uploaderToken("") == "Unknown")
        // Special characters stripped
        let t = GatherPathNaming.uploaderToken("O'Brien & Co!")
        #expect(!t.contains("'"))
        #expect(!t.contains("!"))
        #expect(!t.contains("&"))
    }

    @Test("shellSafeComponent removes apostrophes, parens, exclamation marks")
    func shellSafeComponent() {
        let result = GatherPathNaming.shellSafeComponent("and_that's_cool", maxLength: 60)
        #expect(!result.contains("'"))
        let result2 = GatherPathNaming.shellSafeComponent("(baaaaaaaaaaahhh!!)", maxLength: 60)
        #expect(!result2.contains("("))
        #expect(!result2.contains("!"))
        #expect(!result2.isEmpty)
    }

    @Test("parseSRTTimestampToSeconds handles comma milliseconds")
    func parseSRT() {
        #expect(GatherPathNaming.parseSRTTimestampToSeconds("00:01:30,500") == 90.5)
        #expect(GatherPathNaming.parseSRTTimestampToSeconds("00:00:02,000") == 2)
    }

    @Test("paddedClipIndex width follows total digit count")
    func paddedIndex() {
        #expect(GatherPathNaming.paddedClipIndex(1, total: 5) == "01")
        #expect(GatherPathNaming.paddedClipIndex(10, total: 99) == "10")
        #expect(GatherPathNaming.paddedClipIndex(3, total: 100) == "003")
    }
}
