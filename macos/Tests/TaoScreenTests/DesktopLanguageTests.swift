import Testing
@testable import TaoScreen

struct DesktopLanguageTests {
    @Test func resolvesFirstSupportedSystemLanguage() {
        #expect(DesktopLanguage.resolve(.system, preferredLanguages: ["fr-FR", "en-GB", "zh-Hans-CN"]) == .english)
        #expect(DesktopLanguage.resolve(.system, preferredLanguages: ["zh-Hant-TW", "en-US"]) == .chinese)
        #expect(DesktopLanguage.resolve(.system, preferredLanguages: ["ja-JP"]) == .english)
        #expect(DesktopLanguage.resolve(.system, preferredLanguages: []) == .english)
    }

    @Test func preservesExplicitChoice() {
        #expect(DesktopLanguage.resolve(.english, preferredLanguages: ["zh-CN"]) == .english)
        #expect(DesktopLanguage.resolve(.chinese, preferredLanguages: ["en-US"]) == .chinese)
    }
}
