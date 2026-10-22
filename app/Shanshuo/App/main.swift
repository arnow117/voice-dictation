import AppKit
import ShanshuoCore

// `--transcribe` is an explicit developer/test entry point. The menu-bar application never writes
// recognized text to diagnostics or standard output.
let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "--transcribe" {
  exit(CLI.transcribe(Array(arguments.dropFirst(2))))
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private let modelItem = NSMenuItem(title: "语音模型：加载中…", action: nil, keyEquivalent: "")
  private let sessionItem = NSMenuItem(title: "状态：就绪", action: nil, keyEquivalent: "")
  private let accessItem = NSMenuItem(title: "直接插入：检查中…", action: nil, keyEquivalent: "")
  private let hotkeyItem = NSMenuItem(title: "快捷键：检查中…", action: nil, keyEquivalent: "")
  private var stateTimer: Timer?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var distributedObservers: [NSObjectProtocol] = []

  private let permissions = SystemPermissionService()
  private let focusInspector = SystemFocusInspector()
  private let audioCapture = MemoryAudioCapture()
  private let hotkeys = SystemHotkeyMonitor()
  private let soundPlayer = SystemRecordingSoundPlayer()
  private var recognizer: Qwen3ASRService!
  private var coordinator: DictationCoordinator!
  private var modelManager: ModelManager?
  private var modelWindowController: ModelManagementWindowController?
  private var modelObservation: UUID?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let statusButton = statusItem.button else {
      return
    }
    statusButton.image = NSImage(
      systemSymbolName: "waveform", accessibilityDescription: ShanshuoInfo.displayName)

    statusItem.menu = makeMenu()
    let pill = RecordingPill(
      statusButton: statusButton,
      statusMenuItem: sessionItem,
      soundPlayer: soundPlayer,
      requestDirectInsertion: { [weak self] in
        self?.openAccessibilitySettings()
      }
    )
    recognizer = Qwen3ASRService()
    let inserter = SystemTextInserter(permissions: permissions, focusInspector: focusInspector)
    coordinator = DictationCoordinator(
      permissions: permissions,
      focusInspector: focusInspector,
      indicator: pill,
      audioCapture: audioCapture,
      recognizer: recognizer,
      textInserter: inserter,
      hotkeys: hotkeys
    )
    hotkeys.onHold = { [weak self] shortcut, isPressed in
      self?.coordinator.hotkeyChanged(shortcut, isPressed: isPressed)
    }
    hotkeys.onCancel = { [weak self] in
      self?.coordinator.cancelFromHotkey()
    }
    hotkeys.onOtherKey = { [weak self] in
      self?.coordinator.cancelForOtherKey()
    }

    configureModelManager()
    installSystemObservers()
    refreshSystemState()
    coordinator.prepareAudio()
  }

  func applicationWillTerminate(_ notification: Notification) {
    stateTimer?.invalidate()
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    for observer in distributedObservers {
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    hotkeys.stop()
    coordinator?.cancelForSystemInterruption()
    recognizer?.unload()
    if let modelObservation {
      modelManager?.removeObserver(modelObservation)
    }
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(
      NSMenuItem(
        title: "\(ShanshuoInfo.displayName) \(Paths.version)（\(Paths.buildID)）",
        action: nil,
        keyEquivalent: ""
      ))
    menu.addItem(sessionItem)
    menu.addItem(modelItem)
    let manageModelItem = NSMenuItem(
      title: "管理语音模型…",
      action: #selector(openModelManagement),
      keyEquivalent: ""
    )
    manageModelItem.target = self
    menu.addItem(manageModelItem)
    menu.addItem(accessItem)
    menu.addItem(hotkeyItem)
    menu.addItem(
      NSMenuItem(title: "开启直接插入…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "退出\(ShanshuoInfo.displayName)", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    return menu
  }

  private func configureModelManager() {
    do {
      let manifest = try Qwen3ModelManifest.loadBundled()
      let manager = ModelManager(
        manifest: manifest,
        ownedDirectory: Paths.ownedModelDirectory,
        readOnlySeedDirectory: Paths.readOnlyModelSeedDirectory,
        runtime: recognizer
      )
      manager.onWillMutate = { [weak self] in
        self?.coordinator.cancelForModelChange()
      }
      modelManager = manager
      modelWindowController = ModelManagementWindowController(manager: manager)
      modelObservation = manager.observe { [weak self] status in
        self?.updateModelMenu(status)
      }
      manager.bootstrap()
    } catch {
      modelItem.title = "语音模型：配置错误"
    }
  }

  private func updateModelMenu(_ status: ModelManagerStatus) {
    switch status {
    case .ready:
      modelItem.title = "语音模型：就绪"
    case .downloading:
      modelItem.title = "语音模型：正在下载"
    case .paused:
      modelItem.title = "语音模型：下载已暂停"
    case .loading:
      modelItem.title = "语音模型：正在加载"
    case .deleting:
      modelItem.title = "语音模型：正在删除"
    case .checking:
      modelItem.title = "语音模型：正在检查"
    case .repairRequired, .failed:
      modelItem.title = "语音模型：需要修复"
    }
    refreshSystemState()
  }

  private func refreshSystemState() {
    coordinator?.refreshSystemState()
    if permissions.accessibilityPermission.isAuthorized {
      accessItem.title = "直接插入：已授权"
    } else {
      accessItem.title = "直接插入：未授权（仅复制模式 ⌃⇧ Space）"
    }
    hotkeyItem.title = hotkeys.isShortcutAvailable ? "快捷键：就绪" : "快捷键：不可用，请检查设置"
  }

  private func installSystemObservers() {
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.refreshSystemState()
    }
    RunLoop.main.add(timer, forMode: .common)
    stateTimer = timer

    let notificationCenter = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.coordinator.cancelForSystemInterruption()
      }
    )
    workspaceObservers.append(
      notificationCenter.addObserver(
        forName: NSWorkspace.screensDidSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.coordinator.cancelForSystemInterruption()
      }
    )
    distributedObservers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.screenIsLocked"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.coordinator.cancelForSystemInterruption()
      }
    )
    workspaceObservers.append(
      notificationCenter.addObserver(
        forName: NSWorkspace.sessionDidResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.coordinator.cancelForSystemInterruption()
      }
    )
  }

  @objc private func openAccessibilitySettings() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    if let url {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func openModelManagement() {
    modelWindowController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
