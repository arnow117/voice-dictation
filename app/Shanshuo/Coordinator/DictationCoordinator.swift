import Foundation
import ShanshuoCore

protocol DictationClock {
  func now() -> Date
}

protocol CoordinatorTimer: AnyObject {
  func cancel()
}

protocol CoordinatorTimerScheduling {
  func schedule(after interval: TimeInterval, repeats: Bool, _ action: @escaping () -> Void)
    -> CoordinatorTimer
}

/// A narrowly scoped claim that an onboarding practice session began in the app's dedicated
/// practice control. It prevents ordinary results in another Shanshuo window from being treated
/// as practice, and keeps practice text out of the persisted history boundary.
struct PracticeSessionBinding: Equatable {
  let target: TargetSnapshot
  let attemptID: UUID

  init(target: TargetSnapshot, attemptID: UUID = UUID()) {
    self.target = target
    self.attemptID = attemptID
  }

  func matches(_ candidate: TargetSnapshot) -> Bool {
    guard target.bundleIdentifier == candidate.bundleIdentifier,
      target.processIdentifier == candidate.processIdentifier
    else {
      return false
    }
    if let candidateIdentifier = candidate.elementIdentifier {
      return target.elementIdentifier == candidateIdentifier
    }
    // Without Accessibility, the platform cannot expose an AX identifier. The onboarding window
    // performs a fresh native first-responder check for every press before it supplies a binding.
    // That preserves the practice boundary while the copy-only fallback remains usable.
    return true
  }
}

enum SessionPurpose: Equatable {
  case dictation
  case onboardingPractice(PracticeSessionBinding)
}

/// The only result that downstream features may retain. It is emitted once, after the coordinator
/// has finished its permission, secure-input, focus, and insertion checks. Cancelled sessions never
/// construct this value, so history and onboarding do not need to infer safety from UI copy.
struct SessionOutcome {
  enum Delivery: String {
    case inserted
    case copied
    case unverified
  }

  let sessionID: UUID
  let recognizedText: String
  let finalText: String
  let delivery: Delivery
  let target: TargetSnapshot
  let purpose: SessionPurpose
  let createdAt: Date

  var isPersistableInHistory: Bool {
    if case .onboardingPractice = purpose {
      return false
    }
    return true
  }
}

enum MicrophoneTestCompletion: Equatable {
  case detectedSound
  case noSound
  case cancelled
  case unavailable
}

private final class SystemDictationClock: DictationClock {
  func now() -> Date {
    Date()
  }
}

private final class MainRunLoopTimer: CoordinatorTimer {
  var timer: Timer?

  func cancel() {
    timer?.invalidate()
    timer = nil
  }

  deinit {
    cancel()
  }
}

final class MainRunLoopTimerScheduler: CoordinatorTimerScheduling {
  func schedule(after interval: TimeInterval, repeats: Bool, _ action: @escaping () -> Void)
    -> CoordinatorTimer
  {
    let task = MainRunLoopTimer()
    let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
      action()
    }
    RunLoop.main.add(timer, forMode: .common)
    task.timer = timer
    return task
  }
}

/// The sole owner of a dictation session. All public entry points run on the main thread; system
/// adapters return to this object before changing state. Generation matching makes delayed capture,
/// recognition, and insertion results harmless after cancellation, sleep, permission revocation, or
/// a new session.
final class DictationCoordinator {
  private enum SessionInsertionMode {
    case directInsertion
    case copyOnly
  }

  private struct ActiveSession {
    let id: UUID
    let generation: SessionGeneration
    let startedAt: Date
    let pressTarget: SystemFocusSnapshot
    var releaseTarget: SystemFocusSnapshot?
    let shortcut: HoldShortcut
    let insertionMode: SessionInsertionMode
    let purpose: SessionPurpose
  }

  private struct RetainedReceipt {
    let receipt: InsertionReceipt
    let target: SystemFocusSnapshot
  }

  private let permissions: PermissionProviding
  private let focusInspector: FocusInspecting
  private let indicator: RecordingIndicating
  private let audioCapture: AudioCapturing
  private let recognizer: ASRRecognizing
  private let textInserter: TextInserting
  private let hotkeys: HotkeyMonitoring
  private let clock: DictationClock
  private let timerScheduler: CoordinatorTimerScheduling
  private let performanceDiagnostics: PerformanceEventRecording
  private let onReceiptEnded: (InsertionReceipt) -> Void
  private let onSessionOutcome: (SessionOutcome) -> Void
  private var activeSession: ActiveSession?
  /// The event tap only supplies press and release edges. Retain the generated ID for each held
  /// trigger so a rejected press cannot later release whichever session happens to be active.
  private var heldHotkeyAttempts: [(shortcut: HoldShortcut, id: UUID)] = []
  private var recordingTimer: CoordinatorTimer?
  private var receiptExpiryTimer: CoordinatorTimer?
  private var pendingInsertion: TextInsertionOperation?
  private var pendingRecognition: ASRTranscriptionOperation?
  private var audioOperation: AudioCaptureOperation?
  private var retainedReceipt: RetainedReceipt?
  private var microphoneTestOperation: AudioCaptureOperation?
  private var microphoneTestStoppingOperation: AudioCaptureOperation?
  private var microphoneTestGeneration: UInt64 = 0
  private var microphoneTestStoppingGeneration: UInt64?
  private var microphoneTestStoppingCompletion: ((MicrophoneTestCompletion) -> Void)?
  private var microphoneTestStoppingResult: MicrophoneTestCompletion?
  private var microphoneTestTimer: CoordinatorTimer?
  private var microphoneTestHasSound = false
  private var microphoneTestLevelHandler: ((Float) -> Void)?
  private var microphoneTestCompletion: ((MicrophoneTestCompletion) -> Void)?
  private var generation = SessionGeneration()
  private(set) var phase: DictationPhase = .idle
  private(set) var isPaused = false
  private var secureInputLatched = false
  /// The onboarding window supplies a binding only while its exact native practice control is
  /// visible and first responder. Querying this on every press avoids carrying a stale "armed"
  /// exception across a cancelled, silent, or short practice attempt.
  private var onboardingPracticeBindingProvider:
    ((TargetSnapshot, UUID) -> PracticeSessionBinding?)?

  init(
    permissions: PermissionProviding,
    focusInspector: FocusInspecting,
    indicator: RecordingIndicating,
    audioCapture: AudioCapturing,
    recognizer: ASRRecognizing,
    textInserter: TextInserting,
    hotkeys: HotkeyMonitoring,
    clock: DictationClock = SystemDictationClock(),
    timerScheduler: CoordinatorTimerScheduling = MainRunLoopTimerScheduler(),
    performanceDiagnostics: PerformanceEventRecording = NoopPerformanceEventRecorder(),
    onReceiptEnded: @escaping (InsertionReceipt) -> Void = { _ in },
    onSessionOutcome: @escaping (SessionOutcome) -> Void = { _ in }
  ) {
    self.permissions = permissions
    self.focusInspector = focusInspector
    self.indicator = indicator
    self.audioCapture = audioCapture
    self.recognizer = recognizer
    self.textInserter = textInserter
    self.hotkeys = hotkeys
    self.clock = clock
    self.timerScheduler = timerScheduler
    self.performanceDiagnostics = performanceDiagnostics
    self.onReceiptEnded = onReceiptEnded
    self.onSessionOutcome = onSessionOutcome
    self.audioCapture.onInterruption = { [weak self] operation in
      self?.handleAudioInterruption(operation)
    }
  }

  func setPaused(_ paused: Bool) {
    requireMainThread()
    isPaused = paused
    if paused {
      cancel(message: "语音输入已暂停")
    }
  }

  var isMicrophoneTestActive: Bool {
    microphoneTestOperation != nil || microphoneTestStoppingOperation != nil
  }

  /// Starts a bounded, memory-only microphone level check. The caller must first make its test
  /// indicator visible; this method deliberately never begins an invisible capture. A test shares
  /// the same exclusive audio adapter as dictation and therefore cannot race a dictation session.
  @discardableResult
  func beginMicrophoneTest(
    indicatorVisible: Bool,
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (MicrophoneTestCompletion) -> Void
  ) -> Bool {
    requireMainThread()
    guard indicatorVisible,
      phase == .idle,
      microphoneTestOperation == nil,
      microphoneTestStoppingOperation == nil,
      !isPaused,
      permissions.microphonePermission.isAuthorized,
      audioCapture.isAvailable,
      !focusInspector.snapshot().target.isSecure
    else {
      completion(.unavailable)
      return false
    }

    microphoneTestHasSound = false
    microphoneTestGeneration &+= 1
    microphoneTestLevelHandler = onLevel
    microphoneTestCompletion = completion
    let operation = audioCapture.start(
      onLevel: { [weak self] level in
        self?.handleMicrophoneTestLevel(level)
      },
      completion: { [weak self] operation, result in
        self?.microphoneTestDidStart(operation, result: result)
      }
    )
    microphoneTestOperation = operation
    return true
  }

  func endMicrophoneTest() {
    requireMainThread()
    finishMicrophoneTest(cancelled: true)
  }

  /// Installs the onboarding-owned live practice check. The provider is asked for every new
  /// press with the coordinator's new attempt ID, rather than retaining a previous focus snapshot
  /// after a practice attempt finishes.
  func setOnboardingPracticeBindingProvider(
    _ provider: @escaping (TargetSnapshot, UUID) -> PracticeSessionBinding?
  ) {
    requireMainThread()
    onboardingPracticeBindingProvider = provider
  }

  func clearOnboardingPracticeBindingProvider() {
    requireMainThread()
    onboardingPracticeBindingProvider = nil
  }

  /// The audio adapter owns AVAudioEngine on its dedicated serial queue. The coordinator only
  /// receives its completions here on the main thread, so hotkey callbacks never wait for cold
  /// engine startup.
  func prepareAudio() {
    requireMainThread()
    guard permissions.microphonePermission.isAuthorized else {
      return
    }
    audioCapture.prepare()
  }

  func refreshSystemState() {
    requireMainThread()
    hotkeys.refresh(accessibilityAuthorized: permissions.accessibilityPermission.isAuthorized)
    expireReceiptIfNeeded()

    refreshMicrophoneTestState()

    guard let activeSession else {
      return
    }
    guard permissions.microphonePermission.isAuthorized else {
      cancel(message: "权限已撤销，本次内容已丢弃")
      return
    }
    guard audioCapture.isAvailable else {
      cancel(message: "麦克风不可用，本次内容已丢弃")
      return
    }
    // The delivery mode is captured at press time. A user may choose a custom Ctrl-Shift-Space
    // shortcut while Accessibility is authorized; that session still needs to discard if AX is
    // later revoked. The shortcut's legacy name is not a permission boundary.
    if activeSession.insertionMode == .directInsertion,
      !permissions.accessibilityPermission.isAuthorized
    {
      cancel(message: "权限已撤销，本次内容已丢弃")
      return
    }
    cancelIfSecureInputActive()
  }

  func hotkeyChanged(_ shortcut: HoldShortcut, isPressed: Bool) {
    requireMainThread()
    let callbackTimestamp = performanceDiagnostics.now()
    if isPressed {
      let attemptID = UUID()
      retainHotkeyAttempt(shortcut: shortcut, id: attemptID)
      beginRecording(
        shortcut: shortcut,
        attemptID: attemptID,
        hotkeyTimestamp: callbackTimestamp
      )
    } else {
      endRecording(shortcut: shortcut, hotkeyTimestamp: callbackTimestamp)
    }
  }

  func cancelFromHotkey() {
    requireMainThread()
    cancel(message: "已取消")
  }

  /// Rebinding a held trigger must first invalidate the session which may otherwise wait forever
  /// for the key-up of the previous binding.
  func cancelForHotkeyRebind() {
    requireMainThread()
    cancel(message: "快捷键已更改，本次内容已丢弃")
  }

  /// Leaving setup only cancels a session that has explicitly claimed the practice control.
  func cancelOnboardingPracticeSession() {
    requireMainThread()
    guard let activeSession,
      case .onboardingPractice = activeSession.purpose
    else {
      return
    }
    cancel(message: "练习已结束，本次内容已丢弃")
  }

  func cancelForOtherKey() {
    requireMainThread()
    cancel(message: "已取消")
  }

  func cancelForSystemInterruption() {
    requireMainThread()
    cancel(message: "系统已中断，本次内容已丢弃")
  }

  func cancelForModelChange() {
    requireMainThread()
    cancel(message: "语音模型正在更新，本次内容已丢弃")
  }

  private func handleAudioInterruption(_ operation: AudioCaptureOperation) {
    requireMainThread()
    if microphoneTestOperation === operation {
      finishMicrophoneTest(cancelled: true)
      return
    }
    guard audioOperation === operation else {
      return
    }
    cancel(message: "麦克风配置已变化，本次内容已丢弃")
  }

  private func beginRecording(
    shortcut: HoldShortcut,
    attemptID: UUID,
    hotkeyTimestamp: MonotonicTimestamp
  ) {
    performanceDiagnostics.record(
      kind: .hotkeyPressed,
      result: .observed,
      sessionID: attemptID,
      timestamp: hotkeyTimestamp,
      audioDuration: nil
    )
    guard phase == .idle, !isMicrophoneTestActive else {
      indicator.showBusyFeedback()
      recordAttemptFinished(id: attemptID, result: .failed)
      return
    }

    let pressTarget = focusInspector.snapshot()
    let context = StartContext(
      isPaused: isPaused,
      isBusy: false,
      microphonePermission: permissions.microphonePermission,
      microphoneAvailable: audioCapture.isAvailable,
      modelReady: recognizer.isReady,
      indicatorAvailable: indicator.isAvailable,
      secureInputActive: pressTarget.target.isSecure
    )
    switch DictationRules.startDecision(context) {
    case .allowed:
      break
    case .rejected(let rejection):
      indicator.showMessage(StartDecision.rejected(rejection).message, hideAfter: 2)
      recordAttemptFinished(id: attemptID, result: .failed)
      return
    }

    clearRetainedReceipt()
    generation.invalidate()
    let session = ActiveSession(
      id: attemptID,
      generation: generation,
      startedAt: clock.now(),
      pressTarget: pressTarget,
      releaseTarget: nil,
      shortcut: shortcut,
      insertionMode: permissions.accessibilityPermission.isAuthorized
        ? .directInsertion : .copyOnly,
      purpose: claimedPurpose(for: pressTarget.target, attemptID: attemptID)
    )
    activeSession = session
    secureInputLatched = false
    // Do not start AVAudioEngine until the nonactivating pill and menu state are both visible.
    guard indicator.showRecording() else {
      finish(message: "录音提示无法显示，未开始录音")
      return
    }
    performanceDiagnostics.record(
      kind: .recordingDisplayCommitted,
      result: .succeeded,
      sessionID: session.id
    )
    phase = .starting
    hotkeys.setCancellationInterception(true)
    (audioCapture as? PerformanceSessionConfiguring)?.setPerformanceSessionID(session.id)
    audioOperation = audioCapture.start(
      onLevel: { [weak self] level in
        self?.updateRecordingIndicator(level: level, generation: session.generation)
      },
      completion: { [weak self] operation, result in
        self?.captureDidStart(operation, result: result, generation: session.generation)
      }
    )
  }

  private func endRecording(shortcut: HoldShortcut, hotkeyTimestamp: MonotonicTimestamp) {
    requireMainThread()
    guard let attemptID = releaseHotkeyAttempt(for: shortcut) else {
      return
    }
    performanceDiagnostics.record(
      kind: .hotkeyReleased,
      result: .observed,
      sessionID: attemptID,
      timestamp: hotkeyTimestamp,
      audioDuration: nil
    )
    guard let session = activeSession,
      session.id == attemptID,
      session.shortcut == shortcut
    else {
      return
    }
    if phase == .starting {
      cancel(message: "录音尚未开始，本次内容已丢弃")
      return
    }
    guard phase == .listening else {
      return
    }
    cancelIfSecureInputActive()
    guard phase == .listening else {
      return
    }
    captureReleaseTargetAndRecognize(session)
  }

  private func captureReleaseTargetAndRecognize(_ session: ActiveSession) {
    var releasedSession = session
    releasedSession.releaseTarget = focusInspector.snapshot()
    activeSession = releasedSession
    stopRecordingAndRecognize(session: releasedSession)
  }

  private func stopRecordingAndRecognize(session: ActiveSession) {
    recordingTimer?.cancel()
    recordingTimer = nil

    guard let audioOperation else {
      cancel(message: "录音尚未开始，本次内容已丢弃")
      return
    }
    phase = .stopping
    audioCapture.stop(audioOperation) { [weak self] audio in
      self?.handleStoppedAudio(audio, session: session)
    }
  }

  private func captureDidStart(
    _ operation: AudioCaptureOperation,
    result: Result<Void, Error>,
    generation sessionGeneration: SessionGeneration
  ) {
    requireMainThread()
    guard let session = activeSession,
      session.generation == sessionGeneration,
      phase == .starting,
      audioOperation === operation
    else {
      operation.cancel()
      return
    }

    switch result {
    case .success:
      phase = .listening
      startRecordingTimer(for: sessionGeneration)
    case .failure:
      finish(message: "麦克风不可用")
    }
  }

  private func handleStoppedAudio(_ stoppedAudio: CapturedAudio, session: ActiveSession) {
    requireMainThread()
    var audio = stoppedAudio
    guard activeSession?.generation == session.generation, phase == .stopping else {
      audio.erase()
      return
    }
    audioOperation = nil
    let heldDuration = clock.now().timeIntervalSince(session.startedAt)
    guard DictationRules.releaseDisposition(heldFor: heldDuration) == .recognize else {
      audio.erase()
      finish(message: "按压过短")
      return
    }

    guard !secureInputLatched else {
      audio.erase()
      cancel(message: "密码框中不支持语音输入，本次内容已丢弃")
      return
    }

    phase = .recognizing
    indicator.showProcessing()
    let completionGeneration = session.generation
    startRecognition(audio, generation: completionGeneration)
    // The recognizer owns its queued copy now; release this main-thread reference immediately.
    audio.erase()
  }

  private func startRecognition(
    _ audio: CapturedAudio, generation completionGeneration: SessionGeneration
  ) {
    let operation = RecognitionOperationSlot()
    pendingRecognition = operation
    let underlyingOperation = recognizer.transcribe(audio) { [weak self, weak operation] result in
      guard let operation else {
        return
      }
      self?.handleRecognition(result, generation: completionGeneration, operation: operation)
    }
    operation.adopt(underlyingOperation)
  }

  private func handleRecognition(
    _ result: Result<String, Error>,
    generation completionGeneration: SessionGeneration,
    operation: ASRTranscriptionOperation
  ) {
    requireMainThread()
    guard pendingRecognition === operation, isCurrentRecognizingSession(completionGeneration) else {
      return
    }
    pendingRecognition = nil
    guard let session = activeSession else {
      return
    }
    let recognitionResult: PerformanceEventResult
    switch result {
    case .success:
      recognitionResult = .delivered
    case .failure:
      recognitionResult = .failed
    }
    performanceDiagnostics.record(
      kind: .recognitionDelivered,
      result: recognitionResult,
      sessionID: session.id
    )
    cancelIfSecureInputActive()
    guard isCurrentRecognizingSession(completionGeneration) else {
      return
    }
    guard permissionsAreStillAllowed(for: session) else {
      cancel(message: "权限已撤销，本次内容已丢弃")
      return
    }

    switch result {
    case .failure:
      finish(message: "识别失败")
    case .success(let rawText):
      guard let text = TranscriptCleaner.clean(rawText) else {
        finish(message: "没有听到声音")
        return
      }
      insert(text, generation: completionGeneration)
    }
  }

  private func insert(_ text: String, generation completionGeneration: SessionGeneration) {
    requireMainThread()
    guard let session = activeSession, let releaseTarget = session.releaseTarget else {
      finish(message: "焦点信息不可用，本次内容已丢弃")
      return
    }

    guard permissionsAreStillAllowed(for: session) else {
      cancel(message: "权限已撤销，本次内容已丢弃")
      return
    }

    let currentTarget = focusInspector.snapshot()
    let context = InsertionContext(
      releasedTarget: releaseTarget.target,
      currentTarget: currentTarget.target,
      focusMatch: focusInspector.match(releaseTarget, currentTarget),
      accessibilityPermission: permissions.accessibilityPermission,
      secureInputActive: secureInputLatched || currentTarget.target.isSecure
    )
    let decision = DictationRules.insertionDecision(context)
    phase = .inserting
    cancelPendingInsertion()
    (textInserter as? PerformanceSessionConfiguring)?.setPerformanceSessionID(session.id)

    switch decision.action {
    case .discard:
      finish(message: decision.message)
    case .copy:
      startInsertion(session: session, text: text, generation: completionGeneration) { completion in
        self.textInserter.copy(
          text,
          requiresAccessibility: session.insertionMode == .directInsertion,
          completion: completion
        )
      }
    case .insert:
      startInsertion(session: session, text: text, generation: completionGeneration) { completion in
        self.textInserter.insert(text, expectedTarget: releaseTarget, completion: completion)
      }
    }
  }

  private func startInsertion(
    session: ActiveSession,
    text: String,
    generation completionGeneration: SessionGeneration,
    start: (@escaping (TextInsertionResult) -> Void) -> TextInsertionOperation
  ) {
    guard permissionsAreStillAllowed(for: session) else {
      cancel(message: "权限已撤销，本次内容已丢弃")
      return
    }
    let operation = InsertionOperationSlot()
    pendingInsertion = operation
    let underlyingOperation = start { [weak self, weak operation] result in
      guard let operation else {
        return
      }
      self?.handleInsertion(
        result,
        text: text,
        generation: completionGeneration,
        operation: operation
      )
    }
    operation.adopt(underlyingOperation)
  }

  private func handleInsertion(
    _ result: TextInsertionResult,
    text: String,
    generation completionGeneration: SessionGeneration,
    operation: TextInsertionOperation
  ) {
    requireMainThread()
    guard pendingInsertion === operation,
      activeSession?.generation == completionGeneration,
      phase == .inserting
    else {
      return
    }
    guard let session = activeSession else {
      return
    }
    let wasCopyOnlySession = session.insertionMode == .copyOnly
    pendingInsertion = nil
    cancelIfSecureInputActive()
    guard activeSession?.generation == completionGeneration, phase == .inserting else {
      return
    }
    guard permissionsAreStillAllowed(for: session) else {
      cancel(message: "权限已撤销，本次内容已丢弃")
      return
    }

    switch result {
    case .inserted(let receipt):
      retain(receipt: receipt)
      publishOutcome(session: session, text: text, delivery: .inserted)
      finish(message: "已插入", performanceResult: .verifiedInsertion)
    case .copied(let message):
      publishOutcome(session: session, text: text, delivery: .copied)
      if wasCopyOnlySession {
        finishCopyOnly(message: message)
      } else {
        finish(message: message, performanceResult: .copied)
      }
    case .unverified(let message):
      publishOutcome(session: session, text: text, delivery: .unverified)
      finish(message: message, performanceResult: .unverified)
    case .discarded(let message):
      finish(message: message)
    }
  }

  private func updateRecordingIndicator(level: Float, generation: SessionGeneration) {
    requireMainThread()
    guard phase == .listening, let session = activeSession, session.generation == generation else {
      return
    }
    let elapsed = clock.now().timeIntervalSince(session.startedAt)
    indicator.updateRecording(
      level: level,
      elapsed: elapsed,
      countdown: DictationRules.countdownSeconds(elapsed: elapsed)
    )
  }

  private func startRecordingTimer(for timerGeneration: SessionGeneration) {
    recordingTimer?.cancel()
    recordingTimer = timerScheduler.schedule(after: 0.25, repeats: true) { [weak self] in
      guard let self else {
        return
      }
      guard self.activeSession?.generation == timerGeneration, self.phase == .listening else {
        return
      }
      self.refreshSystemState()
      guard self.phase == .listening, let session = self.activeSession else {
        return
      }
      let elapsed = self.clock.now().timeIntervalSince(session.startedAt)
      self.indicator.updateRecording(
        level: 0,
        elapsed: elapsed,
        countdown: DictationRules.countdownSeconds(elapsed: elapsed)
      )
      if DictationRules.shouldAutoStop(elapsed: elapsed) {
        self.captureReleaseTargetAndRecognize(session)
      }
    }
  }

  private func retain(receipt: InsertionReceipt) {
    guard let target = activeSession?.releaseTarget else {
      return
    }
    retainedReceipt = RetainedReceipt(receipt: receipt, target: target)
    receiptExpiryTimer?.cancel()
    receiptExpiryTimer = timerScheduler.schedule(after: 120, repeats: false) { [weak self] in
      self?.clearRetainedReceipt()
    }
  }

  private func expireReceiptIfNeeded() {
    guard let retainedReceipt else {
      return
    }
    guard clock.now() < retainedReceipt.receipt.expiresAt else {
      clearRetainedReceipt()
      return
    }
    let currentTarget = focusInspector.snapshot()
    if currentTarget.target.isSecure
      || focusInspector.match(retainedReceipt.target, currentTarget) != .same
    {
      clearRetainedReceipt()
    }
  }

  private func clearRetainedReceipt() {
    let receipt = retainedReceipt?.receipt
    retainedReceipt = nil
    receiptExpiryTimer?.cancel()
    receiptExpiryTimer = nil
    if let receipt {
      onReceiptEnded(receipt)
    }
  }

  private func cancelIfSecureInputActive() {
    let currentTarget = focusInspector.snapshot()
    if currentTarget.target.isSecure {
      secureInputLatched = true
      cancel(message: "密码框中不支持语音输入，本次内容已丢弃")
    }
  }

  private func cancelPendingInsertion() {
    pendingInsertion?.cancel()
    pendingInsertion = nil
  }

  private func cancelPendingRecognition() {
    pendingRecognition?.cancel()
    pendingRecognition = nil
  }

  private func cancel(message: String) {
    if isMicrophoneTestActive {
      finishMicrophoneTest(cancelled: true)
    }
    guard phase != .idle else {
      return
    }
    generation.invalidate()
    phase = .cancelled
    recordingTimer?.cancel()
    recordingTimer = nil
    cancelPendingRecognition()
    cancelPendingInsertion()
    cancelAudioOperation()
    recordSessionFinished(result: .cancelled)
    activeSession = nil
    hotkeys.setCancellationInterception(false)
    indicator.showMessage(message, hideAfter: 1.5)
    phase = .idle
  }

  private func finish(
    message: String,
    performanceResult: PerformanceEventResult = .failed
  ) {
    generation.invalidate()
    recordingTimer?.cancel()
    recordingTimer = nil
    cancelPendingRecognition()
    cancelPendingInsertion()
    cancelAudioOperation()
    recordSessionFinished(result: performanceResult)
    activeSession = nil
    hotkeys.setCancellationInterception(false)
    indicator.showMessage(message, hideAfter: 1.5)
    phase = .idle
  }

  private func finishCopyOnly(message: String) {
    generation.invalidate()
    recordingTimer?.cancel()
    recordingTimer = nil
    cancelPendingRecognition()
    cancelPendingInsertion()
    cancelAudioOperation()
    recordSessionFinished(result: .copied)
    activeSession = nil
    hotkeys.setCancellationInterception(false)
    indicator.showCopyOnlyResult(message)
    phase = .idle
  }

  private func recordSessionFinished(result: PerformanceEventResult) {
    guard let session = activeSession else {
      return
    }
    recordAttemptFinished(id: session.id, result: result)
  }

  private func recordAttemptFinished(id: UUID, result: PerformanceEventResult) {
    performanceDiagnostics.record(
      kind: .sessionFinished,
      result: result,
      sessionID: id
    )
  }

  private func retainHotkeyAttempt(shortcut: HoldShortcut, id: UUID) {
    heldHotkeyAttempts.removeAll { $0.shortcut == shortcut }
    heldHotkeyAttempts.append((shortcut: shortcut, id: id))
  }

  private func releaseHotkeyAttempt(for shortcut: HoldShortcut) -> UUID? {
    guard let index = heldHotkeyAttempts.lastIndex(where: { $0.shortcut == shortcut }) else {
      return nil
    }
    return heldHotkeyAttempts.remove(at: index).id
  }

  private func isCurrentRecognizingSession(_ completionGeneration: SessionGeneration) -> Bool {
    activeSession?.generation == completionGeneration && phase == .recognizing
      && !secureInputLatched
  }

  private func permissionsAreStillAllowed(for session: ActiveSession) -> Bool {
    guard permissions.microphonePermission.isAuthorized else {
      return false
    }
    return session.insertionMode != .directInsertion
      || permissions.accessibilityPermission.isAuthorized
  }

  private func cancelAudioOperation() {
    audioOperation?.cancel()
    audioOperation = nil
  }

  private func publishOutcome(
    session: ActiveSession,
    text: String,
    delivery: SessionOutcome.Delivery
  ) {
    guard let target = session.releaseTarget?.target else {
      return
    }
    onSessionOutcome(
      SessionOutcome(
        sessionID: session.id,
        recognizedText: text,
        finalText: text,
        delivery: delivery,
        target: target,
        purpose: session.purpose,
        createdAt: clock.now()
      )
    )
  }

  private func claimedPurpose(for pressTarget: TargetSnapshot, attemptID: UUID) -> SessionPurpose {
    guard let binding = onboardingPracticeBindingProvider?(pressTarget, attemptID),
      binding.attemptID == attemptID,
      binding.matches(pressTarget)
    else {
      return .dictation
    }
    return .onboardingPractice(binding)
  }

  private func handleMicrophoneTestLevel(_ level: Float) {
    requireMainThread()
    guard microphoneTestOperation != nil else {
      return
    }
    // This threshold is intentionally low: the test only establishes that the selected input has
    // delivered a non-silent buffer. It does not record, transcribe, or retain the signal.
    if level >= 0.01 {
      microphoneTestHasSound = true
    }
    microphoneTestLevelHandler?(level)
  }

  private func microphoneTestDidStart(
    _ operation: AudioCaptureOperation,
    result: Result<Void, Error>
  ) {
    requireMainThread()
    guard microphoneTestOperation === operation else {
      operation.cancel()
      return
    }
    switch result {
    case .success:
      microphoneTestTimer?.cancel()
      microphoneTestTimer = timerScheduler.schedule(after: 8, repeats: false) { [weak self] in
        self?.finishMicrophoneTest(cancelled: false)
      }
    case .failure:
      finishMicrophoneTest(cancelled: true, completion: .unavailable)
    }
  }

  private func refreshMicrophoneTestState() {
    guard microphoneTestOperation != nil else {
      return
    }
    let focus = focusInspector.snapshot()
    guard permissions.microphonePermission.isAuthorized,
      audioCapture.isAvailable,
      !focus.target.isSecure,
      !isPaused
    else {
      finishMicrophoneTest(cancelled: true)
      return
    }
  }

  private func finishMicrophoneTest(
    cancelled: Bool,
    completion forcedCompletion: MicrophoneTestCompletion? = nil
  ) {
    requireMainThread()
    if let stoppingOperation = microphoneTestStoppingOperation {
      if cancelled {
        stoppingOperation.cancel()
        microphoneTestStoppingResult = forcedCompletion ?? .cancelled
      }
      return
    }
    guard let operation = microphoneTestOperation,
      microphoneTestStoppingOperation == nil
    else {
      return
    }
    let generation = microphoneTestGeneration
    microphoneTestOperation = nil
    microphoneTestStoppingOperation = operation
    microphoneTestStoppingGeneration = generation
    microphoneTestTimer?.cancel()
    microphoneTestTimer = nil
    let completed = microphoneTestCompletion
    microphoneTestCompletion = nil
    microphoneTestLevelHandler = nil

    let detectedSound = microphoneTestHasSound
    if cancelled {
      operation.cancel()
    }
    microphoneTestStoppingCompletion = completed
    microphoneTestStoppingResult =
      cancelled
      ? forcedCompletion ?? .cancelled
      : detectedSound ? .detectedSound : .noSound
    audioCapture.stop(operation) { audio in
      self.completeMicrophoneTestStop(operation: operation, generation: generation, audio: audio)
    }
  }

  private func completeMicrophoneTestStop(
    operation: AudioCaptureOperation,
    generation: UInt64,
    audio: CapturedAudio
  ) {
    requireMainThread()
    var disposableAudio = audio
    disposableAudio.erase()
    guard microphoneTestStoppingOperation === operation,
      microphoneTestStoppingGeneration == generation
    else {
      return
    }
    let completion = microphoneTestStoppingCompletion
    let result = microphoneTestStoppingResult ?? .cancelled
    microphoneTestStoppingOperation = nil
    microphoneTestStoppingGeneration = nil
    microphoneTestStoppingCompletion = nil
    microphoneTestStoppingResult = nil
    completion?(result)
  }

  private func requireMainThread() {
    dispatchPrecondition(condition: .onQueue(.main))
  }
}

private final class InsertionOperationSlot: TextInsertionOperation {
  private var operation: TextInsertionOperation?
  private var isCancelled = false

  func adopt(_ operation: TextInsertionOperation) {
    self.operation = operation
    if isCancelled {
      operation.cancel()
    }
  }

  func cancel() {
    isCancelled = true
    operation?.cancel()
  }
}

private final class RecognitionOperationSlot: ASRTranscriptionOperation {
  private var operation: ASRTranscriptionOperation?
  private var isCancelled = false

  func adopt(_ operation: ASRTranscriptionOperation) {
    self.operation = operation
    if isCancelled {
      operation.cancel()
    }
  }

  func cancel() {
    isCancelled = true
    operation?.cancel()
  }
}
