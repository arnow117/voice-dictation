import AppKit
import Foundation
import ShanshuoCore

// Test-only adapters for the production DictationCoordinator. This executable deliberately has no
// AppKit imports, microphone, model, or pasteboard access.
struct SystemFocusSnapshot {
  let target: TargetSnapshot
}

enum HoldShortcut: Equatable {
  case function
  case rightOption
  case copyOnlyControlShiftSpace
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
  func prepare()
  @discardableResult
  func start(
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) -> AudioCaptureOperation
  func stop(_ operation: AudioCaptureOperation, completion: @escaping (CapturedAudio) -> Void)
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
  func copy(_ text: String, completion: @escaping (TextInsertionResult) -> Void)
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

  func showRecording() -> Bool {
    calls.append("indicator.recording")
    return recordingVisible
  }

  func updateRecording(level: Float, elapsed: TimeInterval, countdown: Int?) {}
  func showProcessing() { calls.append("indicator.processing") }
  func showMessage(_ message: String, hideAfter: TimeInterval) { calls.append("indicator.message") }
  func showCopyOnlyResult(_ message: String) { calls.append("indicator.copy-only") }
  func showBusyFeedback() { calls.append("indicator.busy") }
  func hide() { calls.append("indicator.hide") }
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
  var calls: [String] = []
  private(set) var wasCalledOffMainThread = false
  private(set) var cancellationCount = 0
  private var startCompletion: ((AudioCaptureOperation, Result<Void, Error>) -> Void)?
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
    return operation
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
    completion(
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

private final class FakeInserter: TextInserting {
  var insertCalls = 0
  var copyCalls = 0
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
  func copy(_ text: String, completion: @escaping (TextInsertionResult) -> Void)
    -> TextInsertionOperation
  {
    copyCalls += 1
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
  func stop() {}
}

private final class ReceiptEndObserver {
  private(set) var ended: [InsertionReceipt] = []

  func record(_ receipt: InsertionReceipt) {
    ended.append(receipt)
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
}

private struct Harness {
  let permissions: FakePermissions
  let focus: FakeFocus
  let indicator: FakeIndicator
  let audio: FakeAudio
  let recognizer: FakeRecognizer
  let inserter: FakeInserter
  let hotkeys: FakeHotkeys
  let clock: ManualClock
  let timers: ManualTimerScheduler
  let receiptEndObserver: ReceiptEndObserver
  let coordinator: DictationCoordinator

  init() {
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
    timers = ManualTimerScheduler()
    receiptEndObserver = ReceiptEndObserver()
    coordinator = DictationCoordinator(
      permissions: permissions,
      focusInspector: focus,
      indicator: indicator,
      audioCapture: audio,
      recognizer: recognizer,
      textInserter: inserter,
      hotkeys: hotkeys,
      clock: clock,
      timerScheduler: timers,
      onReceiptEnded: receiptEndObserver.record
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
  listeningHarness.audio.simulateEngineConfigurationChange()
  check(listeningHarness.coordinator.phase == .idle, "configuration change cancels while listening")
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

@main
enum CoordinatorHarnessMain {
  static func main() {
    testOrderingAndInsertion()
    testAsyncStartCannotReviveReleasedOrCancelledSession()
    testAudioReconfigurationCancelsAndRecovers()
    testAutoStopCapturesReleaseTarget()
    testIndicatorFailurePreventsCapture()
    testStaleCompletionAndInsertionCancellation()
    testSecureLatchAndPermissionRevocation()
    testCopyOnlyPrepareBusyAndInterruption()
    testFocusChangeAndNoSpeech()
    testReceiptEndsOnExpiryFocusChangeAndNewPress()
    testCommonModeTimerRunsDuringMenuTracking()
    print("coordinator harness passed")
  }
}
