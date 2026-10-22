import Foundation

/// Memory-only evidence for the onboarding exercise. A typed or prefilled string has no matching
/// delivery evidence and cannot complete the step. Each hold press creates a new attempt identity,
/// so a delayed insertion from a previous practice page cannot satisfy a later attempt.
struct PracticeSessionState {
  private(set) var activeAttemptID: UUID?
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

  @discardableResult
  mutating func notePasteRequest() -> UUID? {
    guard let activeAttemptID else {
      return nil
    }
    pasteWasRequested = true
    return activeAttemptID
  }

  mutating func expectCopiedText(_ text: String, attemptID: UUID) {
    guard activeAttemptID == attemptID else {
      return
    }
    expectedPasteText = text
  }

  mutating func verifyPastedReadback(_ text: String) -> Bool {
    validatePastedReadback(text) == .verified
  }

  mutating func verifyDirectReadback(
    _ text: String,
    expectedText: String,
    attemptID: UUID,
    isVerifiedDirectInsertion: Bool
  ) -> Bool {
    validateDirectReadback(
      text,
      expectedText: expectedText,
      attemptID: attemptID,
      isVerifiedDirectInsertion: isVerifiedDirectInsertion
    ) == .verified
  }

  /// Categorizes the same proof checks used to complete the practice step. No compared text is
  /// retained in the result, so callers can record the reason without emitting dictated content.
  mutating func validatePastedReadback(_ text: String) -> PracticeReadbackValidation {
    guard activeAttemptID != nil else {
      return .noActiveAttempt
    }
    guard pasteWasRequested else {
      return .pasteNotObserved
    }
    guard let expectedPasteText else {
      return .pasteExpectationMissing
    }
    guard text == expectedPasteText else {
      return .readbackMismatch
    }
    guard text != initialText else {
      return .readbackUnchanged
    }
    succeeded = true
    return .verified
  }

  /// AX supplies a receipt. The paste fallback has no receipt, so a paste event after this
  /// attempt and a changed control value are the minimum evidence that matching text was
  /// delivered rather than prefilled.
  mutating func validateDirectReadback(
    _ text: String,
    expectedText: String,
    attemptID: UUID,
    isVerifiedDirectInsertion: Bool
  ) -> PracticeReadbackValidation {
    guard activeAttemptID != nil else {
      return .noActiveAttempt
    }
    guard activeAttemptID == attemptID else {
      return .attemptMismatch
    }
    guard text == expectedText else {
      return .readbackMismatch
    }
    if !isVerifiedDirectInsertion {
      guard pasteWasRequested else {
        return .pasteNotObserved
      }
      guard text != initialText else {
        return .readbackUnchanged
      }
    }
    succeeded = true
    return .verified
  }

  mutating func clear() {
    activeAttemptID = nil
    initialText = ""
    expectedPasteText = nil
    pasteWasRequested = false
    succeeded = false
  }
}
