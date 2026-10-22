import Foundation
import Testing

@testable import ShanshuoCore

@Suite("Dictation rules")
struct DictationRulesTests {
  private let editableTarget = TargetSnapshot(
    bundleIdentifier: "com.apple.Notes",
    processIdentifier: 42,
    elementIdentifier: "note-body",
    isEditable: true,
    isSecure: false
  )

  @Test("start requires live permissions, a ready model, a microphone and a visible indicator")
  func startRestrictions() {
    let ready = StartContext(
      isPaused: false,
      isBusy: false,
      microphonePermission: .authorized,
      microphoneAvailable: true,
      modelReady: true,
      indicatorAvailable: true,
      secureInputActive: false
    )

    #expect(DictationRules.startDecision(ready) == .allowed)

    let cases: [(StartContext, StartRejection)] = [
      (
        StartContext(
          isPaused: true, isBusy: false, microphonePermission: .authorized,
          microphoneAvailable: true, modelReady: true, indicatorAvailable: true,
          secureInputActive: false), .paused
      ),
      (
        StartContext(
          isPaused: false, isBusy: false, microphonePermission: .authorized,
          microphoneAvailable: true, modelReady: true, indicatorAvailable: true,
          secureInputActive: true), .secureField
      ),
      (
        StartContext(
          isPaused: false, isBusy: true, microphonePermission: .authorized,
          microphoneAvailable: true, modelReady: true, indicatorAvailable: true,
          secureInputActive: false), .busy
      ),
      (
        StartContext(
          isPaused: false, isBusy: false, microphonePermission: .denied, microphoneAvailable: true,
          modelReady: true, indicatorAvailable: true, secureInputActive: false),
        .microphonePermission
      ),
      (
        StartContext(
          isPaused: false, isBusy: false, microphonePermission: .authorized,
          microphoneAvailable: false, modelReady: true, indicatorAvailable: true,
          secureInputActive: false), .microphoneUnavailable
      ),
      (
        StartContext(
          isPaused: false, isBusy: false, microphonePermission: .authorized,
          microphoneAvailable: true, modelReady: false, indicatorAvailable: true,
          secureInputActive: false), .modelUnavailable
      ),
      (
        StartContext(
          isPaused: false, isBusy: false, microphonePermission: .authorized,
          microphoneAvailable: true, modelReady: true, indicatorAvailable: false,
          secureInputActive: false), .indicatorUnavailable
      ),
    ]

    for (context, rejection) in cases {
      #expect(DictationRules.startDecision(context) == .rejected(rejection))
    }
  }

  @Test("short holds are discarded and recording stops after exactly three minutes")
  func durationRules() {
    #expect(DictationRules.releaseDisposition(heldFor: 0.299) == .discardMisfire)
    #expect(DictationRules.releaseDisposition(heldFor: 0.3) == .recognize)
    #expect(DictationRules.countdownSeconds(elapsed: 164.999) == nil)
    #expect(DictationRules.countdownSeconds(elapsed: 165) == 15)
    #expect(DictationRules.countdownSeconds(elapsed: 179.001) == 1)
    #expect(!DictationRules.shouldAutoStop(elapsed: 179.999))
    #expect(DictationRules.shouldAutoStop(elapsed: 180))
  }

  @Test("Esc consumption is decided before cancellation changes session state")
  func escapeInterception() {
    #expect(DictationRules.shouldConsumeEscape(cancellationInterceptionEnabled: true))
    #expect(!DictationRules.shouldConsumeEscape(cancellationInterceptionEnabled: false))
  }

  @Test("secure input discards; changed, unknown and unavailable targets copy")
  func insertionRules() {
    let direct = InsertionContext(
      releasedTarget: editableTarget,
      currentTarget: editableTarget,
      focusMatch: .same,
      accessibilityPermission: .authorized,
      secureInputActive: false
    )
    #expect(DictationRules.insertionDecision(direct).action == .insert)

    var changed = direct
    changed.focusMatch = .changed
    #expect(DictationRules.insertionDecision(changed).action == .copy)

    var unknown = direct
    unknown.focusMatch = .unknown
    #expect(DictationRules.insertionDecision(unknown).action == .copy)

    var noAccessibility = direct
    noAccessibility.accessibilityPermission = .denied
    #expect(DictationRules.insertionDecision(noAccessibility).action == .copy)

    var secure = direct
    secure.secureInputActive = true
    #expect(DictationRules.insertionDecision(secure).action == .discard)
  }

  @Test("history keeps the most recent seven days")
  func historyRetention() {
    struct Record {
      let createdAt: Date
    }

    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let records = [
      Record(createdAt: now.addingTimeInterval(-6 * 24 * 60 * 60)),
      Record(createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60)),
    ]
    let retained = DictationRules.retainHistory(records, now: now, createdAt: \.createdAt)
    #expect(retained.count == 1)
  }

  @Test("invalidating a generation makes earlier async completions stale")
  func sessionGeneration() {
    var generation = SessionGeneration(value: 7)
    let pending = generation
    generation.invalidate()
    #expect(pending != generation)
    #expect(generation.value == 8)
  }

  @Test("clipboard restoration never overwrites a newer user clipboard")
  func clipboardOwnership() {
    #expect(ClipboardOwnership.mayRestore(ownedChangeCount: 12, currentChangeCount: 12))
    #expect(!ClipboardOwnership.mayRestore(ownedChangeCount: 12, currentChangeCount: 13))
  }
}
