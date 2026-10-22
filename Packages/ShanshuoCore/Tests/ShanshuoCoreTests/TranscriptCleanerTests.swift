import Testing

@testable import ShanshuoCore

@Suite("TranscriptCleaner")
struct TranscriptCleanerTests {
  @Test("keeps normal text and trims surrounding whitespace")
  func keepsText() {
    #expect(TranscriptCleaner.clean("  明天下午三点开会。 \n") == "明天下午三点开会。")
    #expect(TranscriptCleaner.clean("Ship the build today") == "Ship the build today")
  }

  @Test("empty or punctuation-only output means nothing was recognised")
  func emptyIsNil() {
    #expect(TranscriptCleaner.clean("") == nil)
    #expect(TranscriptCleaner.clean("   \n\t") == nil)
    #expect(TranscriptCleaner.clean("。") == nil)
    #expect(TranscriptCleaner.clean(" ,. ？") == nil)
  }

  @Test(
    "a bare chat-role token is a model artefact, not speech (T001: hotword run produced \"system\")"
  )
  func roleTokenIsNil() {
    #expect(TranscriptCleaner.clean("system") == nil)
    #expect(TranscriptCleaner.clean(" Assistant. ") == nil)
    #expect(TranscriptCleaner.clean("user") == nil)
  }

  @Test("role words inside a real sentence are kept")
  func roleWordInSentenceKept() {
    #expect(TranscriptCleaner.clean("the system is down") == "the system is down")
    #expect(TranscriptCleaner.clean("新 user 注册流程") == "新 user 注册流程")
  }
}
