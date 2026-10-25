import AppKit
import ShanshuoCore

/// A separate, explicit configuration surface for the optional cloud formatter. It never reads
/// CC Switch except after a button action, and background work may only adopt results that still
/// belong to this visible window generation.
final class FormattingSettingsWindowController: NSWindowController, NSWindowDelegate {
  private let configurationStore: FormattingConfigurationStore
  private let credentialStore: FormattingCredentialStore
  private let importer: CCSwitchMiniMaxImporter
  private let formatter: FormattingServicing
  private let workQueue = DispatchQueue(
    label: "com.arnow117.shanshuo.formatting.settings",
    qos: .userInitiated
  )

  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let endpointPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let policyButton = NSButton(title: "查看 MiniMax 数据政策", target: nil, action: nil)
  private let importButton = NSButton(title: "从 CC Switch 导入", target: nil, action: nil)
  private let manualCredentialField = NSSecureTextField(frame: .zero)
  private let saveCredentialButton = NSButton(title: "使用本次 Key", target: nil, action: nil)
  private let testButton = NSButton(title: "测试连接", target: nil, action: nil)
  private let keyHelpButton = NSButton(title: "获取 MiniMax API Key", target: nil, action: nil)
  private let disclosureButton = NSButton(
    checkboxWithTitle: "我了解本次识别文字会发送给 MiniMax 进行整理。",
    target: nil,
    action: nil
  )
  private let enableButton = NSButton(title: "开启智能整理", target: nil, action: nil)
  private let disableButton = NSButton(title: "关闭智能整理", target: nil, action: nil)
  private let deleteButton = NSButton(title: "清除本次 Key", target: nil, action: nil)

  private var observation: UUID?
  private var manualCredentialRow: NSStackView?
  private var windowGeneration: UInt64 = 0
  private var activeTestTicket: FormattingConnectionTestTicket?
  private var activeTestOperation: FormattingOperation?
  private var activeTestGeneration: UInt64 = 0
  private var completedTestTicket: FormattingConnectionTestTicket?
  private var statusOverride: String?

  init(
    configurationStore: FormattingConfigurationStore,
    credentialStore: FormattingCredentialStore = FormattingCredentialStore(),
    importer: CCSwitchMiniMaxImporter = CCSwitchMiniMaxImporter(),
    formatter: FormattingServicing
  ) {
    self.configurationStore = configurationStore
    self.credentialStore = credentialStore
    self.importer = importer
    self.formatter = formatter

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 590, height: 620),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "智能整理"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.delegate = self
    configureWindow()
    observation = configurationStore.observe { [weak self] snapshot in
      self?.configurationDidChange(snapshot)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    if let observation {
      configurationStore.removeObserver(observation)
    }
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    render(configurationStore.snapshot())
  }

  func windowWillClose(_ notification: Notification) {
    windowGeneration &+= 1
    cancelConnectionTest()
    completedTestTicket = nil
    statusOverride = nil
    configurationStore.invalidateConnectionTest()
  }

  private func configureWindow() {
    guard let contentView = window?.contentView else {
      return
    }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
    ])

    let title = NSTextField(labelWithString: "智能整理（可选）")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    let disclosure = NSTextField(wrappingLabelWithString: "开启后只发送本次本机识别出的文字给 MiniMax。音频、屏幕内容和其他应用内容不会发送。Key 只在本次运行内存中有效，退出后需重新导入、测试并开启。MiniMax 的数据政策由所选服务端点决定；本应用不承诺零数据保留。")
    disclosure.maximumNumberOfLines = 0
    disclosure.textColor = .secondaryLabelColor

    modelPopup.addItems(withTitles: FormattingModel.allCases.map(\.rawValue))
    modelPopup.target = self
    modelPopup.action = #selector(modelChanged)
    endpointPopup.addItems(withTitles: FormattingEndpoint.allCases.map(\.rawValue))
    endpointPopup.target = self
    endpointPopup.action = #selector(endpointChanged)
    policyButton.target = self
    policyButton.action = #selector(openPolicy)
    importButton.target = self
    importButton.action = #selector(importCCSwitch)
    saveCredentialButton.target = self
    saveCredentialButton.action = #selector(saveManualCredential)
    testButton.target = self
    testButton.action = #selector(testConnection)
    keyHelpButton.target = self
    keyHelpButton.action = #selector(openAPIKeyConsole)
    disclosureButton.target = self
    disclosureButton.action = #selector(disclosureChanged)
    enableButton.target = self
    enableButton.action = #selector(enableFormatting)
    disableButton.target = self
    disableButton.action = #selector(disableFormatting)
    deleteButton.target = self
    deleteButton.action = #selector(deleteCredential)

    manualCredentialField.placeholderString = "粘贴 MiniMax API Key"
    manualCredentialField.setAccessibilityLabel("MiniMax API Key")
    disclosureButton.setAccessibilityLabel("确认 MiniMax 数据流向")
    statusLabel.maximumNumberOfLines = 0
    statusLabel.textColor = .secondaryLabelColor

    stack.addArrangedSubview(title)
    stack.addArrangedSubview(disclosure)
    stack.addArrangedSubview(row(title: "模型", control: modelPopup))
    stack.addArrangedSubview(row(title: "服务端点", control: endpointPopup))
    stack.addArrangedSubview(policyButton)
    stack.addArrangedSubview(disclosureButton)
    let credentialRow = row(title: "手动 Key", control: manualCredentialField)
    manualCredentialRow = credentialRow
    stack.addArrangedSubview(importButton)
    stack.addArrangedSubview(credentialRow)
    stack.addArrangedSubview(saveCredentialButton)
    stack.addArrangedSubview(testButton)
    stack.addArrangedSubview(keyHelpButton)
    stack.addArrangedSubview(enableButton)
    stack.addArrangedSubview(disableButton)
    stack.addArrangedSubview(deleteButton)
    stack.addArrangedSubview(statusLabel)

    for view in stack.arrangedSubviews {
      view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    }
  }

  private func row(title: String, control: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 16
    label.widthAnchor.constraint(equalToConstant: 90).isActive = true
    control.widthAnchor.constraint(equalToConstant: 390).isActive = true
    return row
  }

  private func configurationDidChange(_ snapshot: FormattingConfigurationSnapshot) {
    if let ticket = activeTestTicket, !matches(ticket: ticket, snapshot: snapshot) {
      cancelConnectionTest()
    }
    if let ticket = completedTestTicket, !matches(ticket: ticket, snapshot: snapshot) {
      completedTestTicket = nil
      statusOverride = nil
    }
    render(snapshot)
  }

  private func render(_ snapshot: FormattingConfigurationSnapshot) {
    guard let modelIndex = FormattingModel.allCases.firstIndex(of: snapshot.model),
      let endpointIndex = FormattingEndpoint.allCases.firstIndex(of: snapshot.endpoint)
    else {
      return
    }
    modelPopup.selectItem(at: modelIndex)
    endpointPopup.selectItem(at: endpointIndex)
    if snapshot.consentVersion != nil {
      disclosureButton.state = .on
    }
    let acknowledged = disclosureButton.state == .on
    let credentialStatus = snapshot.credential.map { "本次运行已导入 \($0.hint)" } ?? "未配置 Key"
    let enabledStatus = snapshot.enabled ? "已开启" : "已关闭"
    let defaultStatus = "智能整理\(enabledStatus)；\(credentialStatus)。开启前需要完成当前连接测试和数据流向确认。"
    statusLabel.stringValue = statusOverride ?? defaultStatus

    let credentialControls: [NSView] = [
      importButton,
      manualCredentialRow ?? manualCredentialField,
      saveCredentialButton,
      testButton,
      keyHelpButton,
      enableButton,
      disableButton,
      deleteButton,
    ]
    for control in credentialControls {
      control.isHidden = !acknowledged
    }

    testButton.isEnabled = acknowledged && snapshot.credential != nil && activeTestOperation == nil
    enableButton.isEnabled = !snapshot.enabled && acknowledged && completedTestTicket != nil
    disableButton.isEnabled = snapshot.enabled
    deleteButton.isEnabled = snapshot.credential != nil
  }

  @objc private func modelChanged() {
    guard let model = selectedModel(), let endpoint = selectedEndpoint() else {
      return
    }
    statusOverride = nil
    invalidateBackgroundWork()
    _ = configurationStore.select(model: model, endpoint: endpoint)
  }

  @objc private func endpointChanged() {
    guard let model = selectedModel(), let endpoint = selectedEndpoint() else {
      return
    }
    statusOverride = nil
    invalidateBackgroundWork()
    _ = configurationStore.select(model: model, endpoint: endpoint)
  }

  @objc private func openPolicy() {
    guard let endpoint = selectedEndpoint() else {
      return
    }
    NSWorkspace.shared.open(endpoint.privacyPolicyURL)
  }

  @objc private func openAPIKeyConsole() {
    guard let endpoint = selectedEndpoint() else {
      return
    }
    NSWorkspace.shared.open(endpoint.apiKeyURL)
  }

  @objc private func disclosureChanged() {
    statusOverride = nil
    render(configurationStore.snapshot())
  }

  @objc private func importCCSwitch() {
    guard requireDisclosureAcknowledgement() else {
      return
    }
    let selectedModel = selectedModel() ?? .flash
    let expectedConfiguration = configurationStore.snapshot()
    let generation = beginBackgroundWork()
    let databaseURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cc-switch", isDirectory: true)
      .appendingPathComponent("cc-switch.db", isDirectory: false)
    statusOverride = "正在从 CC Switch 导入本次运行 Key…"
    render(configurationStore.snapshot())
    workQueue.async { [weak self] in
      guard let self else {
        return
      }
      do {
        let imported = try self.importer.readCredential(from: databaseURL)
        let descriptor = try self.credentialStore.save(imported.apiKey)
        DispatchQueue.main.async {
          self.adoptImportedCredential(
            descriptor,
            endpoint: imported.endpoint,
            model: selectedModel,
            generation: generation,
            expectedConfiguration: expectedConfiguration
          )
        }
      } catch {
        DispatchQueue.main.async {
          guard self.windowGeneration == generation else {
            return
          }
          self.statusOverride = "无法导入 CC Switch 配置。请确认存在唯一 MiniMax 配置。"
          self.render(self.configurationStore.snapshot())
        }
      }
    }
  }

  @objc private func saveManualCredential() {
    guard requireDisclosureAcknowledgement() else {
      return
    }
    let credential = manualCredentialField.stringValue
    manualCredentialField.stringValue = ""
    guard !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      statusOverride = "请输入有效的 MiniMax API Key。"
      render(configurationStore.snapshot())
      return
    }
    let endpoint = selectedEndpoint() ?? .domestic
    let model = selectedModel() ?? .flash
    let expectedConfiguration = configurationStore.snapshot()
    let generation = beginBackgroundWork()
    statusOverride = "正在保存本次运行 Key…"
    render(configurationStore.snapshot())
    workQueue.async { [weak self] in
      guard let self else {
        return
      }
      do {
        let descriptor = try self.credentialStore.save(credential)
        DispatchQueue.main.async {
          self.adoptImportedCredential(
            descriptor,
            endpoint: endpoint,
            model: model,
            generation: generation,
            expectedConfiguration: expectedConfiguration
          )
        }
      } catch {
        DispatchQueue.main.async {
          guard self.windowGeneration == generation else {
            return
          }
          self.statusOverride = "无法保存本次运行 Key。"
          self.render(self.configurationStore.snapshot())
        }
      }
    }
  }

  private func adoptImportedCredential(
    _ descriptor: FormattingCredentialDescriptor,
    endpoint: FormattingEndpoint,
    model: FormattingModel,
    generation: UInt64,
    expectedConfiguration: FormattingConfigurationSnapshot
  ) {
    let currentConfiguration = configurationStore.snapshot()
    guard windowGeneration == generation, currentConfiguration == expectedConfiguration else {
      removeNewCredential(reference: descriptor.reference)
      return
    }
    _ = configurationStore.replaceCredential(descriptor, model: model, endpoint: endpoint)
    statusOverride = "Key 已导入本次运行。请测试连接并确认数据流向后开启。"
    render(configurationStore.snapshot())
  }

  @objc private func testConnection() {
    guard requireDisclosureAcknowledgement(), activeTestOperation == nil,
      let ticket = configurationStore.beginConnectionTest()
    else {
      return
    }
    activeTestTicket = ticket
    activeTestGeneration &+= 1
    let testGeneration = activeTestGeneration
    let testWindowGeneration = windowGeneration
    let operation = FormattingSettingsOperationSlot()
    activeTestOperation = operation
    statusOverride = "正在测试连接…"
    let underlyingOperation = formatter.format(
      request: FormattingRequest(
        originalText: "第一买牛奶第二取快递",
        dictionaryTerms: []
      ),
      configuration: configurationStore.snapshot(),
      authorizeSend: { [weak self] in
        guard let self, self.windowGeneration == testWindowGeneration else {
          return false
        }
        return self.activeTestTicket == ticket
          && self.matches(ticket: ticket, snapshot: self.configurationStore.snapshot())
      },
      completion: { [weak self] result in
        self?.completeConnectionTest(
          result,
          ticket: ticket,
          generation: testGeneration,
          windowGeneration: testWindowGeneration
        )
      }
    )
    operation.adopt(underlyingOperation)
    render(configurationStore.snapshot())
  }

  private func completeConnectionTest(
    _ result: FormattingResult,
    ticket: FormattingConnectionTestTicket,
    generation: UInt64,
    windowGeneration: UInt64
  ) {
    guard self.windowGeneration == windowGeneration,
      activeTestGeneration == generation,
      activeTestTicket == ticket
    else {
      return
    }
    activeTestOperation?.cancel()
    activeTestOperation = nil
    activeTestTicket = nil
    guard matches(ticket: ticket, snapshot: configurationStore.snapshot()) else {
      return
    }
    if case .formatted = result, configurationStore.recordConnectionTestSuccess(ticket) {
      completedTestTicket = ticket
      statusOverride = "连接测试成功。可以开启智能整理。"
    } else if case .fallback(_, let reason) = result, reason == .authorizationFailed {
      statusOverride = "Key 无效。请通过下方官方链接获取或更新 MiniMax API Key。"
    } else {
      statusOverride = "连接测试未完成。智能整理仍保持关闭。"
    }
    render(configurationStore.snapshot())
  }

  @objc private func enableFormatting() {
    guard disclosureButton.state == .on, let ticket = completedTestTicket else {
      statusOverride = "请先完成当前连接测试并确认数据流向。"
      render(configurationStore.snapshot())
      return
    }
    if configurationStore.enable(afterSuccessfulTest: ticket, consentVersion: 1) {
      statusOverride = "智能整理已开启。"
    } else {
      completedTestTicket = nil
      statusOverride = "连接测试已失效，请重新测试。"
    }
    render(configurationStore.snapshot())
  }

  @objc private func disableFormatting() {
    statusOverride = "智能整理已关闭。"
    invalidateBackgroundWork()
    _ = configurationStore.disable()
    render(configurationStore.snapshot())
  }

  @objc private func deleteCredential() {
    guard let previous = configurationStore.snapshot().credential
    else {
      return
    }
    invalidateBackgroundWork()
    credentialStore.remove(reference: previous.reference)
    _ = configurationStore.clearCredential()
    statusOverride = "已清除本次运行 Key，智能整理保持关闭。"
    render(configurationStore.snapshot())
  }

  private func beginBackgroundWork() -> UInt64 {
    windowGeneration &+= 1
    cancelConnectionTest()
    completedTestTicket = nil
    return windowGeneration
  }

  private func invalidateBackgroundWork() {
    _ = beginBackgroundWork()
  }

  private func cancelConnectionTest() {
    activeTestGeneration &+= 1
    activeTestOperation?.cancel()
    activeTestOperation = nil
    activeTestTicket = nil
  }

  private func removeNewCredential(reference: String) {
    credentialStore.remove(reference: reference)
  }

  private func requireDisclosureAcknowledgement() -> Bool {
    guard disclosureButton.state == .on else {
      statusOverride = "请先确认 MiniMax 接收本次识别文字的数据流向。"
      render(configurationStore.snapshot())
      return false
    }
    return true
  }

  private func currentTestTicket() -> FormattingConnectionTestTicket? {
    let snapshot = configurationStore.snapshot()
    guard let credential = snapshot.credential else {
      return nil
    }
    return FormattingConnectionTestTicket(
      revision: snapshot.revision,
      generation: snapshot.testGeneration,
      model: snapshot.model,
      endpoint: snapshot.endpoint,
      credentialReference: credential.reference
    )
  }

  private func matches(
    ticket: FormattingConnectionTestTicket,
    snapshot: FormattingConfigurationSnapshot
  ) -> Bool {
    ticket == currentTestTicket() && snapshot.credential != nil
  }

  private func selectedModel() -> FormattingModel? {
    guard modelPopup.indexOfSelectedItem >= 0 else {
      return nil
    }
    return FormattingModel.allCases[modelPopup.indexOfSelectedItem]
  }

  private func selectedEndpoint() -> FormattingEndpoint? {
    guard endpointPopup.indexOfSelectedItem >= 0 else {
      return nil
    }
    return FormattingEndpoint.allCases[endpointPopup.indexOfSelectedItem]
  }
}

private final class FormattingSettingsOperationSlot: FormattingOperation {
  private var operation: FormattingOperation?
  private var isCancelled = false

  func adopt(_ operation: FormattingOperation) {
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
