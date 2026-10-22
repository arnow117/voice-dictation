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
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation {
    FakeInsertionOperation()
  }
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
    let controllers: [NSWindowController] = [
      ModelManagementWindowController(manager: FakeModelManager()),
      OnboardingWindowController(
        model: appModel,
        openAccessibilitySettings: {},
        openModelManagement: {}
      ),
      HistoryWindowController(model: appModel),
      PrivacyWindowController(model: appModel),
      SettingsWindowController(
        model: appModel,
        openAccessibilitySettings: {},
        openKeyboardSettings: {},
        openModelManagement: {},
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
