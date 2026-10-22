import AppKit
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
  let isAvailable = true
  var onInterruption: ((AudioCaptureOperation) -> Void)?
  var availableInputDevices: [InputDevice] = [InputDevice(uid: "default", name: "Default")]
  var selectedInputDeviceUID: String?

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
  let isShortcutAvailable = true
  var onHold: ((HoldShortcut, Bool) -> Void)?
  var onCancel: (() -> Void)?
  var onOtherKey: (() -> Void)?
  var selectedShortcut: HoldShortcut = .function

  func refresh(accessibilityAuthorized: Bool) {}
  func setCancellationInterception(_ enabled: Bool) {}
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
    let controllers: [NSWindowController] = [
      ModelManagementWindowController(manager: FakeModelManager()),
      OnboardingWindowController(
        model: appModel,
        openAccessibilitySettings: {},
        openModelManagement: {}
      ),
      HistoryWindowController(model: appModel),
      PrivacyWindowController(model: appModel),
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
