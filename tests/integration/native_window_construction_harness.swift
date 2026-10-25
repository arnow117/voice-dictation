import AppKit
import Carbon
import Foundation
import ShanshuoCore

// The production controllers are compiled into this harness. These adapters only satisfy their
// collaborators; construction must not ask for permissions, access the microphone, or download.
protocol ASRTranscriptionOperation: AnyObject {
  func cancel()
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

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private final class RecordingEventWindow: NSWindow {
  private(set) var receivedEvent: NSEvent?

  override func sendEvent(_ event: NSEvent) {
    receivedEvent = event
  }
}

private final class FakePermissions: PermissionRequesting {
  var microphonePermission: PermissionStatus = .authorized
  var accessibilityPermission: PermissionStatus = .authorized

  func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
    completion(true)
  }
}

private final class FakeFocusInspector: FocusInspecting {
  private let current = SystemFocusSnapshot(
    target: TargetSnapshot(
      bundleIdentifier: "com.arnow117.shanshuo",
      processIdentifier: Int32(ProcessInfo.processInfo.processIdentifier),
      elementIdentifier: "window-construction",
      isEditable: true,
      isSecure: false
    ),
    element: nil
  )

  func snapshot() -> SystemFocusSnapshot {
    current
  }

  func match(_ expected: SystemFocusSnapshot, _ actual: SystemFocusSnapshot) -> FocusMatch {
    .same
  }
}

private final class FakeIndicator: RecordingIndicating {
  let isAvailable = true

  func showRecording() -> Bool { true }
  func updateRecording(level: Float, elapsed: TimeInterval, countdown: Int?) {}
  func showProcessing() {}
  func showMessage(_ message: String, hideAfter: TimeInterval) {}
  func showCopyOnlyResult(_ message: String) {}
  func showBusyFeedback() {}
  func hide() {}
}

private final class FakeAudioOperation: AudioCaptureOperation {
  func cancel() {}
}

private final class FakeAudioCapture: AudioCapturing {
  var isAvailable = true
  var invalidateReadinessOnSelection = false
  var onInterruption: ((AudioCaptureOperation) -> Void)?
  var availableInputDevices: [InputDevice] = [InputDevice(uid: "default", name: "Default")]
  var selectedInputDeviceUID: String? {
    didSet {
      if invalidateReadinessOnSelection {
        isAvailable = false
      }
    }
  }

  func prepare() {}

  func start(
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) -> AudioCaptureOperation {
    FakeAudioOperation()
  }

  func stop(_ operation: AudioCaptureOperation, completion: @escaping (CapturedAudio) -> Void) {
    completion(CapturedAudio(samples: [], sampleRate: 16_000, duration: 0))
  }
}

private final class FakeASROperation: ASRTranscriptionOperation {
  func cancel() {}
}

private final class FakeRecognizer: ASRRecognizing {
  let isReady = true

  func load(completion: @escaping (Result<Void, Error>) -> Void) {
    completion(.success(()))
  }

  func transcribe(
    _ audio: CapturedAudio,
    completion: @escaping (Result<String, Error>) -> Void
  ) -> ASRTranscriptionOperation {
    FakeASROperation()
  }

  func unload() {}
}

private final class FakeInsertionOperation: TextInsertionOperation {
  func cancel() {}
}

private final class FakeTextInserter: TextInserting {
  func insert(
    _ text: String,
    expectedTarget: SystemFocusSnapshot,
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation {
    FakeInsertionOperation()
  }

  func copy(
    _ text: String,
    requiresAccessibility: Bool,
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation {
    FakeInsertionOperation()
  }
}

private final class FakeFormattingOperation: FormattingOperation {
  private(set) var wasCancelled = false

  func cancel() {
    wasCancelled = true
  }
}

private final class ImmediateFormattingService: FormattingServicing {
  let result: FormattingResult
  private(set) var requestCount = 0

  init(result: FormattingResult) {
    self.result = result
  }

  @discardableResult
  func format(
    request: FormattingRequest,
    configuration: FormattingConfigurationSnapshot,
    authorizeSend: @escaping () -> Bool,
    completion: @escaping (FormattingResult) -> Void
  ) -> FormattingOperation {
    requestCount += 1
    if authorizeSend() {
      completion(result)
    }
    return FakeFormattingOperation()
  }
}

/// Holds a callback after the settings controller has started a real formatter operation. Tests
/// can then force a late success even after the controller has cancelled the operation.
private final class DeferredFormattingService: FormattingServicing {
  private(set) var operation: FakeFormattingOperation?
  private(set) var authorizationWasAccepted = false
  private var completion: ((FormattingResult) -> Void)?

  @discardableResult
  func format(
    request: FormattingRequest,
    configuration: FormattingConfigurationSnapshot,
    authorizeSend: @escaping () -> Bool,
    completion: @escaping (FormattingResult) -> Void
  ) -> FormattingOperation {
    authorizationWasAccepted = authorizeSend()
    self.completion = completion
    let operation = FakeFormattingOperation()
    self.operation = operation
    return operation
  }

  func deliverLate(_ result: FormattingResult) {
    completion?(result)
  }
}

private func descendantViews(of view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap(descendantViews)
}

private func button(named title: String, in view: NSView) -> NSButton? {
  descendantViews(of: view).compactMap { $0 as? NSButton }.first { $0.title == title }
}

private func secureField(in view: NSView) -> NSSecureTextField? {
  descendantViews(of: view).compactMap { $0 as? NSSecureTextField }.first
}

private func hasLabel(_ value: String, in view: NSView) -> Bool {
  descendantViews(of: view).compactMap { $0 as? NSTextField }.contains {
    $0.stringValue == value
  }
}

private func isEffectivelyHidden(_ view: NSView) -> Bool {
  var current: NSView? = view
  while let candidate = current {
    if candidate.isHidden {
      return true
    }
    current = candidate.superview
  }
  return false
}

private func waitForMain(
  timeout: TimeInterval = 1,
  until condition: @escaping () -> Bool
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() {
      return true
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return condition()
}

private func testFormattingSettingsWorkflow() {
  let defaults = UserDefaults(suiteName: "shanshuo-formatting-settings-workflow-\(UUID().uuidString)")!
  let configurationStore = FormattingConfigurationStore(defaults: defaults)
  let credentialStore = FormattingCredentialStore()
  let formatter = ImmediateFormattingService(result: .formatted("第一，买牛奶。"))
  let controller = FormattingSettingsWindowController(
    configurationStore: configurationStore,
    credentialStore: credentialStore,
    formatter: formatter
  )

  guard let contentView = controller.window?.contentView,
    let acknowledgement = button(named: "我了解本次识别文字会发送给 MiniMax 进行整理。", in: contentView),
    let save = button(named: "使用本次 Key", in: contentView),
    let test = button(named: "测试连接", in: contentView),
    let enable = button(named: "开启智能整理", in: contentView),
    let delete = button(named: "清除本次 Key", in: contentView),
    let keyField = secureField(in: contentView)
  else {
    check(false, "the formatting settings window exposes its production controls")
    return
  }

  check(
    isEffectivelyHidden(keyField),
    "first use hides the Key input before the data-flow acknowledgement"
  )
  check(test.isHidden, "first use hides the connection test before the acknowledgement")
  acknowledgement.performClick(nil)
  check(
    !isEffectivelyHidden(keyField),
    "acknowledging the data flow reveals the Key input"
  )

  keyField.stringValue = "fixture-key-not-a-real-secret"
  save.performClick(nil)
  check(
    waitForMain { configurationStore.snapshot().credential != nil },
    "manual secure input imports a Key into the shared process-memory cache"
  )
  guard let descriptor = configurationStore.snapshot().credential else {
    check(false, "manual secure input produces a configuration descriptor")
    return
  }
  check(
    (try? credentialStore.read(reference: descriptor.reference)) == "fixture-key-not-a-real-secret",
    "the settings controller writes its configured Key to the injected cache instance"
  )
  check(test.isEnabled, "an acknowledged configuration with a session Key can test the connection")
  test.performClick(nil)
  check(formatter.requestCount == 1, "the explicit test uses the injected production formatter seam")
  check(hasLabel("连接测试成功。可以开启智能整理。", in: contentView), "the successful test result remains visible after rendering")
  check(enable.isEnabled, "only a completed test enables the explicit enable action")
  enable.performClick(nil)
  check(configurationStore.snapshot().enabled, "the acknowledge-test-enable action chain enables formatting")

  delete.performClick(nil)
  check(!configurationStore.snapshot().enabled, "clearing a Key immediately disables formatting")
  check(
    configurationStore.snapshot().credential == nil,
    "clearing a process-memory Key removes its configuration descriptor"
  )
  check(
    (try? credentialStore.read(reference: descriptor.reference)) == nil,
    "clearing a process-memory Key makes its cache entry unavailable"
  )
  check(
    hasLabel("已清除本次运行 Key，智能整理保持关闭。", in: contentView),
    "clearing a Key describes the session-only result"
  )

  let staleDefaults = UserDefaults(suiteName: "shanshuo-formatting-settings-stale-\(UUID().uuidString)")!
  let staleStore = FormattingConfigurationStore(defaults: staleDefaults)
  let staleCredentials = FormattingCredentialStore()
  let staleFormatter = DeferredFormattingService()
  let staleController = FormattingSettingsWindowController(
    configurationStore: staleStore,
    credentialStore: staleCredentials,
    formatter: staleFormatter
  )
  guard let staleContent = staleController.window?.contentView,
    let staleAcknowledgement = button(named: "我了解本次识别文字会发送给 MiniMax 进行整理。", in: staleContent),
    let staleTest = button(named: "测试连接", in: staleContent),
    let staleEnable = button(named: "开启智能整理", in: staleContent)
  else {
    check(false, "a second formatting settings window exposes its production controls")
    return
  }

  staleAcknowledgement.performClick(nil)
  let staleDescriptor = try! staleCredentials.save("second-fixture-key-not-a-real-secret")
  _ = staleStore.replaceCredential(staleDescriptor, model: .flash, endpoint: .domestic)
  staleTest.performClick(nil)
  check(
    staleFormatter.authorizationWasAccepted && staleFormatter.operation != nil && !staleEnable.isEnabled,
    "a connection test remains pending until its formatter callback completes"
  )
  staleController.windowWillClose(Notification(name: NSWindow.willCloseNotification))
  staleController.showWindow(nil)
  staleController.window?.orderOut(nil)
  staleFormatter.deliverLate(.formatted("第一，买牛奶。"))
  check(
    staleFormatter.operation?.wasCancelled == true
      && !staleEnable.isEnabled
      && !staleStore.snapshot().enabled,
    "closing and reopening cancels a pending test and ignores its forced late success"
  )

  let invalidDefaults = UserDefaults(suiteName: "shanshuo-formatting-settings-invalid-key-\(UUID().uuidString)")!
  let invalidStore = FormattingConfigurationStore(defaults: invalidDefaults)
  let invalidCredentials = FormattingCredentialStore()
  let invalidFormatter = ImmediateFormattingService(
    result: .fallback(original: "第一买牛奶第二取快递", reason: .authorizationFailed)
  )
  let invalidController = FormattingSettingsWindowController(
    configurationStore: invalidStore,
    credentialStore: invalidCredentials,
    formatter: invalidFormatter
  )
  guard let invalidContent = invalidController.window?.contentView,
    let invalidAcknowledgement = button(named: "我了解本次识别文字会发送给 MiniMax 进行整理。", in: invalidContent),
    let invalidTest = button(named: "测试连接", in: invalidContent),
    let keyHelp = button(named: "获取 MiniMax API Key", in: invalidContent)
  else {
    check(false, "the invalid-Key state exposes its production controls")
    return
  }

  invalidAcknowledgement.performClick(nil)
  let invalidDescriptor = try! invalidCredentials.save("invalid-fixture-key-not-a-real-secret")
  _ = invalidStore.replaceCredential(invalidDescriptor, model: .flash, endpoint: .domestic)
  invalidTest.performClick(nil)
  check(
    hasLabel(
      "Key 无效。智能整理仍保持关闭。请通过下方官方链接获取或更新 MiniMax API Key。",
      in: invalidContent
    ),
    "invalid Key feedback reports that initially disabled formatting remains disabled"
  )
  check(!keyHelp.isHidden, "invalid Key feedback retains the official Key console link")
  check(!invalidStore.snapshot().enabled, "an invalid Key never enables formatting")
}

private func testConnectionFeedbackPreservesEnabledState() {
  let defaults = UserDefaults(
    suiteName: "shanshuo-formatting-settings-feedback-\(UUID().uuidString)"
  )!
  let configurationStore = FormattingConfigurationStore(defaults: defaults)
  let credentialStore = FormattingCredentialStore()
  let formatter = DeferredFormattingService()
  let controller = FormattingSettingsWindowController(
    configurationStore: configurationStore,
    credentialStore: credentialStore,
    formatter: formatter
  )

  guard let contentView = controller.window?.contentView,
    let acknowledgement = button(named: "我了解本次识别文字会发送给 MiniMax 进行整理。", in: contentView),
    let test = button(named: "测试连接", in: contentView),
    let enable = button(named: "开启智能整理", in: contentView)
  else {
    check(false, "the feedback test exposes the formatting controls")
    return
  }

  acknowledgement.performClick(nil)
  let descriptor = try! credentialStore.save("feedback-fixture-key-not-a-real-secret")
  _ = configurationStore.replaceCredential(descriptor, model: .flash, endpoint: .domestic)

  test.performClick(nil)
  formatter.deliverLate(
    .fallback(original: "第一买牛奶第二取快递", reason: .transportFailure)
  )
  check(
    hasLabel("连接测试未完成。智能整理仍保持关闭。", in: contentView),
    "a failed test reports that initially disabled formatting remains disabled"
  )
  check(
    !configurationStore.snapshot().enabled,
    "a failed test does not enable initially disabled formatting"
  )

  test.performClick(nil)
  formatter.deliverLate(
    .fallback(original: "第一买牛奶第二取快递", reason: .deadlineExceeded)
  )
  check(
    hasLabel("连接测试未完成。智能整理仍保持关闭。", in: contentView),
    "a timed-out test reports that initially disabled formatting remains disabled"
  )

  test.performClick(nil)
  formatter.deliverLate(.formatted("第一，买牛奶。"))
  enable.performClick(nil)
  check(configurationStore.snapshot().enabled, "a successful test can enable formatting")

  test.performClick(nil)
  formatter.deliverLate(
    .fallback(original: "第一买牛奶第二取快递", reason: .transportFailure)
  )
  check(
    hasLabel("连接测试未完成。智能整理仍保持开启。", in: contentView),
    "a transport failure reports that enabled formatting remains enabled"
  )
  check(
    configurationStore.snapshot().enabled,
    "a transport failure does not change the enabled switch"
  )

  test.performClick(nil)
  formatter.deliverLate(
    .fallback(original: "第一买牛奶第二取快递", reason: .deadlineExceeded)
  )
  check(
    hasLabel("连接测试未完成。智能整理仍保持开启。", in: contentView),
    "a timeout reports that enabled formatting remains enabled"
  )
  check(
    configurationStore.snapshot().enabled,
    "a timeout does not change the enabled switch"
  )

  test.performClick(nil)
  formatter.deliverLate(.formatted("第一，买牛奶。"))
  check(
    hasLabel("连接测试成功。智能整理保持开启。", in: contentView),
    "a successful retest reports that enabled formatting remains enabled"
  )
  check(
    configurationStore.snapshot().enabled,
    "a successful retest does not change the enabled switch"
  )
}

private final class FakeHotkeys: HotkeyMonitoring {
  var isShortcutAvailable = true
  var onHold: ((HoldShortcut, Bool) -> Void)?
  var onCancel: (() -> Void)?
  var onOtherKey: (() -> Void)?
  var selectedShortcut: HoldShortcut = .function
  private(set) var triggeringSuspensionStates: [Bool] = []

  func refresh(accessibilityAuthorized: Bool) {}
  func setCancellationInterception(_ enabled: Bool) {}
  func setTriggeringSuspended(_ suspended: Bool) {
    triggeringSuspensionStates.append(suspended)
  }
  func stop() {}
}

private final class FakeModelManager: ModelManaging {
  let manifest: Qwen3ModelManifest
  var status: ModelManagerStatus = .repairRequired("test model is not installed")
  var selectedSource: ModelDownloadSource
  var onWillMutate: (() -> Void)?
  private var observers: [UUID: (ModelManagerStatus) -> Void] = [:]

  init() {
    let source = ModelDownloadSource(
      id: "test-source",
      name: "Test source",
      baseURL: URL(string: "https://example.invalid")!
    )
    selectedSource = source
    manifest = Qwen3ModelManifest(
      modelKey: "qwen3-asr-0.6b-int8",
      displayName: "Qwen3-ASR 0.6B",
      repository: "test/repository",
      revision: "test-revision",
      license: "Apache-2.0",
      totalBytes: 1,
      sources: [source],
      files: [
        Qwen3ModelManifest.File(
          path: "model.bin", size: 1, sha256: String(repeating: "0", count: 64))
      ]
    )
  }

  func observe(_ handler: @escaping (ModelManagerStatus) -> Void) -> UUID {
    let identifier = UUID()
    observers[identifier] = handler
    handler(status)
    return identifier
  }

  func removeObserver(_ identifier: UUID) {
    observers[identifier] = nil
  }

  func bootstrap() {}
  func download(preferredSource: ModelDownloadSource?) {}
  func pause() {}
  func repair() {}
  func deleteOwnedModel() {}
}

@main
enum NativeWindowConstructionHarness {
  static func main() {
    _ = NSApplication.shared
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shanshuo-window-layout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let permissions = FakePermissions()
    let coordinator = DictationCoordinator(
      permissions: permissions,
      focusInspector: FakeFocusInspector(),
      indicator: FakeIndicator(),
      audioCapture: FakeAudioCapture(),
      recognizer: FakeRecognizer(),
      textInserter: FakeTextInserter(),
      hotkeys: FakeHotkeys()
    )
    let appModel = AppModel(
      permissions: permissions,
      hotkeys: FakeHotkeys(),
      coordinator: coordinator,
      audioCapture: FakeAudioCapture(),
      modelManager: FakeModelManager(),
      historyStore: HistoryStore(directory: temporaryDirectory),
      defaults: UserDefaults(suiteName: "shanshuo-window-layout-\(UUID().uuidString)")!
    )
    var observedShortcutTestResults: [Bool] = []
    let shortcutObservation = appModel.observe { snapshot in
      observedShortcutTestResults.append(snapshot.shortcutTestSucceeded)
    }
    appModel.beginShortcutTest()
    appModel.recordHotkeyEvent(.function, isPressed: true)
    appModel.recordHotkeyEvent(.function, isPressed: false)
    check(
      observedShortcutTestResults.last == true,
      "the production AppModel publishes a completed shortcut test to its native observers"
    )
    appModel.beginShortcutTest()
    check(
      observedShortcutTestResults.last == false,
      "resetting a shortcut test publishes the visible incomplete state"
    )
    appModel.removeObserver(shortcutObservation)

    check(
      SettingsFocusProbeMonitor.tabDirection(for: []) == .forward,
      "the focus probe classifies an unmodified Tab as forward navigation"
    )
    check(
      SettingsFocusProbeMonitor.tabDirection(for: [.shift]) == .backward,
      "the focus probe classifies Shift-Tab as backward navigation"
    )
    check(
      SettingsFocusProbeMonitor.tabDirection(for: [.capsLock]) == .forward,
      "the focus probe ignores Caps Lock while classifying ordinary Tab"
    )
    check(
      SettingsFocusProbeMonitor.tabDirection(for: [.shift, .capsLock]) == .backward,
      "the focus probe ignores Caps Lock while classifying Shift-Tab"
    )
    for rejectedModifiers: NSEvent.ModifierFlags in [
      [.control],
      [.option],
      [.command],
      [.function],
      [.shift, .control],
      [.capsLock, .command],
    ] {
      check(
        SettingsFocusProbeMonitor.tabDirection(for: rejectedModifiers) == nil,
        "the focus probe ignores non-ordinary Tab combinations"
      )
    }

    let focusProbeWindow = RecordingEventWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    var focusProbeMoments: [SettingsFocusProbeMoment] = []
    let focusProbeMonitor = SettingsFocusProbeMonitor(window: focusProbeWindow) { moment in
      focusProbeMoments.append(moment)
    }
    focusProbeMonitor.start()
    defer { focusProbeMonitor.stop() }
    var downstreamLocalMonitorReceivedTab = false
    let downstreamLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == UInt16(kVK_Tab) {
        downstreamLocalMonitorReceivedTab = true
      }
      return event
    }
    guard let downstreamLocalMonitor else {
      check(false, "the native harness installs a downstream local monitor")
      return
    }
    defer { NSEvent.removeMonitor(downstreamLocalMonitor) }

    guard
      let tabEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: focusProbeWindow.windowNumber,
        context: nil,
        characters: "\t",
        charactersIgnoringModifiers: "\t",
        isARepeat: false,
        keyCode: UInt16(kVK_Tab)
      )
    else {
      check(false, "the native harness creates a Tab event")
      return
    }
    NSApp.sendEvent(tabEvent)
    check(
      downstreamLocalMonitorReceivedTab,
      "an app-routed Tab event remains in the local monitor chain with the production focus monitor installed"
    )
    check(
      focusProbeMoments.isEmpty,
      "a hidden settings window records no focus snapshot from an app-routed Tab event"
    )
    check(
      focusProbeWindow.receivedEvent == nil,
      "AppKit does not deliver a key event to an invisible window in the isolated harness"
    )

    let coldStartAudio = FakeAudioCapture()
    let coldStartModelManager = FakeModelManager()
    let coldStartModel = AppModel(
      permissions: permissions,
      hotkeys: FakeHotkeys(),
      coordinator: coordinator,
      audioCapture: coldStartAudio,
      modelManager: coldStartModelManager,
      historyStore: HistoryStore(directory: temporaryDirectory),
      defaults: UserDefaults(suiteName: "shanshuo-cold-start-\(UUID().uuidString)")!
    )
    coldStartModel.audioPreparationWasSubmitted()
    check(
      !coldStartModel.isReadyForFirstDictation,
      "a ready A input cannot make cold start ready before the model is verified"
    )
    coldStartAudio.invalidateReadinessOnSelection = true
    coldStartModel.selectInputDevice(uid: "replacement-B")
    check(
      !coldStartAudio.isAvailable,
      "the production AppModel sees readiness revoked while replacement B is pending"
    )
    coldStartModelManager.status = .ready(location: temporaryDirectory, isReadOnly: true)
    check(
      !coldStartModel.isReadyForFirstDictation,
      "a model becoming ready cannot record cold readiness while B remains unprepared"
    )
    testFormattingSettingsWorkflow()
    testConnectionFeedbackPreservesEnabledState()
    let formattingStore = FormattingConfigurationStore(
      defaults: UserDefaults(suiteName: "shanshuo-formatting-window-\(UUID().uuidString)")!
    )
    let controllers: [NSWindowController] = [
      ModelManagementWindowController(manager: FakeModelManager()),
      OnboardingWindowController(
        model: appModel,
        openAccessibilitySettings: {},
        openModelManagement: {}
      ),
      HistoryWindowController(model: appModel),
      PrivacyWindowController(model: appModel, formattingConfigurationStore: formattingStore),
      FormattingSettingsWindowController(
        configurationStore: formattingStore,
        formatter: DisabledFormattingService()
      ),
      SettingsWindowController(
        model: appModel,
        openAccessibilitySettings: {},
        openKeyboardSettings: {},
        openModelManagement: {},
        openFormattingSettings: {},
        openHistory: {},
        openPrivacy: {}
      ),
    ]

    for controller in controllers {
      guard let contentView = controller.window?.contentView else {
        check(false, "\(type(of: controller)) creates a content view")
        return
      }
      contentView.layoutSubtreeIfNeeded()
      check(!contentView.subviews.isEmpty, "\(type(of: controller)) builds its native content")
    }

    print("native window construction harness passed")
  }
}
