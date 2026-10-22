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
  private let pauseOneHourItem = NSMenuItem(title: "暂停 1 小时", action: nil, keyEquivalent: "")
  private let pauseUntilManualItem = NSMenuItem(
    title: "暂停直到手动恢复", action: nil, keyEquivalent: "")
  private let resumeItem = NSMenuItem(title: "恢复语音输入", action: nil, keyEquivalent: "")
  private var stateTimer: Timer?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var distributedObservers: [NSObjectProtocol] = []

  private let performanceDiagnostics = LocalPerformanceDiagnostics()
  private let processStartSessionID = UUID()
  private let permissions = SystemPermissionService()
  private let focusInspector = SystemFocusInspector()
  private lazy var audioCapture = MemoryAudioCapture(
    performanceDiagnostics: performanceDiagnostics
  )
  private let hotkeys = SystemHotkeyMonitor()
  private let soundPlayer = SystemRecordingSoundPlayer()
  private var recognizer: Qwen3ASRService!
  private var coordinator: DictationCoordinator!
  private var modelManager: ModelManager?
  private var modelWindowController: ModelManagementWindowController?
  private var onboardingWindowController: OnboardingWindowController?
  private var historyWindowController: HistoryWindowController?
  private var privacyWindowController: PrivacyWindowController?
  private var settingsWindowController: SettingsWindowController?
  private var appModel: AppModel?
  private var modelObservation: UUID?
  private var didRecordColdStartReady = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let processStartTimestamp = ProcessStartTimestamp.currentProcess() {
      performanceDiagnostics.record(
        kind: .processStarted,
        result: .observed,
        sessionID: processStartSessionID,
        timestamp: processStartTimestamp,
        audioDuration: nil
      )
    }
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    guard let statusButton = statusItem.button else {
      return
    }
    statusButton.image = NSImage(
      systemSymbolName: "waveform", accessibilityDescription: ShanshuoInfo.displayName)

    statusItem.menu = makeMenu()
    NSApp.mainMenu = makeApplicationMenu()
    let pill = RecordingPill(
      statusButton: statusButton,
      statusMenuItem: sessionItem,
      soundPlayer: soundPlayer,
      requestDirectInsertion: { [weak self] in
        self?.openAccessibilitySettings()
      }
    )
    recognizer = Qwen3ASRService()
    let inserter = SystemTextInserter(
      permissions: permissions,
      focusInspector: focusInspector,
      performanceDiagnostics: performanceDiagnostics
    )
    coordinator = DictationCoordinator(
      permissions: permissions,
      focusInspector: focusInspector,
      indicator: pill,
      audioCapture: audioCapture,
      recognizer: recognizer,
      textInserter: inserter,
      hotkeys: hotkeys,
      performanceDiagnostics: performanceDiagnostics,
      onSessionOutcome: { [weak self] outcome in
        self?.appModel?.handleSessionOutcome(outcome)
      }
    )
    hotkeys.onHold = { [weak self] shortcut, isPressed in
      self?.coordinator.hotkeyChanged(shortcut, isPressed: isPressed)
      self?.appModel?.recordHotkeyEvent(shortcut, isPressed: isPressed)
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
    appModel?.audioPreparationWasSubmitted()
    recordColdStartReadyIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.openOnboardingIfNeeded()
    }
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
    performanceDiagnostics.flush()
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
    let continueSetupItem = NSMenuItem(
      title: "继续设置…", action: #selector(openOnboarding), keyEquivalent: "")
    continueSetupItem.target = self
    menu.addItem(continueSetupItem)
    let manageModelItem = NSMenuItem(
      title: "管理语音模型…",
      action: #selector(openModelManagement),
      keyEquivalent: ""
    )
    manageModelItem.target = self
    menu.addItem(manageModelItem)
    let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
    settingsItem.target = self
    menu.addItem(settingsItem)
    menu.addItem(accessItem)
    menu.addItem(hotkeyItem)
    pauseOneHourItem.target = self
    pauseOneHourItem.action = #selector(pauseForOneHour)
    menu.addItem(pauseOneHourItem)
    pauseUntilManualItem.target = self
    pauseUntilManualItem.action = #selector(pauseUntilManualResume)
    menu.addItem(pauseUntilManualItem)
    resumeItem.target = self
    resumeItem.action = #selector(resumeDictation)
    menu.addItem(resumeItem)
    let historyItem = NSMenuItem(
      title: "语音输入历史…", action: #selector(openHistory), keyEquivalent: "")
    historyItem.target = self
    menu.addItem(historyItem)
    let privacyItem = NSMenuItem(title: "隐私…", action: #selector(openPrivacy), keyEquivalent: "")
    privacyItem.target = self
    menu.addItem(privacyItem)
    menu.addItem(
      NSMenuItem(title: "开启直接插入…", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(
      NSMenuItem(
        title: "退出\(ShanshuoInfo.displayName)", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"))
    return menu
  }

  /// An accessory application still needs a main menu while one of its native windows is key.
  /// Status-item key equivalents alone do not receive Command-Comma from the focused window.
  private func makeApplicationMenu() -> NSMenu {
    let mainMenu = NSMenu()
    let applicationItem = NSMenuItem(
      title: ShanshuoInfo.displayName, action: nil, keyEquivalent: "")
    let applicationMenu = NSMenu(title: ShanshuoInfo.displayName)

    let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
    settingsItem.target = self
    applicationMenu.addItem(settingsItem)
    applicationMenu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "退出\(ShanshuoInfo.displayName)",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    quitItem.target = NSApp
    applicationMenu.addItem(quitItem)

    applicationItem.submenu = applicationMenu
    mainMenu.addItem(applicationItem)
    return mainMenu
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
      let appModel = AppModel(
        permissions: permissions,
        hotkeys: hotkeys,
        coordinator: coordinator,
        audioCapture: audioCapture,
        modelManager: manager,
        historyStore: HistoryStore(directory: Paths.historyDirectory),
        soundPreference: soundPlayer
      )
      self.appModel = appModel
      onboardingWindowController = OnboardingWindowController(
        model: appModel,
        openAccessibilitySettings: { [weak self] in
          self?.openAccessibilitySettings()
        },
        openModelManagement: { [weak self] in
          self?.openModelManagement()
        },
        practiceDiagnostics: performanceDiagnostics
      )
      historyWindowController = HistoryWindowController(model: appModel)
      privacyWindowController = PrivacyWindowController(model: appModel)
      settingsWindowController = SettingsWindowController(
        model: appModel,
        openAccessibilitySettings: { [weak self] in self?.openAccessibilitySettings() },
        openKeyboardSettings: { [weak self] in self?.openKeyboardSettings() },
        openModelManagement: { [weak self] in self?.openModelManagement() },
        openHistory: { [weak self] in self?.openHistory() },
        openPrivacy: { [weak self] in self?.openPrivacy() }
      )
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
    appModel?.refreshLiveState()
    if appModel == nil {
      coordinator?.refreshSystemState()
    }
    if permissions.accessibilityPermission.isAuthorized {
      accessItem.title = "直接插入：已授权"
    } else {
      accessItem.title = "直接插入：未授权（仅复制模式 ⌃⇧ Space）"
    }
    hotkeyItem.title = hotkeys.isShortcutAvailable ? "快捷键：就绪" : "快捷键：不可用，请检查设置"
    if let appModel {
      let pauseMenu = PauseMenuPresentation(snapshot: appModel.pauseSnapshot())
      pauseOneHourItem.isHidden = !pauseMenu.showPauseForOneHour
      pauseUntilManualItem.isHidden = !pauseMenu.showPauseUntilManualResume
      resumeItem.isHidden = !pauseMenu.showResume
    }
    recordColdStartReadyIfNeeded()
  }

  private func recordColdStartReadyIfNeeded() {
    guard !didRecordColdStartReady,
      let appModel,
      appModel.isReadyForFirstDictation
    else {
      return
    }
    didRecordColdStartReady = true
    performanceDiagnostics.record(
      kind: .coldStartReady,
      result: .ready,
      sessionID: processStartSessionID
    )
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

  @objc private func openOnboarding() {
    onboardingWindowController?.showWindow(nil)
  }

  @objc private func openSettings() {
    settingsWindowController?.showWindow(nil)
  }

  @objc private func openHistory() {
    historyWindowController?.showWindow(nil)
  }

  @objc private func openPrivacy() {
    privacyWindowController?.showWindow(nil)
  }

  @objc private func pauseForOneHour() {
    guard let appModel else {
      return
    }
    appModel.pauseForOneHour()
    refreshSystemState()
  }

  @objc private func pauseUntilManualResume() {
    guard let appModel else {
      return
    }
    appModel.pauseUntilManualResume()
    refreshSystemState()
  }

  @objc private func resumeDictation() {
    guard let appModel else {
      return
    }
    appModel.resumeDictation()
    refreshSystemState()
  }

  private func openKeyboardSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func openOnboardingIfNeeded() {
    guard let appModel,
      !appModel.onboardingProgress().completed.contains(.complete)
    else {
      return
    }
    onboardingWindowController?.showWindow(nil)
  }
}
