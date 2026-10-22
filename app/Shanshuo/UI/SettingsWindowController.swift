import AppKit
import Carbon

/// Native settings surface for the T014 options. It only edits the app's stored preferences; it
/// never changes macOS's default input device or global keyboard settings.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
  private struct ShortcutChoice: Equatable {
    let title: String
    let storageValue: String
  }

  private let model: AppModel
  private let openAccessibilitySettings: () -> Void
  private let openKeyboardSettings: () -> Void
  private let openModelManagement: () -> Void
  private let openHistory: () -> Void
  private let openPrivacy: () -> Void

  private let shortcutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
  private let shortcutCapture = HotkeyCaptureView(frame: .zero)
  private let inputDevicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let soundButton = NSButton(checkboxWithTitle: "播放开始录音提示音", target: nil, action: nil)
  private let modelStatus = NSTextField(wrappingLabelWithString: "")
  private let historyStatus = NSTextField(wrappingLabelWithString: "")
  private let privacyStatus = NSTextField(wrappingLabelWithString: "")
  private var observation: UUID?
  private var isRecordingShortcut = false
  private var shortcutFeedbackOverride: String?
  private var shortcutMenuIsTracking = false
  private var inputDeviceMenuIsTracking = false
  private var renderedShortcutChoices: [ShortcutChoice] = []
  private var renderedInputDevices: [InputDevice] = []

  init(
    model: AppModel,
    openAccessibilitySettings: @escaping () -> Void,
    openKeyboardSettings: @escaping () -> Void,
    openModelManagement: @escaping () -> Void,
    openHistory: @escaping () -> Void,
    openPrivacy: @escaping () -> Void
  ) {
    self.model = model
    self.openAccessibilitySettings = openAccessibilitySettings
    self.openKeyboardSettings = openKeyboardSettings
    self.openModelManagement = openModelManagement
    self.openHistory = openHistory
    self.openPrivacy = openPrivacy

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "闪说设置"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    configureWindow()
    observation = model.observe { [weak self] snapshot in
      self?.render(snapshot)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    if let observation {
      model.removeObserver(observation)
    }
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    stopShortcutRecording()
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
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
    ])

    let title = NSTextField(labelWithString: "通用")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.setAccessibilityLabel("通用设置")

    shortcutPopup.target = self
    shortcutPopup.action = #selector(shortcutChanged)
    shortcutPopup.menu?.delegate = self
    shortcutPopup.setAccessibilityLabel("按住说话的快捷键")
    shortcutCapture.setAccessibilityLabel("录入自定义快捷键")
    shortcutCapture.onCapture = { [weak self] shortcut in
      self?.commitShortcut(shortcut)
    }
    shortcutCapture.onError = { [weak self] message in
      self?.showShortcutFeedback(message)
    }
    shortcutCapture.onCancel = { [weak self] in
      self?.stopShortcutRecording()
    }
    shortcutCapture.isHidden = true

    let shortcutRow = row(
      title: "快捷键",
      detail: "按住说话，松开结束。录入组合键时全局触发会暂停。",
      control: shortcutPopup
    )
    let captureButton = NSButton(
      title: "录入自定义组合键…", target: self, action: #selector(startShortcutRecording))
    captureButton.setAccessibilityLabel("录入自定义按住快捷键")
    let keyboardSettingsButton = NSButton(
      title: "打开键盘设置", target: self, action: #selector(openKeyboardSettingsAction))
    keyboardSettingsButton.setAccessibilityLabel("打开 macOS 键盘快捷键设置")

    inputDevicePopup.target = self
    inputDevicePopup.action = #selector(inputDeviceChanged)
    inputDevicePopup.menu?.delegate = self
    inputDevicePopup.setAccessibilityLabel("语音输入设备")
    let inputRow = row(
      title: "输入设备",
      detail: "只设置闪说的下一次采集，不会修改 macOS 默认输入设备。",
      control: inputDevicePopup
    )

    soundButton.target = self
    soundButton.action = #selector(soundChanged)
    soundButton.setAccessibilityLabel("播放开始录音提示音")
    let soundRow = row(
      title: "提示音",
      detail: "关闭后，录音胶囊和菜单栏的录音状态仍始终显示。",
      control: soundButton
    )

    let permissionButton = NSButton(
      title: "开启直接插入…", target: self, action: #selector(openAccessibilitySettingsAction))
    permissionButton.setAccessibilityLabel("打开辅助功能设置以开启直接插入")
    let permissionRow = row(
      title: "直接插入",
      detail: "辅助功能未授权时，闪说固定使用 ⌃⇧ Space 并仅复制结果。",
      control: permissionButton
    )

    let integrationTitle = NSTextField(labelWithString: "语音模型、历史与隐私")
    integrationTitle.font = .systemFont(ofSize: 17, weight: .semibold)
    let modelButton = NSButton(
      title: "管理语音模型…", target: self, action: #selector(openModelManagementAction))
    let historyButton = NSButton(
      title: "语音输入历史…", target: self, action: #selector(openHistoryAction))
    let privacyButton = NSButton(title: "隐私…", target: self, action: #selector(openPrivacyAction))
    modelButton.setAccessibilityLabel("打开语音模型管理")
    historyButton.setAccessibilityLabel("打开语音输入历史")
    privacyButton.setAccessibilityLabel("打开隐私说明")
    modelStatus.maximumNumberOfLines = 0
    historyStatus.maximumNumberOfLines = 0
    privacyStatus.maximumNumberOfLines = 0
    modelStatus.textColor = .secondaryLabelColor
    historyStatus.textColor = .secondaryLabelColor
    privacyStatus.textColor = .secondaryLabelColor

    stack.addArrangedSubview(title)
    stack.addArrangedSubview(shortcutRow)
    stack.addArrangedSubview(shortcutStatus)
    stack.addArrangedSubview(captureButton)
    stack.addArrangedSubview(shortcutCapture)
    stack.addArrangedSubview(keyboardSettingsButton)
    stack.addArrangedSubview(inputRow)
    stack.addArrangedSubview(soundRow)
    stack.addArrangedSubview(permissionRow)
    stack.addArrangedSubview(integrationTitle)
    stack.addArrangedSubview(modelStatus)
    stack.addArrangedSubview(modelButton)
    stack.addArrangedSubview(historyStatus)
    stack.addArrangedSubview(historyButton)
    stack.addArrangedSubview(privacyStatus)
    stack.addArrangedSubview(privacyButton)

    for view in [shortcutRow, inputRow, soundRow, permissionRow] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    shortcutCapture.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    shortcutCapture.heightAnchor.constraint(equalToConstant: 44).isActive = true
  }

  private func row(title: String, detail: String, control: NSView) -> NSStackView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    let detailLabel = NSTextField(wrappingLabelWithString: detail)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.maximumNumberOfLines = 2
    let labels = NSStackView(views: [titleLabel, detailLabel])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 3

    let row = NSStackView(views: [labels, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = 16
    labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
    return row
  }

  private func render(_ snapshot: AppStatusSnapshot) {
    populateShortcutChoices(selected: snapshot.preferredShortcut)
    populateInputDevices(selectedUID: model.selectedInputDeviceUID())
    soundButton.state = snapshot.soundEnabled ? .on : .off
    if !isRecordingShortcut, shortcutFeedbackOverride == nil {
      shortcutStatus.stringValue = shortcutStatusText(snapshot)
    }
    modelStatus.stringValue = "语音模型：\(modelStatusText(snapshot.modelStatus))"
    historyStatus.stringValue =
      snapshot.historyEnabled
      ? "历史：已开启，最多保留 7 天。"
      : "历史：已关闭，不会保存后续结果。"
    privacyStatus.stringValue = "音频仅在内存中；本机识别，不发送遥测。"
  }

  private func populateShortcutChoices(selected: HoldShortcut) {
    var choices: [ShortcutChoice] =
      [HoldShortcut.function, .rightOption, .copyOnlyControlShiftSpace].map {
        ShortcutChoice(title: $0.displayName, storageValue: $0.storageValue)
      }
    if case .custom = selected {
      choices.append(
        ShortcutChoice(title: selected.displayName, storageValue: selected.storageValue))
    }
    choices.append(ShortcutChoice(title: "录入自定义组合键…", storageValue: "record-custom"))

    if choices != renderedShortcutChoices {
      guard !shortcutMenuIsTracking else {
        return
      }
      shortcutPopup.removeAllItems()
      for choice in choices {
        shortcutPopup.addItem(withTitle: choice.title)
        shortcutPopup.lastItem?.representedObject = choice.storageValue
      }
      renderedShortcutChoices = choices
    }

    guard !shortcutMenuIsTracking else {
      return
    }
    if let index = shortcutPopup.itemArray.firstIndex(where: {
      ($0.representedObject as? String) == selected.storageValue
    }), shortcutPopup.indexOfSelectedItem != index {
      shortcutPopup.selectItem(at: index)
    }
  }

  private func populateInputDevices(selectedUID: String?) {
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
    let selectedIndex =
      selectedUID.flatMap { uid in
        inputDevicePopup.itemArray.firstIndex { ($0.representedObject as? String) == uid }
      } ?? 0
    if inputDevicePopup.indexOfSelectedItem != selectedIndex {
      inputDevicePopup.selectItem(at: selectedIndex)
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    if menu == shortcutPopup.menu {
      shortcutMenuIsTracking = true
    }
    if menu == inputDevicePopup.menu {
      inputDeviceMenuIsTracking = true
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    if menu == shortcutPopup.menu {
      shortcutMenuIsTracking = false
    }
    if menu == inputDevicePopup.menu {
      inputDeviceMenuIsTracking = false
      populateInputDevices(selectedUID: model.selectedInputDeviceUID())
    }
  }

  private func shortcutStatusText(_ snapshot: AppStatusSnapshot) -> String {
    if !snapshot.accessibilityPermission.isAuthorized {
      return "未授权辅助功能：当前有效快捷键是 ⌃⇧ Space，识别结果只复制。偏好保持为 \(snapshot.preferredShortcut.displayName)。"
    }
    if !snapshot.isShortcutAvailable {
      return "快捷键未注册。请改用其他组合键或检查 macOS 键盘快捷键设置。"
    }
    if snapshot.effectiveShortcut == .function {
      return "当前有效快捷键：Fn。无法自动确认系统是否占用 Fn；请完成一次实际按住/松开测试，必要时打开键盘设置。"
    }
    return "当前有效快捷键：\(snapshot.effectiveShortcut.displayName)。"
  }

  @objc private func shortcutChanged() {
    guard let storageValue = shortcutPopup.selectedItem?.representedObject as? String else {
      return
    }
    if storageValue == "record-custom" {
      startShortcutRecording()
      return
    }
    guard let shortcut = HoldShortcut(storageValue: storageValue) else {
      return
    }
    shortcutFeedbackOverride = nil
    model.setPreferredShortcut(shortcut)
  }

  @objc private func startShortcutRecording() {
    guard !isRecordingShortcut else {
      return
    }
    isRecordingShortcut = true
    shortcutFeedbackOverride = nil
    model.beginShortcutRecording()
    shortcutStatus.stringValue = "按下 Fn、右 Option，或按住修饰键再按普通键。按 Esc 取消。"
    shortcutCapture.isHidden = false
    shortcutCapture.beginCapture()
    window?.makeFirstResponder(shortcutCapture)
  }

  private func commitShortcut(_ shortcut: HoldShortcut) {
    let error = model.commitRecordedShortcut(shortcut)
    isRecordingShortcut = false
    shortcutCapture.isHidden = true
    shortcutCapture.endCapture()
    if let error {
      showShortcutFeedback(error)
    } else {
      shortcutFeedbackOverride = nil
    }
  }

  private func stopShortcutRecording() {
    guard isRecordingShortcut else {
      return
    }
    isRecordingShortcut = false
    shortcutCapture.isHidden = true
    shortcutCapture.endCapture()
    model.cancelShortcutRecording()
    shortcutFeedbackOverride = nil
  }

  private func showShortcutFeedback(_ message: String) {
    shortcutFeedbackOverride = message
    shortcutStatus.stringValue = message
  }

  @objc private func inputDeviceChanged() {
    let uid = inputDevicePopup.selectedItem?.representedObject as? String
    model.selectInputDevice(uid: uid)
  }

  @objc private func soundChanged() {
    model.setSoundEnabled(soundButton.state == .on)
  }

  @objc private func openAccessibilitySettingsAction() {
    openAccessibilitySettings()
  }

  @objc private func openKeyboardSettingsAction() {
    openKeyboardSettings()
  }

  @objc private func openModelManagementAction() {
    openModelManagement()
  }

  @objc private func openHistoryAction() {
    openHistory()
  }

  @objc private func openPrivacyAction() {
    openPrivacy()
  }

  private func modelStatusText(_ status: ModelManagerStatus) -> String {
    switch status {
    case .ready:
      return "就绪"
    case .downloading:
      return "正在下载"
    case .paused:
      return "下载已暂停"
    case .loading:
      return "正在加载"
    case .deleting:
      return "正在删除"
    case .checking:
      return "正在检查"
    case .repairRequired:
      return "需要修复"
    case .failed:
      return "不可用"
    }
  }
}

private final class HotkeyCaptureView: NSView {
  var onCapture: ((HoldShortcut) -> Void)?
  var onError: ((String) -> Void)?
  var onCancel: (() -> Void)?
  private var captureState = HotkeyCaptureState()

  override var acceptsFirstResponder: Bool {
    true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    dirtyRect.fill()
    let message = "按下快捷键；Esc 取消"
    message.draw(
      at: NSPoint(x: 12, y: 13),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
  }

  func beginCapture() {
    captureState.reset()
  }

  func endCapture() {
    captureState.reset()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      onCancel?()
      return
    }
    var modifiers = HotkeyModifiers(event.modifierFlags)
    if captureState.rightOptionIsHeld {
      modifiers.remove(.option)
      modifiers.insert(.rightOption)
    }
    switch captureState.ordinaryKeyPressed(keyCode: event.keyCode, modifiers: modifiers) {
    case .captured(let shortcut):
      onCapture?(shortcut)
    case .rejected(let error):
      onError?(error)
    }
  }

  override func flagsChanged(with event: NSEvent) {
    let isPressed = isModifierPressed(event)
    if let shortcut = captureState.modifierChanged(keyCode: event.keyCode, isPressed: isPressed) {
      onCapture?(shortcut)
    } else {
      super.flagsChanged(with: event)
    }
  }

  private func isModifierPressed(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case UInt16(kVK_Control):
      return event.modifierFlags.contains(.control)
    case UInt16(kVK_Shift):
      return event.modifierFlags.contains(.shift)
    case UInt16(kVK_Option):
      return event.modifierFlags.contains(.option)
    case UInt16(kVK_Command):
      return event.modifierFlags.contains(.command)
    case UInt16(kVK_Function):
      return event.modifierFlags.contains(.function)
    case UInt16(kVK_RightOption):
      let deviceRightOptionMask: UInt = 0x40
      return event.modifierFlags.rawValue & deviceRightOptionMask != 0
    default:
      return false
    }
  }
}

extension HotkeyModifiers {
  fileprivate init(_ flags: NSEvent.ModifierFlags) {
    var modifiers: HotkeyModifiers = []
    if flags.contains(.control) {
      modifiers.insert(.control)
    }
    if flags.contains(.shift) {
      modifiers.insert(.shift)
    }
    if flags.contains(.option) {
      modifiers.insert(.option)
    }
    if flags.contains(.command) {
      modifiers.insert(.command)
    }
    self = modifiers
  }
}
