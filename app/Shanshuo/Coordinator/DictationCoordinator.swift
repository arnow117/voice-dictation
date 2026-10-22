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
  private struct ActiveSession {
    let generation: SessionGeneration
    let startedAt: Date
    let pressTarget: SystemFocusSnapshot
    var releaseTarget: SystemFocusSnapshot?
    let shortcut: HoldShortcut
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
  private let onReceiptEnded: (InsertionReceipt) -> Void
  private var activeSession: ActiveSession?
  private var recordingTimer: CoordinatorTimer?
  private var receiptExpiryTimer: CoordinatorTimer?
  private var pendingInsertion: TextInsertionOperation?
  private var pendingRecognition: ASRTranscriptionOperation?
  private var audioOperation: AudioCaptureOperation?
  private var retainedReceipt: RetainedReceipt?
  private var generation = SessionGeneration()
  private(set) var phase: DictationPhase = .idle
  private(set) var isPaused = false
  private var secureInputLatched = false

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
    onReceiptEnded: @escaping (InsertionReceipt) -> Void = { _ in }
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
    self.onReceiptEnded = onReceiptEnded
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
    // Ctrl-Shift-Space deliberately supports the no-Accessibility copy-only path. A session that
    // began with a direct-insertion shortcut, however, must discard as soon as that permission is
    // revoked so it cannot continue with stale accessibility state.
    if activeSession.shortcut != .copyOnlyControlShiftSpace,
      !permissions.accessibilityPermission.isAuthorized
    {
      cancel(message: "权限已撤销，本次内容已丢弃")
      return
    }
    cancelIfSecureInputActive()
  }

  func hotkeyChanged(_ shortcut: HoldShortcut, isPressed: Bool) {
    requireMainThread()
    if isPressed {
      beginRecording(shortcut: shortcut)
    } else {
      endRecording()
    }
  }

  func cancelFromHotkey() {
    requireMainThread()
    cancel(message: "已取消")
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
    guard audioOperation === operation else {
      return
    }
    cancel(message: "麦克风配置已变化，本次内容已丢弃")
  }

  private func beginRecording(shortcut: HoldShortcut) {
    clearRetainedReceipt()
    guard phase == .idle else {
      indicator.showBusyFeedback()
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
      return
    }

    generation.invalidate()
    let session = ActiveSession(
      generation: generation,
      startedAt: clock.now(),
      pressTarget: pressTarget,
      releaseTarget: nil,
      shortcut: shortcut
    )
    activeSession = session
    secureInputLatched = false

    // Do not start AVAudioEngine until the nonactivating pill and menu state are both visible.
    guard indicator.showRecording() else {
      finish(message: "录音提示无法显示，未开始录音")
      return
    }
    phase = .starting
    hotkeys.setCancellationInterception(true)
    audioOperation = audioCapture.start(
      onLevel: { [weak self] level in
        self?.updateRecordingIndicator(level: level, generation: session.generation)
      },
      completion: { [weak self] operation, result in
        self?.captureDidStart(operation, result: result, generation: session.generation)
      }
    )
  }

  private func endRecording() {
    requireMainThread()
    guard let session = activeSession else {
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
    guard activeSession?.generation == sessionGeneration,
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
    cancelIfSecureInputActive()
    guard isCurrentRecognizingSession(completionGeneration) else {
      return
    }
    guard permissions.microphonePermission.isAuthorized else {
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

    switch decision.action {
    case .discard:
      finish(message: decision.message)
    case .copy:
      startInsertion(generation: completionGeneration) { completion in
        self.textInserter.copy(text, completion: completion)
      }
    case .insert:
      startInsertion(generation: completionGeneration) { completion in
        self.textInserter.insert(text, expectedTarget: releaseTarget, completion: completion)
      }
    }
  }

  private func startInsertion(
    generation completionGeneration: SessionGeneration,
    start: (@escaping (TextInsertionResult) -> Void) -> TextInsertionOperation
  ) {
    let operation = InsertionOperationSlot()
    pendingInsertion = operation
    let underlyingOperation = start { [weak self, weak operation] result in
      guard let operation else {
        return
      }
      self?.handleInsertion(result, generation: completionGeneration, operation: operation)
    }
    operation.adopt(underlyingOperation)
  }

  private func handleInsertion(
    _ result: TextInsertionResult,
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
    let wasCopyOnlySession = activeSession?.shortcut == .copyOnlyControlShiftSpace
    pendingInsertion = nil
    cancelIfSecureInputActive()
    guard activeSession?.generation == completionGeneration, phase == .inserting else {
      return
    }

    switch result {
    case .inserted(let receipt):
      retain(receipt: receipt)
      finish(message: "已插入")
    case .copied(let message):
      if wasCopyOnlySession {
        finishCopyOnly(message: message)
      } else {
        finish(message: message)
      }
    case .discarded(let message), .unverified(let message):
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
    activeSession = nil
    hotkeys.setCancellationInterception(false)
    indicator.showMessage(message, hideAfter: 1.5)
    phase = .idle
  }

  private func finish(message: String) {
    generation.invalidate()
    recordingTimer?.cancel()
    recordingTimer = nil
    cancelPendingRecognition()
    cancelPendingInsertion()
    cancelAudioOperation()
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
    activeSession = nil
    hotkeys.setCancellationInterception(false)
    indicator.showCopyOnlyResult(message)
    phase = .idle
  }

  private func isCurrentRecognizingSession(_ completionGeneration: SessionGeneration) -> Bool {
    activeSession?.generation == completionGeneration && phase == .recognizing
      && !secureInputLatched
  }

  private func cancelAudioOperation() {
    audioOperation?.cancel()
    audioOperation = nil
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
