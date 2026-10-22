import AppKit
import Foundation
import ShanshuoCore

final class OnboardingWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate,
  NSTextViewDelegate
{
  private static let practiceTextAccessibilityIdentifier = "shanshuo-onboarding-practice"
  private let model: AppModel
  private let practiceDiagnostics: PerformanceEventRecording
  private let openAccessibilitySettings: () -> Void
  private let openModelManagement: () -> Void
  private let titleLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(wrappingLabelWithString: "")
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let levelIndicator = NSProgressIndicator()
  private let inputDevicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let keyboardSettingsButton = NSButton(title: "打开键盘设置", target: nil, action: nil)
  private let practiceTextView = PracticeTextView(frame: .zero)
  private let previousButton = NSButton(title: "上一步", target: nil, action: nil)
  private let primaryButton = NSButton(title: "继续", target: nil, action: nil)
  private let skipButton = NSButton(title: "跳过", target: nil, action: nil)
  private var currentStep: OnboardingStep
  private var observation: UUID?
  private var outcomeObservation: UUID?
  private var snapshot: AppStatusSnapshot?
  private var microphoneTestResult: MicrophoneTestCompletion?
  private var microphoneTestActive = false
  private var shortcutTestStarted = false
  private var practiceState = PracticeSessionState()
  private var inputDeviceRow: NSStackView?
  private var shortcutRow: NSStackView?
  private var automaticAccessibilityAdvancePending = false
  private var practiceGeneration: UInt64 = 0
  private let microphoneTestStartGate: DeferredActionGate
  private var inputDeviceMenuIsTracking = false
  private var renderedInputDevices: [InputDevice] = []

  init(
    model: AppModel,
    openAccessibilitySettings: @escaping () -> Void,
    openModelManagement: @escaping () -> Void,
    practiceDiagnostics: PerformanceEventRecording = NoopPerformanceEventRecorder(),
    microphoneTestStartGate: DeferredActionGate = DeferredActionGate()
  ) {
    self.model = model
    self.practiceDiagnostics = practiceDiagnostics
    self.openAccessibilitySettings = openAccessibilitySettings
    self.openModelManagement = openModelManagement
    self.microphoneTestStartGate = microphoneTestStartGate
    currentStep = model.onboardingProgress().firstIncomplete()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 430),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "欢迎使用闪说"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    configureWindow()
    observation = model.observe { [weak self] snapshot in
      self?.snapshot = snapshot
      guard self?.window?.isVisible == true else {
        return
      }
      self?.render()
    }
    outcomeObservation = model.observeSessionOutcome { [weak self] outcome in
      self?.receive(outcome)
    }
    model.setOnboardingPracticeBindingProvider { [weak self] pressTarget, attemptID in
      self?.livePracticeBinding(for: pressTarget, attemptID: attemptID)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    if let observation {
      model.removeObserver(observation)
    }
    if let outcomeObservation {
      model.removeSessionOutcomeObserver(outcomeObservation)
    }
    model.clearOnboardingPracticeBindingProvider()
  }

  override func showWindow(_ sender: Any?) {
    currentStep = model.onboardingProgress().firstIncomplete()
    model.visit(currentStep)
    enterCurrentStep()
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if currentStep == .microphoneTest {
      model.refreshInputDevices()
    }
    render()
  }

  func windowWillClose(_ notification: Notification) {
    invalidatePendingMicrophoneTestStart()
    clearTransientPracticeState()
    model.endMicrophoneTest()
  }

  private func configureWindow() {
    guard let contentView = window?.contentView else {
      return
    }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
    ])

    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
    titleLabel.setAccessibilityLabel("设置步骤")
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.maximumNumberOfLines = 0
    detailLabel.setAccessibilityLabel("步骤说明")
    statusLabel.maximumNumberOfLines = 0
    statusLabel.setAccessibilityLabel("当前状态")

    levelIndicator.minValue = 0
    levelIndicator.maxValue = 1
    levelIndicator.isIndeterminate = false
    levelIndicator.doubleValue = 0
    levelIndicator.setAccessibilityLabel("麦克风测试音量")

    inputDevicePopup.target = self
    inputDevicePopup.action = #selector(inputDeviceChanged)
    inputDevicePopup.menu?.delegate = self
    inputDevicePopup.setAccessibilityLabel("本次和后续语音输入使用的麦克风")
    let inputDeviceRow = NSStackView(views: [
      NSTextField(labelWithString: "输入设备："),
      inputDevicePopup,
    ])
    inputDeviceRow.orientation = .horizontal
    inputDeviceRow.alignment = .centerY
    inputDeviceRow.spacing = 8
    self.inputDeviceRow = inputDeviceRow

    shortcutPopup.target = self
    shortcutPopup.action = #selector(shortcutChanged)
    shortcutPopup.setAccessibilityLabel("语音输入快捷键偏好")
    for shortcut in [HoldShortcut.function, .rightOption, .copyOnlyControlShiftSpace] {
      shortcutPopup.addItem(withTitle: shortcutName(shortcut))
      shortcutPopup.lastItem?.representedObject = shortcut.storageValue
    }
    let shortcutRow = NSStackView(views: [
      NSTextField(labelWithString: "快捷键："),
      shortcutPopup,
    ])
    shortcutRow.orientation = .horizontal
    shortcutRow.alignment = .centerY
    shortcutRow.spacing = 8
    self.shortcutRow = shortcutRow
    keyboardSettingsButton.target = self
    keyboardSettingsButton.action = #selector(openKeyboardSettings)
    keyboardSettingsButton.setAccessibilityLabel("打开键盘快捷键设置")

    practiceTextView.isRichText = false
    practiceTextView.isEditable = true
    practiceTextView.isSelectable = true
    practiceTextView.font = .systemFont(ofSize: 14)
    practiceTextView.string = ""
    practiceTextView.setAccessibilityLabel("练习文本")
    practiceTextView.setAccessibilityIdentifier(Self.practiceTextAccessibilityIdentifier)
    practiceTextView.delegate = self
    practiceTextView.onPaste = { [weak self] in
      guard let self, let attemptID = self.practiceState.notePasteRequest() else {
        return
      }
      self.practiceDiagnostics.recordPractice(.pasteObserved, sessionID: attemptID)
      DispatchQueue.main.async {
        self.validatePastedPracticeText()
      }
    }
    let practiceScrollView = NSScrollView()
    practiceScrollView.hasVerticalScroller = true
    practiceScrollView.documentView = practiceTextView
    practiceScrollView.borderType = .bezelBorder
    practiceScrollView.translatesAutoresizingMaskIntoConstraints = false

    previousButton.target = self
    previousButton.action = #selector(previous)
    previousButton.setAccessibilityLabel("返回上一个已访问步骤")
    primaryButton.target = self
    primaryButton.action = #selector(primaryAction)
    primaryButton.keyEquivalent = "\r"
    primaryButton.setAccessibilityLabel("完成当前步骤")
    skipButton.target = self
    skipButton.action = #selector(skip)
    skipButton.setAccessibilityLabel("跳过可跳过步骤")
    let buttonRow = NSStackView(views: [previousButton, skipButton, primaryButton])
    buttonRow.orientation = .horizontal
    buttonRow.alignment = .centerY
    buttonRow.spacing = 8

    stack.addArrangedSubview(titleLabel)
    stack.addArrangedSubview(detailLabel)
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(inputDeviceRow)
    stack.addArrangedSubview(shortcutRow)
    stack.addArrangedSubview(keyboardSettingsButton)
    stack.addArrangedSubview(levelIndicator)
    stack.addArrangedSubview(practiceScrollView)
    stack.addArrangedSubview(buttonRow)
    levelIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    practiceScrollView.heightAnchor.constraint(equalToConstant: 88).isActive = true
    practiceScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  private func render() {
    guard let snapshot, window?.isVisible == true else {
      return
    }
    titleLabel.stringValue = "\(currentStep.title)（\(stepPosition(currentStep))/8）"
    detailLabel.stringValue = detail(for: currentStep)
    previousButton.isEnabled = previousVisitedStep() != nil
    levelIndicator.isHidden = currentStep != .microphoneTest
    inputDeviceRow?.isHidden = currentStep != .microphoneTest
    shortcutRow?.isHidden = currentStep != .shortcut
    let isTestingFn = snapshot.effectiveShortcut == .function && !model.shortcutTestSucceeded
    keyboardSettingsButton.isHidden =
      currentStep != .shortcut || (snapshot.isShortcutAvailable && !isTestingFn)
    practiceTextView.enclosingScrollView?.isHidden = currentStep != .practice
    let canContinueModelDownload = currentStep == .model && !snapshot.modelReady
    skipButton.isHidden =
      currentStep != .microphoneTest
      && currentStep != .accessibility
      && !canContinueModelDownload
    skipButton.title = canContinueModelDownload ? "后台继续" : "跳过"

    switch currentStep {
    case .welcome:
      statusLabel.stringValue = "所有语音识别都在本机完成。按住快捷键时会显示录音提示，录音不会保存。"
      primaryButton.title = "开始设置"
      primaryButton.isEnabled = true
    case .microphone:
      statusLabel.stringValue = permissionText(snapshot.microphonePermission, name: "麦克风")
      primaryButton.title = snapshot.microphonePermission.isAuthorized ? "继续" : "允许麦克风"
      primaryButton.isEnabled = true
    case .accessibility:
      statusLabel.stringValue =
        snapshot.accessibilityPermission.isAuthorized
        ? "辅助功能已授权，可使用直接插入。"
        : "未授权时仍可使用仅复制快捷键 ⌃⇧ Space。"
      primaryButton.title = snapshot.accessibilityPermission.isAuthorized ? "继续" : "打开辅助功能设置"
      primaryButton.isEnabled = true
    case .model:
      statusLabel.stringValue = "模型状态：\(snapshot.modelStatus.summary)"
      primaryButton.title = snapshot.modelReady ? "继续" : "管理语音模型…"
      primaryButton.isEnabled = true
    case .microphoneTest:
      renderMicrophoneTest(snapshot)
    case .shortcut:
      selectShortcut(snapshot.preferredShortcut)
      statusLabel.stringValue = shortcutStatus(snapshot)
      primaryButton.title = model.shortcutTestSucceeded ? "继续" : "开始快捷键测试"
      primaryButton.isEnabled = snapshot.isShortcutAvailable
    case .practice:
      statusLabel.stringValue = practiceStatus(snapshot)
      primaryButton.title = practiceState.succeeded ? "继续" : "等待本次练习结果"
      primaryButton.isEnabled = practiceState.succeeded
    case .complete:
      statusLabel.stringValue = completionStatus(snapshot)
      primaryButton.title = "完成"
      primaryButton.isEnabled = canFinish(snapshot)
    }

    scheduleAccessibilityAdvanceIfNeeded(snapshot)
  }

  private func renderMicrophoneTest(_ snapshot: AppStatusSnapshot) {
    populateInputDevices()
    if let microphoneTestResult {
      switch microphoneTestResult {
      case .detectedSound:
        statusLabel.stringValue = "检测到声音。此测试没有保存或识别任何录音。"
        primaryButton.title = "继续"
      case .noSound:
        statusLabel.stringValue = "没有检测到声音。请检查输入设备或重新测试。"
        primaryButton.title = "重新测试"
      case .cancelled:
        statusLabel.stringValue = "测试已取消。"
        primaryButton.title = "重新测试"
      case .unavailable:
        statusLabel.stringValue = permissionText(snapshot.microphonePermission, name: "麦克风")
        primaryButton.title = "重新测试"
      }
    } else if microphoneTestActive {
      statusLabel.stringValue = "正在测试麦克风。关闭窗口或切换步骤会立即停止采集。"
      primaryButton.title = "测试中…"
    } else {
      statusLabel.stringValue = "开始测试后，请说一句话；只检测实时音量，不会保存或识别录音。"
      primaryButton.title = "开始测试"
    }
    primaryButton.isEnabled = !microphoneTestActive
  }

  @objc private func primaryAction() {
    guard let snapshot else {
      return
    }
    switch currentStep {
    case .welcome:
      completeAndAdvance()
    case .microphone:
      if snapshot.microphonePermission.isAuthorized {
        completeAndAdvance()
      } else if snapshot.microphonePermission == .denied
        || snapshot.microphonePermission == .restricted
      {
        openMicrophoneSettings()
      } else {
        model.requestMicrophoneAccess { [weak self] granted in
          guard let self else {
            return
          }
          if granted {
            self.completeAndAdvance()
          } else {
            self.render()
          }
        }
      }
    case .accessibility:
      if snapshot.accessibilityPermission.isAuthorized {
        completeAndAdvance()
      } else {
        openAccessibilitySettings()
      }
    case .model:
      if snapshot.modelReady {
        completeAndAdvance()
      } else {
        openModelManagement()
      }
    case .microphoneTest:
      if microphoneTestResult == .detectedSound {
        completeAndAdvance()
      } else {
        startMicrophoneTest()
      }
    case .shortcut:
      if model.shortcutTestSucceeded {
        completeAndAdvance()
      } else {
        shortcutTestStarted = true
        model.beginShortcutTest()
        render()
      }
    case .practice:
      if practiceState.succeeded {
        completeAndAdvance()
      }
    case .complete:
      if canFinish(snapshot) {
        model.complete(.complete)
        close()
      }
    }
  }

  @objc private func previous() {
    guard let previous = previousVisitedStep() else {
      return
    }
    leaveCurrentStep()
    currentStep = previous
    model.visit(previous)
    enterCurrentStep()
    render()
  }

  @objc private func skip() {
    if currentStep == .model, snapshot?.modelReady == false {
      advance()
      return
    }
    guard currentStep == .microphoneTest || currentStep == .accessibility else {
      return
    }
    leaveCurrentStep()
    model.skip(currentStep)
    advance()
  }

  @objc private func inputDeviceChanged() {
    let uid = inputDevicePopup.selectedItem?.representedObject as? String
    model.selectInputDevice(uid: uid)
  }

  @objc private func shortcutChanged() {
    guard let value = shortcutPopup.selectedItem?.representedObject as? String,
      let shortcut = HoldShortcut(storageValue: value)
    else {
      return
    }
    model.setPreferredShortcut(shortcut)
  }

  @objc private func openKeyboardSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func openMicrophoneSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func startMicrophoneTest() {
    microphoneTestResult = nil
    microphoneTestActive = true
    levelIndicator.doubleValue = 0.001
    render()
    // `render` makes the indicator visible before this deferred start. Closing the window or
    // leaving this step invalidates the gate, so an old main-queue turn cannot start capture.
    microphoneTestStartGate.schedule(
      when: { [weak self] in
        self?.isMicrophoneTestStartEligible == true
      },
      action: { [weak self] in
        guard let self else {
          return
        }
        let started = self.model.beginMicrophoneTest(
          indicatorVisible: self.isMicrophoneTestIndicatorVisible,
          onLevel: { [weak self] level in
            self?.levelIndicator.doubleValue = min(1, Double(level) * 12)
          },
          completion: { [weak self] result in
            guard let self, self.currentStep == .microphoneTest else {
              return
            }
            self.microphoneTestResult = result
            self.microphoneTestActive = false
            self.render()
          }
        )
        if !started {
          self.microphoneTestActive = false
          self.microphoneTestResult = .unavailable
          self.render()
        }
      }
    )
  }

  private func completeAndAdvance() {
    guard completionRequirementsMet() else {
      render()
      return
    }
    model.complete(currentStep)
    advance()
  }

  private func advance() {
    guard let index = OnboardingStep.allCases.firstIndex(of: currentStep),
      index + 1 < OnboardingStep.allCases.count
    else {
      return
    }
    leaveCurrentStep()
    currentStep = OnboardingStep.allCases[index + 1]
    model.visit(currentStep)
    enterCurrentStep()
    render()
  }

  private func leaveCurrentStep() {
    if currentStep == .microphoneTest {
      invalidatePendingMicrophoneTestStart()
      model.endMicrophoneTest()
    }
    if currentStep == .practice {
      clearTransientPracticeState()
    }
  }

  private func enterCurrentStep() {
    guard currentStep == .practice else {
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.currentStep == .practice else {
        return
      }
      self.window?.makeFirstResponder(self.practiceTextView)
    }
  }

  private func scheduleAccessibilityAdvanceIfNeeded(_ snapshot: AppStatusSnapshot) {
    guard currentStep == .accessibility,
      snapshot.accessibilityPermission.isAuthorized,
      !snapshot.onboardingProgress.completed.contains(.accessibility),
      !automaticAccessibilityAdvancePending
    else {
      return
    }
    automaticAccessibilityAdvancePending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      self.automaticAccessibilityAdvancePending = false
      guard self.currentStep == .accessibility,
        self.snapshot?.accessibilityPermission.isAuthorized == true
      else {
        return
      }
      self.completeAndAdvance()
    }
  }

  private func completionRequirementsMet() -> Bool {
    guard let snapshot else {
      return false
    }
    switch currentStep {
    case .microphone:
      return snapshot.microphonePermission.isAuthorized
    case .accessibility:
      return snapshot.accessibilityPermission.isAuthorized
    case .model:
      return snapshot.modelReady
    case .microphoneTest:
      return microphoneTestResult == .detectedSound
    case .shortcut:
      return model.shortcutTestSucceeded && snapshot.isShortcutAvailable
    case .practice:
      return practiceState.succeeded
    case .complete:
      return canFinish(snapshot)
    case .welcome:
      return true
    }
  }

  private func canFinish(_ snapshot: AppStatusSnapshot) -> Bool {
    snapshot.microphonePermission.isAuthorized
      && snapshot.modelReady
      && snapshot.isShortcutAvailable
      && (practiceState.succeeded || snapshot.onboardingProgress.completed.contains(.practice))
  }

  private func previousVisitedStep() -> OnboardingStep? {
    guard let index = OnboardingStep.allCases.firstIndex(of: currentStep), index > 0 else {
      return nil
    }
    for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
      let candidate = OnboardingStep.allCases[candidateIndex]
      if model.onboardingProgress().hasVisited(candidate) {
        return candidate
      }
    }
    return nil
  }

  private func receive(_ outcome: SessionOutcome) {
    guard case .onboardingPractice(let binding) = outcome.purpose else {
      return
    }

    practiceDiagnostics.recordPractice(.outcomeReceived, sessionID: outcome.sessionID)
    guard currentStep == .practice else {
      practiceDiagnostics.recordPractice(.outcomeStepInactive, sessionID: outcome.sessionID)
      return
    }

    let targetMatches =
      binding.matches(outcome.target)
      && binding.target.elementIdentifier == Self.practiceTextAccessibilityIdentifier
    guard targetMatches else {
      practiceDiagnostics.recordPractice(.outcomeTargetMismatch, sessionID: outcome.sessionID)
      return
    }
    practiceDiagnostics.recordPractice(.outcomeTargetMatched, sessionID: outcome.sessionID)

    guard binding.attemptID == outcome.sessionID else {
      practiceDiagnostics.recordPractice(
        .validation(.attemptMismatch),
        sessionID: outcome.sessionID
      )
      return
    }

    switch outcome.delivery {
    case .inserted, .unverified:
      verifyDirectPracticeReadback(
        expectedText: outcome.finalText,
        attemptID: binding.attemptID,
        delivery: outcome.delivery
      )
    case .copied:
      practiceState.expectCopiedText(outcome.finalText, attemptID: binding.attemptID)
      statusLabel.stringValue = "已复制本次结果。请在下面按 ⌘V 粘贴这次结果完成练习。"
    }
  }

  private func verifyDirectPracticeReadback(
    expectedText: String,
    attemptID: UUID,
    delivery: SessionOutcome.Delivery
  ) {
    let expectedGeneration = practiceGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }

      guard self.currentStep == .practice, self.practiceGeneration == expectedGeneration else {
        self.practiceDiagnostics.recordPractice(
          .validation(.generationInvalidated),
          sessionID: attemptID
        )
        return
      }

      let validation = self.practiceState.validateDirectReadback(
        self.practiceTextView.string,
        expectedText: expectedText,
        attemptID: attemptID,
        isVerifiedDirectInsertion: delivery == .inserted
      )
      self.practiceDiagnostics.recordPractice(.validation(validation), sessionID: attemptID)
      guard validation == .verified else {
        return
      }
      self.render()
    }
  }

  private func validatePastedPracticeText() {
    guard currentStep == .practice, let attemptID = practiceState.activeAttemptID else {
      return
    }

    let validation = practiceState.validatePastedReadback(practiceTextView.string)
    practiceDiagnostics.recordPractice(.validation(validation), sessionID: attemptID)
    guard validation == .verified else {
      return
    }
    render()
  }

  private func clearTransientPracticeState() {
    practiceGeneration &+= 1
    model.cancelOnboardingPracticeSession()
    practiceState.clear()
    practiceTextView.string = ""
  }

  /// The practice purpose is sampled on every global-key press. A stale focus snapshot is never
  /// enough: the same visible onboarding window must still own the exact native text responder.
  private func livePracticeBinding(
    for pressTarget: TargetSnapshot,
    attemptID: UUID
  ) -> PracticeSessionBinding? {
    guard currentStep == .practice else {
      practiceDiagnostics.recordPractice(.bindingRejected(.stepInactive), sessionID: attemptID)
      return nil
    }
    guard let window else {
      practiceDiagnostics.recordPractice(.bindingRejected(.windowUnavailable), sessionID: attemptID)
      return nil
    }
    guard window.isVisible else {
      practiceDiagnostics.recordPractice(.bindingRejected(.windowHidden), sessionID: attemptID)
      return nil
    }
    guard window.isKeyWindow else {
      practiceDiagnostics.recordPractice(.bindingRejected(.windowNotKey), sessionID: attemptID)
      return nil
    }
    guard window.firstResponder === practiceTextView else {
      practiceDiagnostics.recordPractice(.bindingRejected(.responderMismatch), sessionID: attemptID)
      return nil
    }
    guard practiceTextView.window === window else {
      practiceDiagnostics.recordPractice(.bindingRejected(.textViewDetached), sessionID: attemptID)
      return nil
    }
    guard practiceTextView.isEditable else {
      practiceDiagnostics.recordPractice(
        .bindingRejected(.textViewNotEditable), sessionID: attemptID)
      return nil
    }
    guard !practiceTextView.isHidden else {
      practiceDiagnostics.recordPractice(.bindingRejected(.textViewHidden), sessionID: attemptID)
      return nil
    }
    guard !pressTarget.isSecure else {
      practiceDiagnostics.recordPractice(.bindingRejected(.secureTarget), sessionID: attemptID)
      return nil
    }

    let expectedTarget = TargetSnapshot(
      bundleIdentifier: Bundle.main.bundleIdentifier,
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      elementIdentifier: Self.practiceTextAccessibilityIdentifier,
      isEditable: true,
      isSecure: false
    )
    let binding = PracticeSessionBinding(target: expectedTarget, attemptID: attemptID)
    guard binding.matches(pressTarget) else {
      practiceDiagnostics.recordPractice(.bindingRejected(.targetMismatch), sessionID: attemptID)
      return nil
    }
    practiceState.beginAttempt(binding.attemptID, initialText: practiceTextView.string)
    practiceDiagnostics.recordPractice(.bindingAccepted, sessionID: attemptID)
    return binding
  }

  private var isMicrophoneTestStartEligible: Bool {
    currentStep == .microphoneTest
      && microphoneTestActive
      && window?.isVisible == true
      && isMicrophoneTestIndicatorVisible
  }

  private var isMicrophoneTestIndicatorVisible: Bool {
    guard !levelIndicator.isHidden,
      let window,
      levelIndicator.window === window
    else {
      return false
    }
    return window.isVisible
  }

  private func invalidatePendingMicrophoneTestStart() {
    microphoneTestStartGate.invalidate()
    microphoneTestActive = false
  }

  private func populateInputDevices() {
    let selectedUID = model.selectedInputDeviceUID()
    let devices = model.inputDevices()

    if devices != renderedInputDevices {
      guard !inputDeviceMenuIsTracking else {
        return
      }
      inputDevicePopup.removeAllItems()
      inputDevicePopup.addItem(withTitle: "跟随系统默认")
      inputDevicePopup.lastItem?.representedObject = nil
      for device in devices {
        inputDevicePopup.addItem(withTitle: device.name)
        inputDevicePopup.lastItem?.representedObject = device.uid
      }
      renderedInputDevices = devices
    }

    guard !inputDeviceMenuIsTracking else {
      return
    }
    guard let selectedUID else {
      if inputDevicePopup.indexOfSelectedItem != 0 {
        inputDevicePopup.selectItem(at: 0)
      }
      return
    }
    if let selectedItem = inputDevicePopup.itemArray.first(where: {
      ($0.representedObject as? String) == selectedUID
    }) {
      if inputDevicePopup.selectedItem !== selectedItem {
        inputDevicePopup.select(selectedItem)
      }
    } else {
      if inputDevicePopup.indexOfSelectedItem != 0 {
        inputDevicePopup.selectItem(at: 0)
      }
      statusLabel.stringValue = "上次选择的输入设备不可用；请重新选择或跟随系统默认。"
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    if menu == inputDevicePopup.menu {
      model.refreshInputDevices()
      inputDeviceMenuIsTracking = true
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    guard menu == inputDevicePopup.menu else {
      return
    }
    inputDeviceMenuIsTracking = false
    populateInputDevices()
  }

  private func selectShortcut(_ shortcut: HoldShortcut) {
    if shortcutPopup.itemArray.contains(where: {
      ($0.representedObject as? String) == shortcut.storageValue
    }) {
      shortcutPopup.selectItem(withTitle: shortcutName(shortcut))
      return
    }
    shortcutPopup.addItem(withTitle: shortcutName(shortcut))
    shortcutPopup.lastItem?.representedObject = shortcut.storageValue
    shortcutPopup.selectItem(withTitle: shortcutName(shortcut))
  }

  private func detail(for step: OnboardingStep) -> String {
    switch step {
    case .welcome:
      return "用一次简短设置，让闪说在你需要的地方把语音转成文字。"
    case .microphone:
      return "闪说只会在你按住快捷键或主动测试麦克风时采集音频。"
    case .accessibility:
      return "辅助功能授权后可直接插入文字；未授权时会安全地只复制结果。"
    case .model:
      return "下载并验证唯一的本地 Qwen3-ASR 语音模型。"
    case .microphoneTest:
      return "确认当前输入设备能接收到你的声音。"
    case .shortcut:
      return "实际按住并松开当前快捷键，确认它没有被系统或其他应用占用。"
    case .practice:
      return "用一次真实识别结果完成练习。不会保存练习文本或音频。"
    case .complete:
      return "检查当前可用状态后完成设置。"
    }
  }

  private func shortcutStatus(_ snapshot: AppStatusSnapshot) -> String {
    if !snapshot.isShortcutAvailable {
      return "快捷键当前不可用。请检查系统快捷键设置后重试。"
    }
    if shortcutTestStarted && model.shortcutTestSucceeded {
      return "已检测到真实按下和松开。"
    }
    if snapshot.effectiveShortcut == .function {
      return "当前有效快捷键：Fn。无法自动确认系统是否占用 Fn；请完成一次实际按住/松开测试，必要时打开键盘设置。"
    }
    return "当前有效快捷键：\(shortcutName(snapshot.effectiveShortcut))。"
  }

  private func practiceStatus(_ snapshot: AppStatusSnapshot) -> String {
    guard snapshot.microphonePermission.isAuthorized, snapshot.modelReady else {
      return "请先完成麦克风和模型步骤，再进行练习。"
    }
    if practiceState.succeeded {
      return "已收到并验证本次练习结果。"
    }
    return "把焦点放在练习框，按住快捷键说一句话；直接插入或复制后粘贴都可以完成。"
  }

  private func completionStatus(_ snapshot: AppStatusSnapshot) -> String {
    if canFinish(snapshot) {
      return "设置完成。之后可从菜单栏继续管理模型、历史和隐私。"
    }
    return "仍需确认麦克风、模型、快捷键和真实练习结果。"
  }

  private func permissionText(_ status: PermissionStatus, name: String) -> String {
    switch status {
    case .authorized:
      return "\(name)已授权。"
    case .notDetermined:
      return "尚未请求\(name)权限。"
    case .denied, .restricted:
      return "\(name)未授权。可在系统设置中修改后继续，无需重启。"
    }
  }

  private func shortcutName(_ shortcut: HoldShortcut) -> String {
    shortcut.displayName
  }

  private func stepPosition(_ step: OnboardingStep) -> Int {
    (OnboardingStep.allCases.firstIndex(of: step) ?? 0) + 1
  }
}

private final class PracticeTextView: NSTextView {
  var onPaste: (() -> Void)?

  override func paste(_ sender: Any?) {
    onPaste?()
    super.paste(sender)
  }
}
