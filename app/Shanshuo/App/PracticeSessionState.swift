import Foundation

/// Memory-only evidence for the onboarding exercise. A typed or prefilled string has no matching
/// delivery evidence and cannot complete the step. Each hold press creates a new attempt identity,
/// so a delayed insertion from a previous practice page cannot satisfy a later attempt.
struct PracticeSessionState {
  private var activeAttemptID: UUID?
  private var initialText = ""
  private(set) var expectedPasteText: String?
  private(set) var pasteWasRequested = false
  private(set) var succeeded = false

  mutating func beginAttempt(_ attemptID: UUID, initialText: String) {
    activeAttemptID = attemptID
    self.initialText = initialText
    expectedPasteText = nil
    pasteWasRequested = false
    succeeded = false
  }

  mutating func notePasteRequest() {
    guard activeAttemptID != nil else {
      return
    }
    pasteWasRequested = true
  }

  mutating func expectCopiedText(_ text: String, attemptID: UUID) {
    guard activeAttemptID == attemptID else {
      return
    }
    expectedPasteText = text
  }

  mutating func verifyPastedReadback(_ text: String) -> Bool {
    guard
      pasteWasRequested,
      let expectedPasteText,
      text == expectedPasteText,
      text != initialText
    else {
      return false
    }
    succeeded = true
    return true
  }

  mutating func verifyDirectReadback(
    _ text: String,
    expectedText: String,
    attemptID: UUID,
    isVerifiedDirectInsertion: Bool
  ) -> Bool {
    guard activeAttemptID == attemptID, text == expectedText else {
      return false
    }
    // AX supplies a receipt. The paste fallback has no receipt, so a paste event after this
    // attempt and a changed control value are the minimum evidence that matching text was
    // delivered rather than prefilled.
    let hasUnverifiedPasteEvidence = pasteWasRequested && text != initialText
    if !isVerifiedDirectInsertion, !hasUnverifiedPasteEvidence {
      return false
    }
    succeeded = true
    return true
  }

  mutating func clear() {
    activeAttemptID = nil
    initialText = ""
    expectedPasteText = nil
    pasteWasRequested = false
    succeeded = false
  }
}
