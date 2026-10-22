import Foundation

/// Memory-only evidence for the onboarding exercise. This value is never encoded into onboarding
/// progress or history. A typed or prefilled string has no matching delivery evidence and cannot
/// complete the step.
struct PracticeSessionState {
  private(set) var expectedPasteText: String?
  private(set) var pasteWasRequested = false
  private(set) var succeeded = false

  mutating func notePasteRequest() {
    pasteWasRequested = true
  }

  mutating func expectCopiedText(_ text: String) {
    expectedPasteText = text
    pasteWasRequested = false
  }

  mutating func verifyPastedReadback(_ text: String) -> Bool {
    guard pasteWasRequested, let expectedPasteText, text == expectedPasteText else {
      return false
    }
    succeeded = true
    return true
  }

  mutating func verifyDirectReadback(_ text: String, expectedText: String) -> Bool {
    guard text == expectedText else {
      return false
    }
    succeeded = true
    return true
  }

  mutating func clear() {
    expectedPasteText = nil
    pasteWasRequested = false
    succeeded = false
  }
}
