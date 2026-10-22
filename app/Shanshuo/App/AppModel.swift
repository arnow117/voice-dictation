import AppKit
import Foundation
import ShanshuoCore

struct AppStatusSnapshot {
  let microphonePermission: PermissionStatus
  let accessibilityPermission: PermissionStatus
  let modelStatus: ModelManagerStatus
  let preferredShortcut: HoldShortcut
  let effectiveShortcut: HoldShortcut
  let isShortcutAvailable: Bool
  let pause: PauseSnapshot
  let historyEnabled: Bool
  let onboardingProgress: OnboardingProgress
  let historyFailure: HistoryStoreError?

  var modelReady: Bool {
    if case .ready = modelStatus {
      return true
    }
    return false
  }
}

/// Main-thread projection shared by the menu, onboarding, history, and privacy windows. It owns no
/// audio session, model files, or SQLite connection; it only translates user actions into commands
/// for their respective single owners and publishes a live snapshot for native views.
final class AppModel {
  private enum Key {
    static let preferredShortcut = "hotkey.preferred"
    static let historyEnabled = "history.enabled"
  }

  private let permissions: PermissionRequesting
  private let hotkeys: HotkeyMonitoring
  private let coordinator: DictationCoordinator
  private let audioCapture: AudioCapturing
  private let modelManager: ModelManaging
  private let historyStore: HistoryStore
  private let pauseController: PauseController
  private let progressStore: OnboardingProgressStore
  private let defaults: UserDefaults
  private let targetAppName: (TargetSnapshot) -> String?
  private var modelObservation: UUID?
  private var observers: [UUID: (AppStatusSnapshot) -> Void] = [:]
  private var outcomeObservers: [UUID: (SessionOutcome) -> Void] = [:]
  private var historyWriteGeneration: UInt64 = 0
  private var historyEnabled: Bool
  private var historyFailure: HistoryStoreError?
  private var progress: OnboardingProgress
  private var lastCleanupAt: Date?
  private var shortcutTestSawPress = false
  private var shortcutTestSawRelease = false
  private let selectedInputDeviceKey = "audio.input-device-uid"

  init(
    permissions: PermissionRequesting,
    hotkeys: HotkeyMonitoring,
    coordinator: DictationCoordinator,
    audioCapture: AudioCapturing,
    modelManager: ModelManaging,
    historyStore: HistoryStore,
    pauseController: PauseController = PauseController(),
    progressStore: OnboardingProgressStore = OnboardingProgressStore(),
    defaults: UserDefaults = .standard,
    targetAppName: @escaping (TargetSnapshot) -> String? = AppModel.defaultTargetAppName
  ) {
    self.permissions = permissions
    self.hotkeys = hotkeys
    self.coordinator = coordinator
    self.audioCapture = audioCapture
    self.modelManager = modelManager
    self.historyStore = historyStore
    self.pauseController = pauseController
    self.progressStore = progressStore
    self.defaults = defaults
    self.targetAppName = targetAppName
    if defaults.object(forKey: Key.historyEnabled) == nil {
      historyEnabled = true
      defaults.set(true, forKey: Key.historyEnabled)
    } else {
      historyEnabled = defaults.bool(forKey: Key.historyEnabled)
    }
    progress = progressStore.load()

    hotkeys.selectedShortcut = preferredShortcutFromDefaults()
    audioCapture.selectedInputDeviceUID = defaults.string(forKey: selectedInputDeviceKey)
    modelObservation = modelManager.observe { [weak self] _ in
      self?.publish()
    }
    historyStore.open { [weak self] result in
      guard let self else {
        return
      }
      self.handleHistoryOperation(result)
      guard case .success = result else {
        return
      }
      self.setHistoryEnabledOnStore()
      self.cleanupHistoryIfNeeded(force: true)
    }
  }

  deinit {
    if let modelObservation {
      modelManager.removeObserver(modelObservation)
    }
  }

  func observe(_ observer: @escaping (AppStatusSnapshot) -> Void) -> UUID {
    requireMainThread()
    let identifier = UUID()
    observers[identifier] = observer
    observer(snapshot())
    return identifier
  }

  func removeObserver(_ identifier: UUID) {
    requireMainThread()
    observers[identifier] = nil
  }

  func observeSessionOutcome(_ observer: @escaping (SessionOutcome) -> Void) -> UUID {
    requireMainThread()
    let identifier = UUID()
    outcomeObservers[identifier] = observer
    return identifier
  }

  func removeSessionOutcomeObserver(_ identifier: UUID) {
    requireMainThread()
    outcomeObservers[identifier] = nil
  }

  func refreshLiveState() {
    requireMainThread()
    _ = pauseController.refreshExpiredPause()
    coordinator.setPaused(pauseController.snapshot().isPaused)
    coordinator.refreshSystemState()
    cleanupHistoryIfNeeded(force: false)
    publish()
  }

  func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
    requireMainThread()
    permissions.requestMicrophoneAccess { [weak self] granted in
      self?.refreshLiveState()
      completion(granted)
    }
  }

  func setPreferredShortcut(_ shortcut: HoldShortcut) {
    requireMainThread()
    defaults.set(shortcut.storageValue, forKey: Key.preferredShortcut)
    hotkeys.selectedShortcut = shortcut
    hotkeys.refresh(accessibilityAuthorized: permissions.accessibilityPermission.isAuthorized)
    publish()
  }

  func pauseForOneHour() {
    requireMainThread()
    _ = pauseController.pauseForOneHour()
    coordinator.setPaused(true)
    publish()
  }

  func pauseUntilManualResume() {
    requireMainThread()
    _ = pauseController.pauseUntilManualResume()
    coordinator.setPaused(true)
    publish()
  }

  func resumeDictation() {
    requireMainThread()
    _ = pauseController.resume()
    coordinator.setPaused(false)
    publish()
  }

  func setHistoryEnabled(_ enabled: Bool) {
    requireMainThread()
    historyEnabled = enabled
    defaults.set(enabled, forKey: Key.historyEnabled)
    historyWriteGeneration &+= 1
    setHistoryEnabledOnStore()
    publish()
  }

  func historyRecords(completion: @escaping (Result<[HistoryRecord], HistoryStoreError>) -> Void) {
    requireMainThread()
    historyStore.records(completion: completion)
  }

  func deleteHistoryRecord(
    _ record: HistoryRecord, completion: @escaping (Result<Void, HistoryStoreError>) -> Void
  ) {
    requireMainThread()
    historyWriteGeneration &+= 1
    historyStore.delete(
      sessionID: record.sessionID,
      writeGeneration: historyWriteGeneration,
      completion: completion
    )
  }

  func clearHistory(completion: @escaping (Result<Void, HistoryStoreError>) -> Void) {
    requireMainThread()
    historyWriteGeneration &+= 1
    historyStore.clear(writeGeneration: historyWriteGeneration, completion: completion)
  }

  func handleSessionOutcome(_ outcome: SessionOutcome) {
    requireMainThread()
    for observer in outcomeObservers.values {
      observer(outcome)
    }
    guard outcome.isPersistableInHistory else {
      return
    }
    guard historyEnabled else {
      return
    }
    historyStore.append(
      outcome,
      targetAppName: targetAppName(outcome.target),
      writeGeneration: historyWriteGeneration
    ) { [weak self] result in
      self?.handleHistoryOperation(result)
    }
  }

  func visit(_ step: OnboardingStep) {
    requireMainThread()
    progress.visited.insert(step)
    persistProgress()
  }

  func complete(_ step: OnboardingStep) {
    requireMainThread()
    progress.visited.insert(step)
    progress.completed.insert(step)
    progress.skipped.remove(step)
    persistProgress()
  }

  func skip(_ step: OnboardingStep) {
    requireMainThread()
    progress.visited.insert(step)
    progress.skipped.insert(step)
    persistProgress()
  }

  func onboardingProgress() -> OnboardingProgress {
    progress
  }

  func pauseSnapshot() -> PauseSnapshot {
    pauseController.snapshot()
  }

  func inputDevices() -> [InputDevice] {
    audioCapture.availableInputDevices
  }

  func selectedInputDeviceUID() -> String? {
    audioCapture.selectedInputDeviceUID
  }

  func selectInputDevice(uid: String?) {
    requireMainThread()
    if let uid {
      defaults.set(uid, forKey: selectedInputDeviceKey)
    } else {
      defaults.removeObject(forKey: selectedInputDeviceKey)
    }
    audioCapture.selectedInputDeviceUID = uid
    publish()
  }

  func beginMicrophoneTest(
    indicatorVisible: Bool,
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (MicrophoneTestCompletion) -> Void
  ) -> Bool {
    coordinator.beginMicrophoneTest(
      indicatorVisible: indicatorVisible,
      onLevel: onLevel,
      completion: completion
    )
  }

  func endMicrophoneTest() {
    coordinator.endMicrophoneTest()
  }

  /// Installs the onboarding window's live first-responder check. The provider runs immediately
  /// before every hold begins, so retrying after Esc, silence, or a short press cannot reuse a
  /// stale practice claim.
  func setOnboardingPracticeBindingProvider(
    _ provider: @escaping (TargetSnapshot) -> PracticeSessionBinding?
  ) {
    requireMainThread()
    coordinator.setOnboardingPracticeBindingProvider(provider)
  }

  func clearOnboardingPracticeBindingProvider() {
    requireMainThread()
    coordinator.clearOnboardingPracticeBindingProvider()
  }

  func beginShortcutTest() {
    requireMainThread()
    shortcutTestSawPress = false
    shortcutTestSawRelease = false
  }

  func recordHotkeyEvent(_ shortcut: HoldShortcut, isPressed: Bool) {
    requireMainThread()
    guard shortcut == snapshot().effectiveShortcut else {
      return
    }
    if isPressed {
      shortcutTestSawPress = true
    } else if shortcutTestSawPress {
      shortcutTestSawRelease = true
    }
    publish()
  }

  var shortcutTestSucceeded: Bool {
    shortcutTestSawPress && shortcutTestSawRelease
  }

  private func snapshot() -> AppStatusSnapshot {
    let accessibilityAuthorized = permissions.accessibilityPermission.isAuthorized
    let effectiveShortcut: HoldShortcut =
      accessibilityAuthorized
      ? hotkeys.selectedShortcut
      : .copyOnlyControlShiftSpace
    return AppStatusSnapshot(
      microphonePermission: permissions.microphonePermission,
      accessibilityPermission: permissions.accessibilityPermission,
      modelStatus: modelManager.status,
      preferredShortcut: hotkeys.selectedShortcut,
      effectiveShortcut: effectiveShortcut,
      isShortcutAvailable: hotkeys.isShortcutAvailable,
      pause: pauseController.snapshot(),
      historyEnabled: historyEnabled,
      onboardingProgress: progress,
      historyFailure: historyFailure
    )
  }

  private func publish() {
    requireMainThread()
    let currentSnapshot = snapshot()
    for observer in observers.values {
      observer(currentSnapshot)
    }
  }

  private func persistProgress() {
    progressStore.save(progress)
    publish()
  }

  private func setHistoryEnabledOnStore() {
    historyStore.setEnabled(historyEnabled, writeGeneration: historyWriteGeneration) {
      [weak self] result in
      guard case .failure(let error) = result else {
        return
      }
      self?.historyFailure = error
      self?.publish()
    }
  }

  private func cleanupHistoryIfNeeded(force: Bool) {
    let now = Date()
    guard force || lastCleanupAt.map({ now.timeIntervalSince($0) >= 60 * 60 }) != false else {
      return
    }
    lastCleanupAt = now
    historyStore.removeExpired { [weak self] result in
      self?.handleHistoryOperation(result)
    }
  }

  private func handleHistoryOperation<Value>(_ result: Result<Value, HistoryStoreError>) {
    requireMainThread()
    switch result {
    case .success:
      historyFailure = nil
    case .failure(let error):
      historyFailure = error
    }
    publish()
  }

  private func preferredShortcutFromDefaults() -> HoldShortcut {
    guard let rawValue = defaults.string(forKey: Key.preferredShortcut),
      let shortcut = HoldShortcut(storageValue: rawValue)
    else {
      return .function
    }
    return shortcut
  }

  private static func defaultTargetAppName(_ target: TargetSnapshot) -> String? {
    guard let processIdentifier = target.processIdentifier else {
      return nil
    }
    return NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
  }

  private func requireMainThread() {
    dispatchPrecondition(condition: .onQueue(.main))
  }
}

extension HoldShortcut {
  fileprivate var storageValue: String {
    switch self {
    case .function:
      return "function"
    case .rightOption:
      return "rightOption"
    case .copyOnlyControlShiftSpace:
      return "copyOnlyControlShiftSpace"
    }
  }

  fileprivate init?(storageValue: String) {
    switch storageValue {
    case "function":
      self = .function
    case "rightOption":
      self = .rightOption
    case "copyOnlyControlShiftSpace":
      self = .copyOnlyControlShiftSpace
    default:
      return nil
    }
  }
}
