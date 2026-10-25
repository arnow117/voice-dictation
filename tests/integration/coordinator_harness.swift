import AppKit
import Foundation
import ShanshuoCore

// Test-only adapters for the production DictationCoordinator. This executable deliberately has no
// AppKit imports, microphone, model, or pasteboard access.
struct SystemFocusSnapshot {
  let target: TargetSnapshot
}

protocol PermissionProviding: AnyObject {
  var microphonePermission: PermissionStatus { get }
  var accessibilityPermission: PermissionStatus { get }
}

protocol FocusInspecting: AnyObject {
  func snapshot() -> SystemFocusSnapshot
  func match(_ expected: SystemFocusSnapshot, _ actual: SystemFocusSnapshot) -> FocusMatch
}

protocol RecordingIndicating: AnyObject {
  var isAvailable: Bool { get }
  func showRecording() -> Bool
  func updateRecording(level: Float, elapsed: TimeInterval, countdown: Int?)
  func showProcessing()
  func showMessage(_ message: String, hideAfter: TimeInterval)
  func showCopyOnlyResult(_ message: String)
  func showBusyFeedback()
  func hide()
}

struct CapturedAudio {
  var samples: [Float]
  let sampleRate: Int
  let duration: TimeInterval

  mutating func erase() {
    samples.withUnsafeMutableBufferPointer { buffer in
      buffer.initialize(repeating: 0)
    }
    samples.removeAll(keepingCapacity: false)
  }
}

protocol AudioCaptureOperation: AnyObject {
  func cancel()
}

protocol AudioCapturing: AnyObject {
  var isAvailable: Bool { get }
  var onInterruption: ((AudioCaptureOperation) -> Void)? { get set }
  var availableInputDevices: [InputDevice] { get }
  var selectedInputDeviceUID: String? { get set }
  func prepare()
  @discardableResult
  func start(
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) -> AudioCaptureOperation
  func stop(_ operation: AudioCaptureOperation, completion: @escaping (CapturedAudio) -> Void)
}

struct InputDevice: Equatable {
  let uid: String
  let name: String
}

protocol ASRRecognizing: AnyObject {
  var isReady: Bool { get }
  func load(completion: @escaping (Result<Void, Error>) -> Void)
  @discardableResult
  func transcribe(
    _ audio: CapturedAudio,
    completion: @escaping (Result<String, Error>) -> Void
  ) -> ASRTranscriptionOperation
  func unload()
}

protocol ASRTranscriptionOperation: AnyObject {
  func cancel()
}

struct InsertionReceipt {
  let targetProcessIdentifier: Int32
  let targetElementIdentifier: String
  let insertedText: String
  let method: String
  let insertedAt: Date
  let expiresAt: Date
}

enum TextInsertionResult {
  case inserted(InsertionReceipt)
  case copied(String)
  case discarded(String)
  case unverified(String)
}

protocol TextInserting: AnyObject {
  @discardableResult
  func insert(
    _ text: String,
    expectedTarget: SystemFocusSnapshot,
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation

  @discardableResult
  func copy(
    _ text: String,
    requiresAccessibility: Bool,
    completion: @escaping (TextInsertionResult) -> Void
  )
    -> TextInsertionOperation
}

protocol HotkeyMonitoring: AnyObject {
  var isShortcutAvailable: Bool { get }
  var onHold: ((HoldShortcut, Bool) -> Void)? { get set }
  var onCancel: (() -> Void)? { get set }
  var onOtherKey: (() -> Void)? { get set }
  var selectedShortcut: HoldShortcut { get set }
  func refresh(accessibilityAuthorized: Bool)
  func setCancellationInterception(_ enabled: Bool)
  func setTriggeringSuspended(_ suspended: Bool)
  func stop()
}

private final class FakePermissions: PermissionProviding {
  var microphonePermission: PermissionStatus = .authorized
  var accessibilityPermission: PermissionStatus = .authorized
}

private final class FakeFocus: FocusInspecting {
  var current: SystemFocusSnapshot
  var matchResult: FocusMatch = .same

  init(_ target: TargetSnapshot) {
    current = SystemFocusSnapshot(target: target)
  }

  func snapshot() -> SystemFocusSnapshot {
    current
  }

  func match(_ expected: SystemFocusSnapshot, _ actual: SystemFocusSnapshot) -> FocusMatch {
    matchResult
  }
}

private final class FakeIndicator: RecordingIndicating {
  var isAvailable = true
  var recordingVisible = true
  var calls: [String] = []
  var messages: [String] = []

  func showRecording() -> Bool {
    calls.append("indicator.recording")
    return recordingVisible
  }

  func updateRecording(level: Float, elapsed: TimeInterval, countdown: Int?) {}
  func showProcessing() { calls.append("indicator.processing") }
  func showMessage(_ message: String, hideAfter: TimeInterval) {
    calls.append("indicator.message")
    messages.append(message)
  }
  func showCopyOnlyResult(_ message: String) { calls.append("indicator.copy-only") }
  func showBusyFeedback() { calls.append("indicator.busy") }
  func hide() { calls.append("indicator.hide") }
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

private final class FakeAudioOperation: AudioCaptureOperation {
  private let onCancel: () -> Void
  private(set) var isCancelled = false

  init(onCancel: @escaping () -> Void) {
    self.onCancel = onCancel
  }

  func cancel() {
    guard !isCancelled else {
      return
    }
    isCancelled = true
    onCancel()
  }
}

private final class FakeAudio: AudioCapturing {
  var isAvailable = true
  var onInterruption: ((AudioCaptureOperation) -> Void)?
  var availableInputDevices: [InputDevice] = [InputDevice(uid: "default", name: "Default")]
  var selectedInputDeviceUID: String?
  var calls: [String] = []
  private(set) var wasCalledOffMainThread = false
  private(set) var cancellationCount = 0
  private var startCompletion: ((AudioCaptureOperation, Result<Void, Error>) -> Void)?
  var defersStopCompletion = false
  private var stopCompletion: ((CapturedAudio) -> Void)?
  private var levelHandler: ((Float) -> Void)?
  private(set) var latestOperation: FakeAudioOperation?

  func prepare() {
    record("audio.prepare")
  }

  @discardableResult
  func start(
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) -> AudioCaptureOperation {
    record("audio.start")
    let operation = FakeAudioOperation { [weak self] in
      self?.cancellationCount += 1
    }
    latestOperation = operation
    startCompletion = completion
    levelHandler = onLevel
    return operation
  }

  func emitLevel(_ level: Float) {
    levelHandler?(level)
  }

  /// Simulates an engine start returning after the main thread has processed a release or Esc.
  func completePendingStart(_ result: Result<Void, Error> = .success(())) {
    guard let operation = latestOperation, let startCompletion else {
      return
    }
    self.startCompletion = nil
    startCompletion(operation, result)
  }

  func stop(_ operation: AudioCaptureOperation, completion: @escaping (CapturedAudio) -> Void) {
    record("audio.stop")
    stopCompletion = completion
    if defersStopCompletion {
      return
    }
    completePendingStop()
  }

  func completePendingStop() {
    let completion = stopCompletion
    stopCompletion = nil
    completion?(
      CapturedAudio(
        samples: Array(repeating: 0.1, count: 6_400),
        sampleRate: 16_000,
        duration: 0.4
      )
    )
  }

  /// Models the production adapter invalidating an active capture before it reports a hardware
  /// configuration change back to the main-thread coordinator.
  func simulateEngineConfigurationChange() {
    guard let operation = latestOperation else {
      return
    }
    operation.cancel()
    onInterruption?(operation)
  }

  private func record(_ call: String) {
    if !Thread.isMainThread {
      wasCalledOffMainThread = true
    }
    calls.append(call)
  }
}

private final class FakeRecognizer: ASRRecognizing {
  final class Operation: ASRTranscriptionOperation {
    fileprivate(set) var isCancelled = false

    func cancel() {
      isCancelled = true
    }
  }

  var isReady = true
  private(set) var transcriptionCount = 0
  private var completion: ((Result<String, Error>) -> Void)?
  private(set) var latestOperation: Operation?

  func load(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func transcribe(
    _ audio: CapturedAudio,
    completion: @escaping (Result<String, Error>) -> Void
  ) -> ASRTranscriptionOperation {
    transcriptionCount += 1
    self.completion = completion
    let operation = Operation()
    latestOperation = operation
    return operation
  }

  func complete(_ result: Result<String, Error>) {
    completion?(result)
  }

  func unload() {}
}

private final class FakeInsertionOperation: TextInsertionOperation {
  private(set) var isCancelled = false

  func cancel() {
    isCancelled = true
  }
}

private final class FakeFormattingOperation: FormattingOperation {
  private(set) var isCancelled = false

  func cancel() {
    isCancelled = true
  }
}

private final class FakeFormatter: FormattingServicing {
  private(set) var requests: [FormattingRequest] = []
  private(set) var operation: FakeFormattingOperation?
  private(set) var authorizationWasDenied = false
  var synchronousResult: FormattingResult?
  private var authorizeSend: (() -> Bool)?
  private var completion: ((FormattingResult) -> Void)?

  @discardableResult
  func format(
    request: FormattingRequest,
    configuration: FormattingConfigurationSnapshot,
    authorizeSend: @escaping () -> Bool,
    completion: @escaping (FormattingResult) -> Void
  ) -> FormattingOperation {
    requests.append(request)
    let operation = FakeFormattingOperation()
    self.operation = operation
    self.authorizeSend = authorizeSend
    self.completion = completion
    if let synchronousResult {
      deliver(synchronousResult)
    }
    return operation
  }

  func deliver(_ result: FormattingResult) {
    guard authorizeSend?() == true else {
      authorizationWasDenied = true
      return
    }
    completion?(result)
  }

  func forceDeliver(_ result: FormattingResult) {
    completion?(result)
  }
}

private final class FakeInserter: TextInserting {
  var insertCalls = 0
  var copyCalls = 0
  private(set) var insertedTexts: [String] = []
  private(set) var copiedTexts: [String] = []
  private(set) var copyRequiresAccessibility: [Bool] = []
  var deferCompletion = false
  private let clock: DictationClock
  private var completion: ((TextInsertionResult) -> Void)?
  private(set) var latestOperation: FakeInsertionOperation?

  init(clock: DictationClock) {
    self.clock = clock
  }

  @discardableResult
  func insert(
    _ text: String,
    expectedTarget: SystemFocusSnapshot,
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation {
    insertCalls += 1
    insertedTexts.append(text)
    let operation = FakeInsertionOperation()
    latestOperation = operation
    if deferCompletion {
      self.completion = completion
    } else {
      completion(receipt(for: text, target: expectedTarget))
    }
    return operation
  }

  @discardableResult
  func copy(
    _ text: String,
    requiresAccessibility: Bool,
    completion: @escaping (TextInsertionResult) -> Void
  )
    -> TextInsertionOperation
  {
    copyCalls += 1
    copiedTexts.append(text)
    copyRequiresAccessibility.append(requiresAccessibility)
    let operation = FakeInsertionOperation()
    latestOperation = operation
    if deferCompletion {
      self.completion = completion
    } else {
      completion(.copied("已复制"))
    }
    return operation
  }

  func completeDeferred(_ result: TextInsertionResult) {
    completion?(result)
  }

  private func receipt(for text: String, target: SystemFocusSnapshot) -> TextInsertionResult {
    let now = clock.now()
    return .inserted(
      InsertionReceipt(
        targetProcessIdentifier: target.target.processIdentifier ?? 0,
        targetElementIdentifier: target.target.elementIdentifier ?? "unknown",
        insertedText: text,
        method: "fake",
        insertedAt: now,
        expiresAt: now.addingTimeInterval(120)
      )
    )
  }
}

private final class FakeHotkeys: HotkeyMonitoring {
  var isShortcutAvailable = true
  var onHold: ((HoldShortcut, Bool) -> Void)?
  var onCancel: (() -> Void)?
  var onOtherKey: (() -> Void)?
  var selectedShortcut: HoldShortcut = .function
  var interceptionStates: [Bool] = []

  func refresh(accessibilityAuthorized: Bool) {}
  func setCancellationInterception(_ enabled: Bool) { interceptionStates.append(enabled) }
  func setTriggeringSuspended(_ suspended: Bool) {}
  func stop() {}
}

private final class ReceiptEndObserver {
  private(set) var ended: [InsertionReceipt] = []

  func record(_ receipt: InsertionReceipt) {
    ended.append(receipt)
  }
}

private final class OutcomeObserver {
  private(set) var outcomes: [SessionOutcome] = []

  func record(_ outcome: SessionOutcome) {
    outcomes.append(outcome)
  }
}

/// Models the native onboarding window's per-press first-responder check. It deliberately does
/// not remember that an earlier attempt was practice: every call must still see the exact control.
private final class FakeLivePracticeControl {
  let target: TargetSnapshot
  var isExactFirstResponder = true
  private(set) var bindingRequests = 0

  init(target: TargetSnapshot) {
    self.target = target
  }

  func binding(for pressTarget: TargetSnapshot, attemptID: UUID) -> PracticeSessionBinding? {
    bindingRequests += 1
    guard isExactFirstResponder else {
      return nil
    }
    let binding = PracticeSessionBinding(target: target, attemptID: attemptID)
    return binding.matches(pressTarget) ? binding : nil
  }
}

private final class ManualClock: DictationClock {
  var date = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func now() -> Date {
    date
  }

  func advance(_ interval: TimeInterval) {
    date = date.addingTimeInterval(interval)
  }
}

private final class ManualTimer: CoordinatorTimer {
  let action: () -> Void
  let repeats: Bool
  private(set) var isCancelled = false

  init(repeats: Bool, action: @escaping () -> Void) {
    self.repeats = repeats
    self.action = action
  }

  func fire() {
    guard !isCancelled else {
      return
    }
    action()
    if !repeats {
      isCancelled = true
    }
  }

  func cancel() {
    isCancelled = true
  }
}

private final class ManualTimerScheduler: CoordinatorTimerScheduling {
  private(set) var timers: [ManualTimer] = []

  func schedule(after interval: TimeInterval, repeats: Bool, _ action: @escaping () -> Void)
    -> CoordinatorTimer
  {
    let timer = ManualTimer(repeats: repeats, action: action)
    timers.append(timer)
    return timer
  }

  func fireRepeatingTimers() {
    for timer in timers where timer.repeats {
      timer.fire()
    }
  }

  func fireAllTimers() {
    for timer in timers {
      timer.fire()
    }
  }
}

private struct Harness {
  let permissions: FakePermissions
  let focus: FakeFocus
  let indicator: FakeIndicator
  let audio: FakeAudio
  let recognizer: FakeRecognizer
  let inserter: FakeInserter
  let formatter: FakeFormatter
  let hotkeys: FakeHotkeys
  let clock: ManualClock
  let timers: ManualTimerScheduler
  let receiptEndObserver: ReceiptEndObserver
  let outcomeObserver: OutcomeObserver
  let performanceRecorder: FakePerformanceRecorder
  let coordinator: DictationCoordinator

  init(formattingEnabled: Bool = false, synchronousFormatting: FormattingResult? = nil) {
    let target = TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 100,
      elementIdentifier: "body",
      isEditable: true,
      isSecure: false
    )
    permissions = FakePermissions()
    focus = FakeFocus(target)
    indicator = FakeIndicator()
    audio = FakeAudio()
    hotkeys = FakeHotkeys()
    clock = ManualClock()
    recognizer = FakeRecognizer()
    inserter = FakeInserter(clock: clock)
    formatter = FakeFormatter()
    formatter.synchronousResult = synchronousFormatting
    timers = ManualTimerScheduler()
    receiptEndObserver = ReceiptEndObserver()
    outcomeObserver = OutcomeObserver()
    performanceRecorder = FakePerformanceRecorder()
    coordinator = DictationCoordinator(
      permissions: permissions,
      focusInspector: focus,
      indicator: indicator,
      audioCapture: audio,
      recognizer: recognizer,
      textInserter: inserter,
      hotkeys: hotkeys,
      formatter: formatter,
      formattingConfiguration: FormattingConfigurationSnapshot(
        enabled: formattingEnabled,
        model: .flash,
        endpoint: .domestic,
        credential: formattingEnabled
          ? FormattingCredentialDescriptor(reference: "test-key", hint: "••••test")
          : nil,
        consentVersion: formattingEnabled ? 1 : nil,
        revision: 1,
        testGeneration: 0
      ),
      clock: clock,
      timerScheduler: timers,
      performanceDiagnostics: performanceRecorder,
      onReceiptEnded: receiptEndObserver.record,
      onSessionOutcome: outcomeObserver.record
    )
  }

  func pressAndStart(shortcut: HoldShortcut = .function) {
    coordinator.hotkeyChanged(shortcut, isPressed: true)
    audio.completePendingStart()
  }

  func pressAndRelease(shortcut: HoldShortcut = .function) {
    pressAndStart(shortcut: shortcut)
    clock.advance(0.35)
    coordinator.hotkeyChanged(shortcut, isPressed: false)
  }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func testOrderingAndInsertion() {
  let harness = Harness()
  harness.pressAndRelease()
  check(
    harness.indicator.calls.first == "indicator.recording",
    "indicator must be visible before asynchronous capture is requested"
  )
  check(
    harness.audio.calls.first == "audio.start", "capture starts only after indicator visibility")
  harness.recognizer.complete(.success("hello"))
  check(harness.inserter.insertCalls == 1, "same editable focus inserts")
  check(harness.coordinator.phase == .idle, "completed session returns idle")
}

private func testPerformanceEventsFollowProductionFacts() {
  let harness = Harness()
  harness.pressAndRelease()
  harness.recognizer.complete(.success("verified insertion"))

  let eventKinds = harness.performanceRecorder.events.map(\.kind)
  check(
    eventKinds == [
      .hotkeyPressed,
      .recordingDisplayCommitted,
      .hotkeyReleased,
      .recognitionDelivered,
      .sessionFinished,
    ],
    "the coordinator records only callback and delivery facts, leaving hardware facts to the adapter"
  )
  guard let sessionID = harness.performanceRecorder.events.first?.sessionID else {
    check(false, "accepted lifecycle events receive a session identifier")
    return
  }
  check(
    harness.performanceRecorder.events.allSatisfy { $0.sessionID == sessionID },
    "accepted lifecycle events retain one random session identifier"
  )
  check(
    harness.performanceRecorder.events.last?.result == .verifiedInsertion,
    "AX-verified insertion is the only verified final outcome"
  )

  let staleHarness = Harness()
  staleHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  staleHarness.coordinator.hotkeyChanged(.function, isPressed: false)
  staleHarness.audio.completePendingStart()
  check(
    staleHarness.performanceRecorder.events.last?.result == .cancelled,
    "cancelled attempts remain in the diagnostic denominator"
  )
}

private func testRejectedHoldKeepsItsOwnDiagnosticAttempt() {
  let harness = Harness()
  harness.pressAndRelease()
  guard let activeAttemptID = harness.performanceRecorder.events.first?.sessionID else {
    check(false, "the active attempt has a diagnostic identifier")
    return
  }
  check(harness.coordinator.phase == .recognizing, "the first attempt remains active during ASR")

  harness.coordinator.hotkeyChanged(.function, isPressed: true)
  guard
    let rejectedPress = harness.performanceRecorder.events.last(where: {
      $0.kind == .hotkeyPressed && $0.sessionID != activeAttemptID
    })
  else {
    check(false, "a busy physical press creates its own diagnostic attempt")
    return
  }
  let rejectedAttemptID = rejectedPress.sessionID
  check(
    harness.performanceRecorder.events.contains {
      $0.kind == .sessionFinished && $0.sessionID == rejectedAttemptID && $0.result == .failed
    },
    "a busy physical press records an explicit failed terminal outcome"
  )

  harness.coordinator.hotkeyChanged(.function, isPressed: false)
  check(
    harness.performanceRecorder.events.filter {
      $0.kind == .hotkeyReleased && $0.sessionID == rejectedAttemptID
    }.count == 1,
    "the rejected physical release belongs to the rejected attempt exactly once"
  )
  check(
    harness.performanceRecorder.events.filter {
      $0.kind == .hotkeyReleased && $0.sessionID == activeAttemptID
    }.count == 1,
    "a later rejected release cannot add a release event to the active attempt"
  )
  check(
    harness.coordinator.phase == .recognizing,
    "a rejected hold never changes the active ASR attempt"
  )

  harness.recognizer.complete(.success("first attempt still completes"))
  check(
    harness.performanceRecorder.events.last?.sessionID == activeAttemptID,
    "the active attempt completes under its original diagnostic identifier"
  )
}

private func testAsyncStartCannotReviveReleasedOrCancelledSession() {
  let releasedHarness = Harness()
  releasedHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  check(releasedHarness.coordinator.phase == .starting, "start waits for the asynchronous engine")
  releasedHarness.coordinator.hotkeyChanged(.function, isPressed: false)
  let releasedOperation = releasedHarness.audio.latestOperation
  releasedHarness.audio.completePendingStart()
  check(releasedOperation?.isCancelled == true, "release invalidates a pending engine start")
  check(
    releasedHarness.audio.cancellationCount == 1, "late hardware start is stopped after release")
  check(
    releasedHarness.coordinator.phase == .idle, "late release completion never enters listening")

  let cancelledHarness = Harness()
  cancelledHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  cancelledHarness.coordinator.cancelFromHotkey()
  let cancelledOperation = cancelledHarness.audio.latestOperation
  cancelledHarness.audio.completePendingStart()
  check(cancelledOperation?.isCancelled == true, "Esc invalidates a pending engine start")
  check(cancelledHarness.audio.cancellationCount == 1, "late hardware start is stopped after Esc")
  check(cancelledHarness.coordinator.phase == .idle, "late Esc completion never enters listening")
}

private func testAudioReconfigurationCancelsAndRecovers() {
  let startingHarness = Harness()
  startingHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  let startingOperation = startingHarness.audio.latestOperation
  startingHarness.audio.simulateEngineConfigurationChange()
  check(
    startingOperation?.isCancelled == true, "configuration change invalidates a starting capture")
  check(startingHarness.coordinator.phase == .idle, "configuration change cancels while starting")
  startingHarness.audio.completePendingStart()
  check(
    startingHarness.coordinator.phase == .idle,
    "late start completion cannot revive a reconfigured capture"
  )

  let listeningHarness = Harness()
  listeningHarness.pressAndStart()
  listeningHarness.audio.emitLevel(0.2)
  listeningHarness.audio.simulateEngineConfigurationChange()
  check(
    listeningHarness.coordinator.phase == .idle,
    "configuration change after the first captured level cancels listening"
  )
  check(
    listeningHarness.recognizer.transcriptionCount == 0,
    "configuration interruption discards audio instead of starting recognition"
  )

  // The production adapter recomputes availability after a device change. A usable replacement
  // device may start a new session, but it can never continue the interrupted one.
  listeningHarness.audio.isAvailable = true
  listeningHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  listeningHarness.audio.completePendingStart()
  check(
    listeningHarness.coordinator.phase == .listening,
    "a later press can recover after availability is refreshed"
  )
  listeningHarness.coordinator.cancelFromHotkey()
}

private func testAutoStopCapturesReleaseTarget() {
  let harness = Harness()
  harness.pressAndStart()
  harness.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 100,
      elementIdentifier: "body-after-auto-stop",
      isEditable: true,
      isSecure: false
    )
  )
  harness.clock.advance(180)
  harness.timers.fireRepeatingTimers()
  check(harness.audio.calls.contains("audio.stop"), "auto-stop must stop capture")
  harness.recognizer.complete(.success("auto stop"))
  check(
    harness.inserter.insertCalls == 1, "auto-stop must insert through a captured release target")
}

private func testIndicatorFailurePreventsCapture() {
  let harness = Harness()
  harness.indicator.recordingVisible = false
  harness.coordinator.hotkeyChanged(.function, isPressed: true)
  check(
    !harness.audio.calls.contains("audio.start"),
    "capture requires a visible indicator"
  )
  check(harness.coordinator.phase == .idle, "indicator failure returns the coordinator to idle")
}

private func testStaleCompletionAndInsertionCancellation() {
  let harness = Harness()
  harness.pressAndRelease()
  harness.coordinator.cancelFromHotkey()
  check(
    harness.recognizer.latestOperation?.isCancelled == true,
    "coordinator cancellation must cancel pending recognition"
  )
  harness.recognizer.complete(.success("stale"))
  check(
    harness.inserter.insertCalls == 0 && harness.inserter.copyCalls == 0,
    "stale ASR completion must not write"
  )

  let insertionHarness = Harness()
  insertionHarness.inserter.deferCompletion = true
  insertionHarness.pressAndRelease()
  insertionHarness.recognizer.complete(.success("pending"))
  let operation = insertionHarness.inserter.latestOperation
  insertionHarness.coordinator.cancelFromHotkey()
  check(operation?.isCancelled == true, "coordinator cancellation must cancel pending insertion")
  insertionHarness.inserter.completeDeferred(.copied("late"))
  check(insertionHarness.coordinator.phase == .idle, "late insertion completion stays inert")
}

private func testCommonModeTimerRunsDuringMenuTracking() {
  _ = NSApplication.shared
  let scheduler = MainRunLoopTimerScheduler()
  var didFire = false
  let timer = scheduler.schedule(after: 0.01, repeats: false) {
    didFire = true
  }
  let deadline = Date().addingTimeInterval(0.5)
  while !didFire, Date() < deadline {
    let trackingMode = RunLoop.Mode.eventTracking
    RunLoop.main.run(mode: trackingMode, before: Date().addingTimeInterval(0.02))
  }
  timer.cancel()
  check(didFire, "a common-mode recording timer must run while a menu tracks events")
}

private func testSecureLatchAndPermissionRevocation() {
  let secureHarness = Harness()
  secureHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  secureHarness.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Safari",
      processIdentifier: 7,
      elementIdentifier: "password",
      isEditable: true,
      isSecure: true
    )
  )
  secureHarness.coordinator.refreshSystemState()
  check(secureHarness.coordinator.phase == .idle, "entering secure input cancels immediately")
  check(secureHarness.audio.cancellationCount == 1, "secure input invalidates pending capture")

  let permissionHarness = Harness()
  permissionHarness.pressAndStart()
  permissionHarness.permissions.microphonePermission = .denied
  permissionHarness.coordinator.refreshSystemState()
  check(
    permissionHarness.coordinator.phase == .idle,
    "permission revocation cancels an active session"
  )

  let accessibilityHarness = Harness()
  accessibilityHarness.pressAndStart()
  accessibilityHarness.permissions.accessibilityPermission = .denied
  accessibilityHarness.coordinator.refreshSystemState()
  check(
    accessibilityHarness.coordinator.phase == .idle,
    "Accessibility revocation cancels a direct-insertion session"
  )

  let microphoneHarness = Harness()
  microphoneHarness.pressAndStart()
  microphoneHarness.audio.isAvailable = false
  microphoneHarness.coordinator.refreshSystemState()
  check(
    microphoneHarness.coordinator.phase == .idle,
    "microphone device loss cancels an active session"
  )
}

private func testCopyOnlyPrepareBusyAndInterruption() {
  let copyHarness = Harness()
  copyHarness.permissions.accessibilityPermission = .denied
  copyHarness.pressAndRelease(shortcut: .copyOnlyControlShiftSpace)
  copyHarness.recognizer.complete(.success("copy this"))
  check(
    copyHarness.inserter.insertCalls == 0 && copyHarness.inserter.copyCalls == 1,
    "copy-only mode must finish without Accessibility permission"
  )
  check(
    copyHarness.indicator.calls.contains("indicator.copy-only"),
    "copy-only result offers repair action")

  let busyHarness = Harness()
  busyHarness.coordinator.prepareAudio()
  busyHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  busyHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  check(
    busyHarness.audio.calls.first == "audio.prepare", "prepare returns through the audio adapter")
  check(
    busyHarness.audio.calls.filter { $0 == "audio.start" }.count == 1,
    "busy press cannot create a second capture"
  )
  check(
    !busyHarness.audio.wasCalledOffMainThread, "the adapter call itself returns quickly on main")
  check(busyHarness.indicator.calls.contains("indicator.busy"), "busy press provides feedback")
  busyHarness.coordinator.cancelForSystemInterruption()
  check(busyHarness.coordinator.phase == .idle, "simulated system interruption cancels")
}

private func testFocusChangeAndNoSpeech() {
  let focusHarness = Harness()
  focusHarness.pressAndRelease()
  focusHarness.focus.matchResult = .changed
  focusHarness.recognizer.complete(.success("move"))
  check(
    focusHarness.inserter.insertCalls == 0 && focusHarness.inserter.copyCalls == 1,
    "changed focus copies"
  )

  let silenceHarness = Harness()
  silenceHarness.pressAndRelease()
  silenceHarness.recognizer.complete(.success("   。"))
  check(
    silenceHarness.inserter.insertCalls == 0 && silenceHarness.inserter.copyCalls == 0,
    "no speech never writes"
  )
}

private func testFormattingSessionOwnershipAndFallbacks() {
  let localAtPressHarness = Harness()
  localAtPressHarness.pressAndRelease()
  localAtPressHarness.coordinator.updateFormattingConfiguration(
    FormattingConfigurationSnapshot(
      enabled: true,
      model: .flash,
      endpoint: .domestic,
      credential: FormattingCredentialDescriptor(reference: "new-key", hint: "••••new"),
      consentVersion: 1,
      revision: 2,
      testGeneration: 0
    )
  )
  localAtPressHarness.recognizer.complete(.success("local at press"))
  check(
    localAtPressHarness.formatter.requests.isEmpty,
    "a session that was local at press does not send after formatting is enabled"
  )
  check(
    localAtPressHarness.inserter.insertedTexts == ["local at press"],
    "a session that was local at press delivers its original text"
  )

  let successHarness = Harness(formattingEnabled: true)
  successHarness.pressAndRelease()
  successHarness.recognizer.complete(.success("第一买牛奶"))
  check(successHarness.coordinator.phase == .formatting, "formatting is an explicit session phase")
  check(
    successHarness.formatter.requests.first?.dictionaryTerms.isEmpty == true,
    "the coordinator sends no dictionary terms before REQ-003"
  )
  successHarness.formatter.deliver(.formatted("1. 买牛奶"))
  check(successHarness.inserter.insertedTexts == ["1. 买牛奶"], "formatted text is delivered")
  check(
    successHarness.outcomeObserver.outcomes.first?.recognizedText == "第一买牛奶"
      && successHarness.outcomeObserver.outcomes.first?.finalText == "1. 买牛奶",
    "one outcome keeps original and formatted text separately"
  )

  let synchronousHarness = Harness(
    formattingEnabled: true,
    synchronousFormatting: .formatted("同步整理文本")
  )
  synchronousHarness.pressAndRelease()
  synchronousHarness.recognizer.complete(.success("同步原文"))
  check(
    synchronousHarness.inserter.insertedTexts == ["同步整理文本"],
    "a synchronous formatter completion is adopted exactly once"
  )

  let configurationChangeHarness = Harness(formattingEnabled: true)
  configurationChangeHarness.pressAndRelease()
  configurationChangeHarness.recognizer.complete(.success("配置变更原文"))
  configurationChangeHarness.coordinator.updateFormattingConfiguration(
    FormattingConfigurationSnapshot(
      enabled: false,
      model: .flash,
      endpoint: .domestic,
      credential: nil,
      consentVersion: nil,
      revision: 2,
      testGeneration: 1
    )
  )
  check(
    configurationChangeHarness.formatter.operation?.isCancelled == true,
    "a changed formatting revision cancels the previous formatter operation"
  )
  check(
    configurationChangeHarness.inserter.insertedTexts == ["配置变更原文"],
    "a changed formatting revision falls back to the original exactly once"
  )
  configurationChangeHarness.formatter.forceDeliver(.formatted("late cloud text"))
  check(
    configurationChangeHarness.inserter.insertedTexts == ["配置变更原文"],
    "late cloud text cannot replace a configuration fallback"
  )

  let timeoutHarness = Harness(formattingEnabled: true)
  timeoutHarness.pressAndRelease()
  timeoutHarness.recognizer.complete(.success("超时原文"))
  timeoutHarness.formatter.deliver(
    .fallback(original: "不可信的回退文本", reason: .deadlineExceeded)
  )
  timeoutHarness.formatter.forceDeliver(.formatted("late success"))
  check(
    timeoutHarness.inserter.insertedTexts == ["超时原文"],
    "a timeout fallback uses the session original and remains the only delivery after a late success"
  )
  check(
    timeoutHarness.indicator.messages.last == "智能整理超时，已插入原文",
    "a timeout fallback gives a fixed cause and a truthful original-text delivery result"
  )

  let networkHarness = Harness(formattingEnabled: true)
  networkHarness.pressAndRelease()
  networkHarness.recognizer.complete(.success("网络原文"))
  networkHarness.formatter.deliver(
    .fallback(original: "网络原文", reason: .transportFailure)
  )
  check(
    networkHarness.indicator.messages.last == "智能整理网络不可用，已插入原文",
    "a network fallback gives a fixed cause without provider response details"
  )

  let authorizationHarness = Harness(formattingEnabled: true)
  authorizationHarness.pressAndRelease()
  authorizationHarness.recognizer.complete(.success("鉴权原文"))
  authorizationHarness.formatter.deliver(
    .fallback(original: "鉴权原文", reason: .authorizationFailed)
  )
  check(
    authorizationHarness.indicator.messages.last == "智能整理 Key 无效，已插入原文",
    "an authorization fallback gives a fixed Key cause and a truthful delivery result"
  )

  let changedFocusHarness = Harness(formattingEnabled: true)
  changedFocusHarness.pressAndRelease()
  changedFocusHarness.focus.matchResult = .changed
  changedFocusHarness.recognizer.complete(.success("焦点变化原文"))
  changedFocusHarness.formatter.deliver(.formatted("焦点变化整理"))
  check(
    changedFocusHarness.inserter.copiedTexts == ["焦点变化整理"]
      && changedFocusHarness.outcomeObserver.outcomes.first?.delivery == .copied,
    "focus changes truthfully copy the formatted result"
  )

  let unverifiedHarness = Harness(formattingEnabled: true)
  unverifiedHarness.inserter.deferCompletion = true
  unverifiedHarness.pressAndRelease()
  unverifiedHarness.recognizer.complete(.success("未验证原文"))
  unverifiedHarness.formatter.deliver(.formatted("未验证整理"))
  unverifiedHarness.inserter.completeDeferred(.unverified("target changed"))
  check(
    unverifiedHarness.outcomeObserver.outcomes.first?.delivery == .unverified,
    "an unverified insertion remains distinct from an inserted or copied result"
  )
}

private func testFormattingCancellationBoundaries() {
  let cancellationHarness = Harness(formattingEnabled: true)
  cancellationHarness.pressAndRelease()
  cancellationHarness.recognizer.complete(.success("Esc 原文"))
  cancellationHarness.coordinator.cancelFromHotkey()
  cancellationHarness.formatter.forceDeliver(.formatted("late Esc text"))
  check(
    cancellationHarness.formatter.operation?.isCancelled == true
      && cancellationHarness.inserter.insertCalls == 0
      && cancellationHarness.outcomeObserver.outcomes.isEmpty,
    "Esc cancels formatting and discards every late effect"
  )

  let secureHarness = Harness(formattingEnabled: true)
  secureHarness.pressAndRelease()
  secureHarness.recognizer.complete(.success("secure 原文"))
  secureHarness.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Safari",
      processIdentifier: 7,
      elementIdentifier: "password",
      isEditable: true,
      isSecure: true
    )
  )
  secureHarness.coordinator.refreshSystemState()
  secureHarness.formatter.forceDeliver(.formatted("late secure text"))
  check(
    secureHarness.formatter.operation?.isCancelled == true
      && secureHarness.outcomeObserver.outcomes.isEmpty,
    "secure input cancels formatting without a fallback delivery"
  )

  let permissionHarness = Harness(formattingEnabled: true)
  permissionHarness.pressAndRelease()
  permissionHarness.recognizer.complete(.success("permission 原文"))
  permissionHarness.permissions.microphonePermission = .denied
  permissionHarness.coordinator.refreshSystemState()
  check(
    permissionHarness.formatter.operation?.isCancelled == true
      && permissionHarness.outcomeObserver.outcomes.isEmpty,
    "microphone revocation cancels a formatting session"
  )

  let secureAtAuthorizationHarness = Harness(formattingEnabled: true)
  secureAtAuthorizationHarness.pressAndRelease()
  secureAtAuthorizationHarness.recognizer.complete(.success("secure authorization 原文"))
  secureAtAuthorizationHarness.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Safari",
      processIdentifier: 8,
      elementIdentifier: "password-at-send",
      isEditable: true,
      isSecure: true
    )
  )
  secureAtAuthorizationHarness.formatter.deliver(.formatted("不应发送的整理文本"))
  secureAtAuthorizationHarness.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 100,
      elementIdentifier: "body",
      isEditable: true,
      isSecure: false
    )
  )
  secureAtAuthorizationHarness.formatter.forceDeliver(.formatted("迟到的整理文本"))
  check(
    secureAtAuthorizationHarness.formatter.operation?.isCancelled == true
      && secureAtAuthorizationHarness.inserter.insertCalls == 0
      && secureAtAuthorizationHarness.inserter.copyCalls == 0
      && secureAtAuthorizationHarness.outcomeObserver.outcomes.isEmpty,
    "a secure target observed during send authorization latches cancellation despite later focus restoration"
  )

  let permissionAtAuthorizationHarness = Harness(formattingEnabled: true)
  permissionAtAuthorizationHarness.pressAndRelease()
  permissionAtAuthorizationHarness.recognizer.complete(.success("permission authorization 原文"))
  permissionAtAuthorizationHarness.permissions.microphonePermission = .denied
  permissionAtAuthorizationHarness.formatter.deliver(.formatted("不应发送的整理文本"))
  permissionAtAuthorizationHarness.permissions.microphonePermission = .authorized
  permissionAtAuthorizationHarness.formatter.forceDeliver(.formatted("迟到的整理文本"))
  check(
    permissionAtAuthorizationHarness.formatter.operation?.isCancelled == true
      && permissionAtAuthorizationHarness.inserter.insertCalls == 0
      && permissionAtAuthorizationHarness.inserter.copyCalls == 0
      && permissionAtAuthorizationHarness.outcomeObserver.outcomes.isEmpty,
    "a permission revoke observed during send authorization terminally cancels despite later restoration"
  )

  let pauseHarness = Harness(formattingEnabled: true)
  pauseHarness.pressAndRelease()
  pauseHarness.recognizer.complete(.success("pause 原文"))
  pauseHarness.coordinator.setPaused(true)
  check(
    pauseHarness.formatter.operation?.isCancelled == true && pauseHarness.outcomeObserver.outcomes.isEmpty,
    "pausing cancels formatting without insertion, copy, or history outcome"
  )

  let modelChangeHarness = Harness(formattingEnabled: true)
  modelChangeHarness.pressAndRelease()
  modelChangeHarness.recognizer.complete(.success("model 原文"))
  modelChangeHarness.coordinator.cancelForModelChange()
  check(
    modelChangeHarness.formatter.operation?.isCancelled == true
      && modelChangeHarness.outcomeObserver.outcomes.isEmpty,
    "an ASR model change cancels formatting without delivery"
  )

  let quotaThrottleHarness = Harness(formattingEnabled: true)
  quotaThrottleHarness.pressAndRelease()
  quotaThrottleHarness.recognizer.complete(.success("首次额度不足原文"))
  quotaThrottleHarness.formatter.deliver(
    .fallback(original: "首次额度不足原文", reason: .paymentRequired)
  )
  check(
    quotaThrottleHarness.indicator.messages.last == "智能整理额度不足，已插入原文",
    "the first quota fallback reports the fixed quota cause"
  )
  quotaThrottleHarness.pressAndRelease()
  quotaThrottleHarness.recognizer.complete(.success("重复额度不足原文"))
  quotaThrottleHarness.formatter.deliver(
    .fallback(original: "重复额度不足原文", reason: .paymentRequired)
  )
  check(
    quotaThrottleHarness.indicator.messages.last == "智能整理不可用，已插入原文",
    "the full quota warning is throttled for one hour"
  )

  let quotaUnverifiedHarness = Harness(formattingEnabled: true)
  quotaUnverifiedHarness.inserter.deferCompletion = true
  quotaUnverifiedHarness.pressAndRelease()
  quotaUnverifiedHarness.recognizer.complete(.success("额度不足原文"))
  quotaUnverifiedHarness.formatter.deliver(
    .fallback(original: "额度不足原文", reason: .paymentRequired)
  )
  quotaUnverifiedHarness.inserter.completeDeferred(.unverified("target changed"))
  check(
    quotaUnverifiedHarness.indicator.messages.last == "智能整理不可用，原文交付未验证",
    "a quota warning never claims copied or inserted text when delivery is unverified"
  )
}

private func testOutcomeAndMicrophoneTestBoundaries() {
  let outcomeHarness = Harness()
  outcomeHarness.pressAndRelease()
  outcomeHarness.recognizer.complete(.success("final text"))
  check(
    outcomeHarness.outcomeObserver.outcomes.count == 1,
    "final copied or inserted text emits one outcome")
  check(
    outcomeHarness.outcomeObserver.outcomes.first?.delivery == .inserted,
    "direct insertion outcome reports actual inserted delivery"
  )
  check(
    outcomeHarness.outcomeObserver.outcomes.first?.finalText == "final text",
    "outcome exposes the final allowed text"
  )

  let practiceHarness = Harness()
  let practiceControl = FakeLivePracticeControl(target: practiceHarness.focus.current.target)
  practiceHarness.coordinator.setOnboardingPracticeBindingProvider { pressTarget, attemptID in
    practiceControl.binding(for: pressTarget, attemptID: attemptID)
  }
  practiceHarness.pressAndRelease()
  practiceHarness.recognizer.complete(.success("practice text"))
  guard case .onboardingPractice? = practiceHarness.outcomeObserver.outcomes.first?.purpose else {
    check(false, "a matching focused practice control tags only its own session")
    return
  }
  guard
    case .onboardingPractice(let binding)? = practiceHarness.outcomeObserver.outcomes.first?.purpose,
    let outcomeSessionID = practiceHarness.outcomeObserver.outcomes.first?.sessionID
  else {
    check(false, "a claimed practice outcome includes an attempt identity")
    return
  }
  check(
    binding.attemptID == outcomeSessionID,
    "the live practice binding uses the coordinator attempt identity for outcome correlation"
  )
  check(
    practiceHarness.outcomeObserver.outcomes.first?.isPersistableInHistory == false,
    "a verified onboarding practice outcome is excluded from history persistence"
  )

  let unrelatedHarness = Harness()
  let unrelatedControl = FakeLivePracticeControl(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 100,
      elementIdentifier: "other-practice-field",
      isEditable: true,
      isSecure: false
    )
  )
  unrelatedHarness.coordinator.setOnboardingPracticeBindingProvider { pressTarget, attemptID in
    unrelatedControl.binding(for: pressTarget, attemptID: attemptID)
  }
  unrelatedHarness.pressAndRelease()
  unrelatedHarness.recognizer.complete(.success("ordinary text"))
  check(
    unrelatedHarness.outcomeObserver.outcomes.first?.purpose == .dictation,
    "an ordinary app result cannot inherit an unmatched practice purpose"
  )

  let cancelledHarness = Harness()
  cancelledHarness.pressAndRelease()
  cancelledHarness.coordinator.cancelFromHotkey()
  cancelledHarness.recognizer.complete(.success("must not retain"))
  check(cancelledHarness.outcomeObserver.outcomes.isEmpty, "cancelled sessions never emit outcomes")

  let testHarness = Harness()
  var levelValues: [Float] = []
  var microphoneResult: MicrophoneTestCompletion?
  let started = testHarness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { levelValues.append($0) },
    completion: { microphoneResult = $0 }
  )
  check(started, "microphone test starts only through the coordinator")
  check(
    testHarness.coordinator.phase == .idle && testHarness.coordinator.isMicrophoneTestActive,
    "microphone test reserves audio while keeping dictation idle"
  )
  testHarness.audio.completePendingStart()
  testHarness.audio.emitLevel(0.02)
  testHarness.timers.fireAllTimers()
  check(microphoneResult == .detectedSound, "microphone test requires a real audio level")
  check(levelValues == [0.02], "microphone test forwards the observed level only in memory")

  let exclusiveHarness = Harness()
  _ = exclusiveHarness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { _ in },
    completion: { _ in }
  )
  exclusiveHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  check(
    exclusiveHarness.audio.calls.filter { $0 == "audio.start" }.count == 1,
    "dictation cannot start while a microphone test owns the capture"
  )
  exclusiveHarness.coordinator.cancelForSystemInterruption()
  check(
    !exclusiveHarness.coordinator.isMicrophoneTestActive,
    "system interruption cancels microphone testing")

  let closeHarness = Harness()
  var closeResult: MicrophoneTestCompletion?
  _ = closeHarness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { _ in },
    completion: { closeResult = $0 }
  )
  let pendingTestStart = closeHarness.audio.latestOperation
  closeHarness.coordinator.endMicrophoneTest()
  closeHarness.audio.completePendingStart()
  check(
    pendingTestStart?.isCancelled == true, "closing microphone test cancels a queued engine start")
  check(
    closeResult == .cancelled,
    "closing microphone test reports cancellation without retaining audio")

  let delayedStopHarness = Harness()
  delayedStopHarness.audio.defersStopCompletion = true
  var delayedStopResult: MicrophoneTestCompletion?
  _ = delayedStopHarness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { _ in },
    completion: { delayedStopResult = $0 }
  )
  delayedStopHarness.audio.completePendingStart()
  delayedStopHarness.coordinator.endMicrophoneTest()
  check(
    delayedStopHarness.coordinator.isMicrophoneTestActive,
    "the coordinator retains a stopping microphone-test operation until the engine queue returns"
  )
  let overlappingStart = delayedStopHarness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { _ in },
    completion: { _ in }
  )
  check(!overlappingStart, "a queued engine stop prevents an overlapping capture")
  delayedStopHarness.audio.completePendingStop()
  check(delayedStopResult == .cancelled, "a queued cancellation reports only after stop completes")
  let restarted = delayedStopHarness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { _ in },
    completion: { _ in }
  )
  check(restarted, "a completed stop releases ownership for the next microphone test")

  let naturalStopHarness = Harness()
  naturalStopHarness.audio.defersStopCompletion = true
  var naturalStopResult: MicrophoneTestCompletion?
  _ = naturalStopHarness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { _ in },
    completion: { naturalStopResult = $0 }
  )
  naturalStopHarness.audio.completePendingStart()
  naturalStopHarness.timers.fireAllTimers()
  let naturalStopOperation = naturalStopHarness.audio.latestOperation
  check(
    naturalStopHarness.coordinator.isMicrophoneTestActive,
    "a natural test timeout retains the stopping operation until the queued stop completes"
  )
  naturalStopHarness.coordinator.cancelForSystemInterruption()
  check(
    naturalStopOperation?.isCancelled == true,
    "a later interruption still cancels an operation that is waiting for queued stop cleanup"
  )
  naturalStopHarness.audio.completePendingStop()
  check(
    naturalStopResult == .cancelled,
    "cancelling during queued cleanup prevents a natural test result from reviving the closed test"
  )
}

private func testPracticeBindingIsLiveForEveryRetry() {
  func makePracticeHarness() -> (Harness, FakeLivePracticeControl) {
    let harness = Harness()
    let control = FakeLivePracticeControl(target: harness.focus.current.target)
    harness.coordinator.setOnboardingPracticeBindingProvider { pressTarget, attemptID in
      control.binding(for: pressTarget, attemptID: attemptID)
    }
    return (harness, control)
  }

  func checkPracticeOutcome(_ harness: Harness, _ message: String) {
    guard case .onboardingPractice? = harness.outcomeObserver.outcomes.last?.purpose else {
      check(false, message)
      return
    }
    check(
      harness.outcomeObserver.outcomes.last?.isPersistableInHistory == false,
      "practice retries remain outside the history boundary"
    )
  }

  let shortPressHarness = makePracticeHarness()
  shortPressHarness.0.pressAndStart()
  shortPressHarness.0.clock.advance(0.1)
  shortPressHarness.0.coordinator.hotkeyChanged(.function, isPressed: false)
  shortPressHarness.0.pressAndRelease()
  shortPressHarness.0.recognizer.complete(.success("retry after short press"))
  checkPracticeOutcome(shortPressHarness.0, "short press retry receives a fresh practice purpose")
  check(
    shortPressHarness.1.bindingRequests == 2,
    "short press and retry each perform a live practice check"
  )

  let escapeHarness = makePracticeHarness()
  escapeHarness.0.pressAndStart()
  escapeHarness.0.coordinator.cancelFromHotkey()
  escapeHarness.0.pressAndRelease()
  escapeHarness.0.recognizer.complete(.success("retry after escape"))
  checkPracticeOutcome(escapeHarness.0, "Esc retry receives a fresh practice purpose")

  let silenceHarness = makePracticeHarness()
  silenceHarness.0.pressAndRelease()
  silenceHarness.0.recognizer.complete(.success("   。"))
  check(
    silenceHarness.0.outcomeObserver.outcomes.isEmpty,
    "silent practice attempt creates no retainable outcome"
  )
  silenceHarness.0.pressAndRelease()
  silenceHarness.0.recognizer.complete(.success("retry after silence"))
  checkPracticeOutcome(silenceHarness.0, "silent retry receives a fresh practice purpose")

  let otherControlHarness = makePracticeHarness()
  otherControlHarness.0.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 100,
      elementIdentifier: "ordinary-control",
      isEditable: true,
      isSecure: false
    )
  )
  otherControlHarness.0.pressAndRelease()
  otherControlHarness.0.recognizer.complete(.success("ordinary control"))
  check(
    otherControlHarness.0.outcomeObserver.outcomes.last?.purpose == .dictation,
    "another control in the same app cannot claim practice"
  )

  let otherWindowHarness = makePracticeHarness()
  otherWindowHarness.0.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 101,
      elementIdentifier: "body",
      isEditable: true,
      isSecure: false
    )
  )
  otherWindowHarness.0.pressAndRelease()
  otherWindowHarness.0.recognizer.complete(.success("other window"))
  check(
    otherWindowHarness.0.outcomeObserver.outcomes.last?.purpose == .dictation,
    "another window cannot claim practice"
  )

  let copyOnlyHarness = makePracticeHarness()
  copyOnlyHarness.0.permissions.accessibilityPermission = .denied
  copyOnlyHarness.0.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 100,
      elementIdentifier: nil,
      isEditable: false,
      isSecure: false
    )
  )
  copyOnlyHarness.0.pressAndRelease(shortcut: .copyOnlyControlShiftSpace)
  copyOnlyHarness.0.recognizer.complete(.success("copy-only practice"))
  checkPracticeOutcome(
    copyOnlyHarness.0,
    "copy-only practice uses the native responder check when Accessibility has no identifier"
  )
  check(
    copyOnlyHarness.0.outcomeObserver.outcomes.last?.delivery == .copied,
    "copy-only practice records copied delivery for its explicit paste proof"
  )
}

private func testReceiptEndsOnExpiryFocusChangeAndNewPress() {
  let expiryHarness = Harness()
  expiryHarness.pressAndRelease()
  expiryHarness.recognizer.complete(.success("receipt"))
  expiryHarness.clock.advance(121)
  expiryHarness.coordinator.refreshSystemState()
  check(expiryHarness.receiptEndObserver.ended.count == 1, "receipt expires after two minutes")

  let focusHarness = Harness()
  focusHarness.pressAndRelease()
  focusHarness.recognizer.complete(.success("receipt"))
  focusHarness.focus.current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 100,
      elementIdentifier: "other-body",
      isEditable: true,
      isSecure: false
    )
  )
  focusHarness.focus.matchResult = .changed
  focusHarness.coordinator.refreshSystemState()
  check(focusHarness.receiptEndObserver.ended.count == 1, "receipt ends after leaving its focus")

  let nextPressHarness = Harness()
  nextPressHarness.pressAndRelease()
  nextPressHarness.recognizer.complete(.success("receipt"))
  nextPressHarness.coordinator.hotkeyChanged(.function, isPressed: true)
  check(nextPressHarness.receiptEndObserver.ended.count == 1, "new press ends the prior receipt")
  nextPressHarness.coordinator.cancelFromHotkey()
}

private func testDirectSessionCancelsWhenAccessibilityIsRevoked() {
  let harness = Harness()
  let customControlShiftSpace = HoldShortcut.custom(
    HotkeyDescriptor(keyCode: 49, modifiers: [.control, .shift])
  )
  harness.pressAndStart(shortcut: customControlShiftSpace)
  check(
    harness.coordinator.phase == .listening, "custom Ctrl-Shift-Space starts while AX is authorized"
  )

  harness.permissions.accessibilityPermission = .denied
  harness.coordinator.refreshSystemState()
  check(
    harness.coordinator.phase == .idle,
    "a direct session captures its mode and cancels after Accessibility is revoked"
  )
  check(harness.audio.cancellationCount == 1, "revocation cancels the active direct capture")
}

private func testLatePermissionRevocationDiscardsWithoutOutcome() {
  let microphoneRecognitionHarness = Harness()
  microphoneRecognitionHarness.pressAndRelease()
  microphoneRecognitionHarness.permissions.microphonePermission = .denied
  microphoneRecognitionHarness.recognizer.complete(.success("late microphone recognition"))
  check(
    microphoneRecognitionHarness.inserter.insertCalls == 0
      && microphoneRecognitionHarness.inserter.copyCalls == 0,
    "microphone revocation before ASR delivery must not start a text effect"
  )
  check(
    microphoneRecognitionHarness.outcomeObserver.outcomes.isEmpty,
    "microphone revocation before ASR delivery has no history-eligible outcome"
  )

  let accessibilityHarness = Harness()
  accessibilityHarness.pressAndRelease()
  accessibilityHarness.permissions.accessibilityPermission = .denied
  accessibilityHarness.recognizer.complete(.success("late Accessibility revocation"))
  check(
    accessibilityHarness.inserter.insertCalls == 0 && accessibilityHarness.inserter.copyCalls == 0,
    "a direct session must discard instead of copying when Accessibility is revoked before ASR delivery"
  )
  check(
    accessibilityHarness.outcomeObserver.outcomes.isEmpty,
    "a discarded direct result never becomes a history-eligible outcome"
  )

  let microphoneHarness = Harness()
  microphoneHarness.inserter.deferCompletion = true
  microphoneHarness.pressAndRelease()
  microphoneHarness.recognizer.complete(.success("late microphone revocation"))
  check(
    microphoneHarness.inserter.insertCalls == 1,
    "the direct insertion starts while permission exists")
  microphoneHarness.permissions.microphonePermission = .denied
  microphoneHarness.inserter.completeDeferred(
    .inserted(
      InsertionReceipt(
        targetProcessIdentifier: 100,
        targetElementIdentifier: "body",
        insertedText: "late microphone revocation",
        method: "fake",
        insertedAt: microphoneHarness.clock.now(),
        expiresAt: microphoneHarness.clock.now().addingTimeInterval(120)
      )
    ))
  check(
    microphoneHarness.outcomeObserver.outcomes.isEmpty,
    "a late insertion completion after microphone revocation must not publish an outcome"
  )

  let accessibilityCompletionHarness = Harness()
  accessibilityCompletionHarness.inserter.deferCompletion = true
  accessibilityCompletionHarness.pressAndRelease()
  accessibilityCompletionHarness.recognizer.complete(.success("late Accessibility completion"))
  check(
    accessibilityCompletionHarness.inserter.insertCalls == 1,
    "the direct insertion starts before Accessibility is revoked"
  )
  accessibilityCompletionHarness.permissions.accessibilityPermission = .denied
  accessibilityCompletionHarness.inserter.completeDeferred(.unverified("late paste request"))
  check(
    accessibilityCompletionHarness.outcomeObserver.outcomes.isEmpty,
    "a late insertion completion after Accessibility revocation must not publish an outcome"
  )

  let focusChangeHarness = Harness()
  focusChangeHarness.inserter.deferCompletion = true
  focusChangeHarness.pressAndRelease()
  focusChangeHarness.focus.matchResult = .changed
  focusChangeHarness.recognizer.complete(.success("direct fallback copy"))
  check(
    focusChangeHarness.inserter.copyCalls == 1, "focus change uses the direct session copy fallback"
  )
  check(
    focusChangeHarness.inserter.copyRequiresAccessibility == [true],
    "a direct-session copy fallback retains its Accessibility requirement"
  )
  focusChangeHarness.permissions.accessibilityPermission = .denied
  focusChangeHarness.inserter.completeDeferred(.copied("late copy"))
  check(
    focusChangeHarness.outcomeObserver.outcomes.isEmpty,
    "a direct fallback copy must discard if Accessibility is revoked before completion"
  )

  let copyOnlyHarness = Harness()
  copyOnlyHarness.permissions.accessibilityPermission = .denied
  copyOnlyHarness.pressAndRelease(shortcut: .copyOnlyControlShiftSpace)
  copyOnlyHarness.recognizer.complete(.success("copy-only remains allowed"))
  check(
    copyOnlyHarness.inserter.copyCalls == 1,
    "a copy-only session remains valid without Accessibility")
  check(
    copyOnlyHarness.inserter.copyRequiresAccessibility == [false],
    "a copy-only session explicitly permits its Accessibility-free clipboard write"
  )
  check(
    copyOnlyHarness.outcomeObserver.outcomes.count == 1,
    "the valid copy-only result remains eligible for its explicit copied outcome"
  )
}

private func testNaturalMicrophoneTestStopBlocksDictationUntilCompletion() {
  let harness = Harness()
  harness.audio.defersStopCompletion = true
  _ = harness.coordinator.beginMicrophoneTest(
    indicatorVisible: true,
    onLevel: { _ in },
    completion: { _ in }
  )
  harness.audio.completePendingStart()
  harness.timers.fireAllTimers()

  let startsBeforeHeldHotkey = harness.audio.calls.filter { $0 == "audio.start" }.count
  harness.coordinator.hotkeyChanged(.function, isPressed: true)
  check(
    harness.audio.calls.filter { $0 == "audio.start" }.count == startsBeforeHeldHotkey,
    "a natural microphone-test stop keeps the audio adapter exclusive until its queued completion"
  )

  harness.audio.completePendingStop()
  harness.coordinator.hotkeyChanged(.function, isPressed: true)
  check(
    harness.audio.calls.filter { $0 == "audio.start" }.count == startsBeforeHeldHotkey + 1,
    "dictation may start after the microphone-test stop finishes"
  )
  harness.coordinator.cancelFromHotkey()
}

private func testHotkeyRebindCancelsHeldSession() {
  let harness = Harness()
  harness.pressAndStart()
  harness.coordinator.cancelForHotkeyRebind()
  harness.coordinator.hotkeyChanged(.function, isPressed: false)
  check(harness.coordinator.phase == .idle, "changing a binding cancels the old held session")
  check(harness.audio.cancellationCount == 1, "rebinding invalidates the active audio operation")
  check(
    harness.recognizer.transcriptionCount == 0, "an old key-up cannot recognize after rebinding")
}

private func testClosingPracticeCancelsOnlyTheClaimedSession() {
  func configurePractice(_ harness: Harness) {
    harness.coordinator.setOnboardingPracticeBindingProvider { target, attemptID in
      PracticeSessionBinding(target: target, attemptID: attemptID)
    }
  }

  let recordingHarness = Harness()
  configurePractice(recordingHarness)
  recordingHarness.pressAndStart()
  recordingHarness.coordinator.cancelOnboardingPracticeSession()
  check(
    recordingHarness.audio.cancellationCount == 1, "closing practice cancels an active recording")
  recordingHarness.audio.completePendingStart()
  check(
    recordingHarness.outcomeObserver.outcomes.isEmpty, "late recording start cannot revive practice"
  )

  let recognitionHarness = Harness()
  configurePractice(recognitionHarness)
  recognitionHarness.pressAndRelease()
  recognitionHarness.coordinator.cancelOnboardingPracticeSession()
  recognitionHarness.recognizer.complete(.success("late practice recognition"))
  check(
    recognitionHarness.outcomeObserver.outcomes.isEmpty,
    "closing practice discards an in-flight recognition result"
  )

  let insertionHarness = Harness()
  configurePractice(insertionHarness)
  insertionHarness.inserter.deferCompletion = true
  insertionHarness.pressAndRelease()
  insertionHarness.recognizer.complete(.success("late practice insertion"))
  let pendingInsertion = insertionHarness.inserter.latestOperation
  insertionHarness.coordinator.cancelOnboardingPracticeSession()
  insertionHarness.inserter.completeDeferred(.copied("late clipboard"))
  check(pendingInsertion?.isCancelled == true, "closing practice cancels a pending insertion")
  check(
    insertionHarness.outcomeObserver.outcomes.isEmpty,
    "late insertion completion cannot create a practice outcome or history candidate"
  )

  insertionHarness.inserter.deferCompletion = false
  insertionHarness.pressAndRelease()
  insertionHarness.recognizer.complete(.success("fresh practice"))
  guard case .onboardingPractice? = insertionHarness.outcomeObserver.outcomes.last?.purpose else {
    check(false, "a newly opened practice control receives only its own fresh outcome")
    return
  }
  check(
    insertionHarness.outcomeObserver.outcomes.count == 1,
    "reopening practice does not resurrect a prior attempt"
  )
}

@main
enum CoordinatorHarnessMain {
  static func main() {
    testOrderingAndInsertion()
    testPerformanceEventsFollowProductionFacts()
    testRejectedHoldKeepsItsOwnDiagnosticAttempt()
    testAsyncStartCannotReviveReleasedOrCancelledSession()
    testAudioReconfigurationCancelsAndRecovers()
    testAutoStopCapturesReleaseTarget()
    testIndicatorFailurePreventsCapture()
    testStaleCompletionAndInsertionCancellation()
    testSecureLatchAndPermissionRevocation()
    testCopyOnlyPrepareBusyAndInterruption()
    testFocusChangeAndNoSpeech()
    testFormattingSessionOwnershipAndFallbacks()
    testFormattingCancellationBoundaries()
    testOutcomeAndMicrophoneTestBoundaries()
    testPracticeBindingIsLiveForEveryRetry()
    testReceiptEndsOnExpiryFocusChangeAndNewPress()
    testDirectSessionCancelsWhenAccessibilityIsRevoked()
    testLatePermissionRevocationDiscardsWithoutOutcome()
    testNaturalMicrophoneTestStopBlocksDictationUntilCompletion()
    testHotkeyRebindCancelsHeldSession()
    testClosingPracticeCancelsOnlyTheClaimedSession()
    testCommonModeTimerRunsDuringMenuTracking()
    print("coordinator harness passed")
  }
}
