import Foundation
import ShanshuoCore

private final class FakePermissions: PermissionProviding {
  var microphonePermission: PermissionStatus = .authorized
  var accessibilityPermission: PermissionStatus = .authorized
}

private final class FakeFocus: FocusInspecting {
  var current: SystemFocusSnapshot
  var matchResult: FocusMatch = .same

  init(target: TargetSnapshot) {
    current = SystemFocusSnapshot(target: target, element: nil)
  }

  func snapshot() -> SystemFocusSnapshot {
    current
  }

  func match(_ expected: SystemFocusSnapshot, _ actual: SystemFocusSnapshot) -> FocusMatch {
    matchResult
  }
}

private final class ManualScheduledWork: ScheduledTextInsertionWork {
  let deadline: TimeInterval
  let action: () -> Void
  private(set) var isCancelled = false

  init(deadline: TimeInterval, action: @escaping () -> Void) {
    self.deadline = deadline
    self.action = action
  }

  func cancel() {
    isCancelled = true
  }

  func runIfActive() {
    guard !isCancelled else {
      return
    }
    action()
  }
}

private final class ManualTextInsertionScheduler: TextInsertionScheduling {
  private var now: TimeInterval = 0
  private var work: [ManualScheduledWork] = []

  func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
    -> ScheduledTextInsertionWork
  {
    let scheduled = ManualScheduledWork(deadline: now + delay, action: action)
    work.append(scheduled)
    return scheduled
  }

  func advance(to time: TimeInterval) {
    now = time
    while let index = work.indices.first(where: { work[$0].deadline <= now }) {
      let next = work.remove(at: index)
      next.runIfActive()
    }
  }
}

private final class FakeClipboard: ClipboardControlling {
  var changeCount = 0
  var items: ClipboardSnapshot
  var temporaryRead: (() -> Void)?
  var temporaryWrites = 0
  var textWrites = 0
  var restores = 0
  var acceptsTextWrites = true
  var hasTemporaryTextProvider: Bool {
    temporaryRead != nil
  }

  init(items: ClipboardSnapshot) {
    self.items = items
  }

  func snapshot() -> ClipboardSnapshot {
    items
  }

  func writeTemporaryText(_ text: String, onRead: @escaping () -> Void) -> Int? {
    temporaryWrites += 1
    temporaryRead = onRead
    items = [[ClipboardItemData(type: "public.utf8-plain-text", data: Data(text.utf8))]]
    changeCount += 1
    return changeCount
  }

  func writeText(_ text: String) -> Bool {
    textWrites += 1
    guard acceptsTextWrites else {
      return false
    }
    items = [[ClipboardItemData(type: "public.utf8-plain-text", data: Data(text.utf8))]]
    changeCount += 1
    return true
  }

  func restore(_ snapshot: ClipboardSnapshot) {
    restores += 1
    items = snapshot
    changeCount += 1
    temporaryRead = nil
  }

  func releaseTemporaryTextProvider() {
    temporaryRead = nil
  }

  func simulateTargetRead() {
    temporaryRead?()
  }

  func simulateForeignClipboardWrite() {
    items = [[ClipboardItemData(type: "public.utf8-plain-text", data: Data("foreign".utf8))]]
    changeCount += 1
  }
}

private final class FakeEventPoster: TextEventPosting {
  var pastePosts = 0
  var unicodePosts: [String] = []

  func postPaste() {
    pastePosts += 1
  }

  func postUnicode(_ text: String) {
    unicodePosts.append(text)
  }
}

private final class FakePerformanceRecorder: PerformanceEventRecording {
  let processID = UUID()
  private var nextTimestamp: UInt64 = 0
  private(set) var events: [PerformanceDiagnosticEvent] = []

  func now() -> MonotonicTimestamp {
    nextTimestamp &+= 1
    return MonotonicTimestamp(nanoseconds: nextTimestamp)
  }

  func record(
    kind: PerformanceEventKind,
    result: PerformanceEventResult,
    sessionID: UUID,
    timestamp: MonotonicTimestamp,
    audioDuration: TimeInterval?
  ) {
    events.append(
      PerformanceDiagnosticEvent(
        kind: kind,
        result: result,
        processID: processID,
        sessionID: sessionID,
        timestamp: timestamp,
        audioDuration: audioDuration
      )
    )
  }
}

private struct Harness {
  let permissions = FakePermissions()
  let focus: FakeFocus
  let clipboard: FakeClipboard
  let scheduler = ManualTextInsertionScheduler()
  let poster = FakeEventPoster()
  let performanceRecorder = FakePerformanceRecorder()
  let inserter: SystemTextInserter
  let target: SystemFocusSnapshot

  init() {
    let targetSnapshot = TargetSnapshot(
      bundleIdentifier: "com.example.Editor",
      processIdentifier: 100,
      elementIdentifier: "editor",
      isEditable: true,
      isSecure: false
    )
    target = SystemFocusSnapshot(target: targetSnapshot, element: nil)
    focus = FakeFocus(target: targetSnapshot)
    clipboard = FakeClipboard(
      items: [
        [
          ClipboardItemData(type: "public.utf8-plain-text", data: Data("original".utf8)),
          ClipboardItemData(type: "public.png", data: Data([1, 2, 3])),
        ]
      ]
    )
    inserter = SystemTextInserter(
      permissions: permissions,
      focusInspector: focus,
      clipboard: clipboard,
      scheduler: scheduler,
      eventPoster: poster,
      secureInputActive: { false },
      performanceDiagnostics: performanceRecorder
    )
  }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func testCancellationBeforePostRestoresOwnedClipboard() {
  let harness = Harness()
  let original = harness.clipboard.snapshot()
  var results: [TextInsertionResult] = []
  let operation = harness.inserter.insert("dictated", expectedTarget: harness.target) {
    results.append($0)
  }
  operation.cancel()
  harness.scheduler.advance(to: 2)

  check(harness.poster.pastePosts == 0, "cancel before delayed paste must not post Command-V")
  check(harness.clipboard.snapshot() == original, "cancel restores the owned multi-type clipboard")
  check(results.isEmpty, "cancelled insertion must not report a result")
}

private func testPerformanceEventsDescribeOnlyCompletedOrRequestedActions() {
  let harness = Harness()
  let copySessionID = UUID()
  harness.inserter.setPerformanceSessionID(copySessionID)
  _ = harness.inserter.copy("copy this", requiresAccessibility: false) { _ in }
  check(
    harness.performanceRecorder.events.contains {
      $0.kind == .copyCompleted
        && $0.result == .copied
        && $0.sessionID == copySessionID
    },
    "the production inserter records clipboard completion after its real write"
  )

  let pasteSessionID = UUID()
  harness.inserter.setPerformanceSessionID(pasteSessionID)
  _ = harness.inserter.insert("request paste", expectedTarget: harness.target) { _ in }
  harness.scheduler.advance(to: 0.03)
  check(
    harness.performanceRecorder.events.contains {
      $0.kind == .pasteRequested
        && $0.result == .requested
        && $0.sessionID == pasteSessionID
    },
    "the production inserter records Command-V as a request"
  )
  check(
    !harness.performanceRecorder.events.contains {
      $0.kind == .pasteRequested && $0.result == .verifiedInsertion
    },
    "a requested paste never claims verified insertion"
  )
}

private func testCancellationAfterPostStopsTimeoutFallback() {
  let harness = Harness()
  let original = harness.clipboard.snapshot()
  var results: [TextInsertionResult] = []
  let operation = harness.inserter.insert("dictated", expectedTarget: harness.target) {
    results.append($0)
  }
  harness.scheduler.advance(to: 0.03)
  check(harness.poster.pastePosts == 1, "eligible operation posts Command-V once")
  operation.cancel()
  harness.scheduler.advance(to: 2)

  check(harness.clipboard.snapshot() == original, "cancel after post restores only owned clipboard")
  check(harness.clipboard.textWrites == 0, "cancelled timeout must not copy later")
  check(results.isEmpty, "cancel after post must not produce a late receipt")
}

private func testSecureCancellationCannotResumeAfterLeavingSecureInput() {
  let harness = Harness()
  let original = harness.clipboard.snapshot()
  var results: [TextInsertionResult] = []
  let operation = harness.inserter.insert("dictated", expectedTarget: harness.target) {
    results.append($0)
  }
  harness.scheduler.advance(to: 0.03)
  harness.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.example.Editor",
      processIdentifier: 100,
      elementIdentifier: "password",
      isEditable: true,
      isSecure: true
    ),
    element: nil
  )
  // The coordinator cancels as soon as its continuous secure-input check observes this.
  operation.cancel()
  harness.focus.current = harness.target
  harness.scheduler.advance(to: 2)

  check(harness.clipboard.snapshot() == original, "secure cancellation restores temporary data")
  check(harness.clipboard.textWrites == 0, "leaving secure input cannot revive a cancelled copy")
  check(results.isEmpty, "secure cancellation has no later result")
}

private func testNoReadTimeoutRestoresRatherThanClaimingCopy() {
  let harness = Harness()
  let original = harness.clipboard.snapshot()
  var result: TextInsertionResult?
  _ = harness.inserter.insert("dictated", expectedTarget: harness.target) { result = $0 }
  harness.scheduler.advance(to: 0.03)
  harness.scheduler.advance(to: 1)

  check(
    harness.poster.pastePosts == 1,
    "timeout fixture uses the production delayed paste path (posts \(harness.poster.pastePosts))"
  )
  check(
    harness.clipboard.snapshot() == original,
    "no-read timeout restores all original clipboard types")
  check(harness.clipboard.textWrites == 0, "timeout does not claim copied text without a write")
  guard case .unverified? = result else {
    check(false, "timeout must be unverified")
    return
  }
}

private func testClipboardChangeBeforePostNeverPastesUserClipboard() {
  let harness = Harness()
  var result: TextInsertionResult?
  _ = harness.inserter.insert("dictated", expectedTarget: harness.target) { result = $0 }
  harness.clipboard.simulateForeignClipboardWrite()
  harness.scheduler.advance(to: 0.03)

  check(harness.poster.pastePosts == 0, "lost clipboard ownership must block Command-V")
  check(harness.clipboard.textWrites == 0, "lost ownership must not overwrite the newer clipboard")
  check(
    harness.clipboard.snapshot()
      == [[ClipboardItemData(type: "public.utf8-plain-text", data: Data("foreign".utf8))]],
    "lost ownership preserves the newer clipboard contents"
  )
  check(
    !harness.clipboard.hasTemporaryTextProvider, "completion releases a stale temporary provider")
  guard case .unverified? = result else {
    check(false, "lost clipboard ownership is not a verified insertion")
    return
  }
}

private func testPermissionRevocationBeforePasteDiscardsWithoutCopying() {
  func assertDiscardedAfterRevocation(
    _ revoke: (Harness) -> Void,
    label: String
  ) {
    let harness = Harness()
    let original = harness.clipboard.snapshot()
    var result: TextInsertionResult?
    _ = harness.inserter.insert("dictated", expectedTarget: harness.target) { result = $0 }
    revoke(harness)
    harness.scheduler.advance(to: 0.03)

    check(harness.poster.pastePosts == 0, "\(label) revocation must block Command-V")
    check(harness.clipboard.textWrites == 0, "\(label) revocation must not make a final copy")
    check(
      harness.clipboard.snapshot() == original,
      "\(label) revocation restores only the owned clipboard")
    check(
      !harness.clipboard.hasTemporaryTextProvider,
      "\(label) revocation releases the temporary clipboard provider"
    )
    guard case .discarded? = result else {
      check(false, "\(label) revocation must report discard")
      return
    }
  }

  assertDiscardedAfterRevocation(
    { $0.permissions.microphonePermission = .denied }, label: "microphone")
  assertDiscardedAfterRevocation(
    { $0.permissions.accessibilityPermission = .denied },
    label: "Accessibility"
  )
}

private func testCopyPolicyPreservesCopyOnlyWithoutAccessibility() {
  let copyOnlyHarness = Harness()
  copyOnlyHarness.permissions.accessibilityPermission = .denied
  var copyOnlyResult: TextInsertionResult?
  _ = copyOnlyHarness.inserter.copy("copy-only", requiresAccessibility: false) {
    copyOnlyResult = $0
  }
  check(
    copyOnlyHarness.clipboard.textWrites == 1,
    "copy-only writes the clipboard without Accessibility")
  guard case .copied? = copyOnlyResult else {
    check(false, "copy-only reports its successful explicit clipboard write")
    return
  }

  let directFallbackHarness = Harness()
  directFallbackHarness.permissions.accessibilityPermission = .denied
  var directFallbackResult: TextInsertionResult?
  _ = directFallbackHarness.inserter.copy("direct fallback", requiresAccessibility: true) {
    directFallbackResult = $0
  }
  check(
    directFallbackHarness.clipboard.textWrites == 0,
    "a direct-session fallback cannot write after Accessibility is revoked"
  )
  guard case .discarded? = directFallbackResult else {
    check(false, "a direct-session fallback reports discard after Accessibility revocation")
    return
  }
}

private func testForeignClipboardAndSupersedingOperationStaySafe() {
  let harness = Harness()
  var firstResults: [TextInsertionResult] = []
  let first = harness.inserter.insert("first", expectedTarget: harness.target) {
    firstResults.append($0)
  }
  harness.scheduler.advance(to: 0.03)
  harness.clipboard.simulateForeignClipboardWrite()
  first.cancel()
  harness.scheduler.advance(to: 2)
  check(
    harness.clipboard.restores == 0, "foreign clipboard is never overwritten during cancellation")
  check(firstResults.isEmpty, "cancelled first operation remains silent")

  var secondResult: TextInsertionResult?
  _ = harness.inserter.copy("second", requiresAccessibility: false) { secondResult = $0 }
  check(harness.clipboard.textWrites == 1, "superseding operation performs its own explicit copy")
  guard case .copied? = secondResult else {
    check(false, "explicit copy reports success only after its write")
    return
  }
}

private func testEscapeInterceptionSnapshotsCurrentState() {
  var activeCancellationCount = 0
  let activeConsumed = SystemHotkeyMonitor.handleEscape(
    cancellationInterceptionEnabled: true
  ) {
    activeCancellationCount += 1
  }
  check(activeConsumed, "Esc during an active session must be swallowed")
  check(activeCancellationCount == 1, "active Esc still cancels the session")

  var idleCancellationCount = 0
  let idleConsumed = SystemHotkeyMonitor.handleEscape(
    cancellationInterceptionEnabled: false
  ) {
    idleCancellationCount += 1
  }
  check(!idleConsumed, "idle Esc must pass through to the focused app")
  check(idleCancellationCount == 1, "idle Esc keeps the monitor callback behavior")
}

@main
enum TextInserterHarnessMain {
  static func main() {
    testCancellationBeforePostRestoresOwnedClipboard()
    testPerformanceEventsDescribeOnlyCompletedOrRequestedActions()
    testCancellationAfterPostStopsTimeoutFallback()
    testSecureCancellationCannotResumeAfterLeavingSecureInput()
    testNoReadTimeoutRestoresRatherThanClaimingCopy()
    testClipboardChangeBeforePostNeverPastesUserClipboard()
    testPermissionRevocationBeforePasteDiscardsWithoutCopying()
    testCopyPolicyPreservesCopyOnlyWithoutAccessibility()
    testForeignClipboardAndSupersedingOperationStaySafe()
    testEscapeInterceptionSnapshotsCurrentState()
    print("text inserter harness passed")
  }
}
