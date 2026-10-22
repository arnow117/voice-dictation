import AppKit

/// A shared native model window for the first-run flow and the later settings surface. It owns no
/// model state: opening and closing it only observes the existing ModelManager.
final class ModelManagementWindowController: NSWindowController {
  private let manager: ModelManaging
  private var observation: UUID?
  private let modelNameLabel = NSTextField(labelWithString: "")
  private let modelDetailLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let locationLabel = NSTextField(labelWithString: "")
  private let progressIndicator = NSProgressIndicator()
  private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let primaryButton = NSButton(title: "下载", target: nil, action: nil)
  private let repairButton = NSButton(title: "重新下载并修复", target: nil, action: nil)
  private let deleteButton = NSButton(title: "删除本机下载", target: nil, action: nil)

  init(manager: ModelManaging) {
    self.manager = manager
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "语音模型"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    configureWindow()
    observation = manager.observe { [weak self] status in
      self?.render(status)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    if let observation {
      manager.removeObserver(observation)
    }
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
      stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
    ])

    modelNameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    modelNameLabel.setAccessibilityLabel("当前语音模型")
    modelDetailLabel.textColor = .secondaryLabelColor
    modelDetailLabel.setAccessibilityLabel("模型大小和许可证")
    statusLabel.setAccessibilityLabel("模型状态")
    locationLabel.lineBreakMode = .byTruncatingMiddle
    locationLabel.textColor = .secondaryLabelColor
    locationLabel.setAccessibilityLabel("模型位置")

    progressIndicator.isIndeterminate = false
    progressIndicator.minValue = 0
    progressIndicator.maxValue = 1
    progressIndicator.controlSize = .regular
    progressIndicator.translatesAutoresizingMaskIntoConstraints = false
    progressIndicator.setAccessibilityLabel("模型下载进度")

    sourcePopup.removeAllItems()
    for source in manager.manifest.sources {
      sourcePopup.addItem(withTitle: source.name)
      sourcePopup.lastItem?.representedObject = source.id
    }
    sourcePopup.target = self
    sourcePopup.action = #selector(sourceChanged)
    sourcePopup.setAccessibilityLabel("模型下载源")

    primaryButton.target = self
    primaryButton.action = #selector(primaryAction)
    primaryButton.keyEquivalent = "\r"
    primaryButton.setAccessibilityLabel("下载或暂停模型")
    repairButton.target = self
    repairButton.action = #selector(repair)
    repairButton.setAccessibilityLabel("重新下载并修复模型")
    deleteButton.target = self
    deleteButton.action = #selector(deleteModel)
    deleteButton.setAccessibilityLabel("删除本机下载的模型")

    let sourceRow = NSStackView(views: [
      NSTextField(labelWithString: "下载源："),
      sourcePopup,
    ])
    sourceRow.orientation = .horizontal
    sourceRow.alignment = .centerY
    sourceRow.spacing = 8

    let buttons = NSStackView(views: [primaryButton, repairButton, deleteButton])
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8

    stack.addArrangedSubview(modelNameLabel)
    stack.addArrangedSubview(modelDetailLabel)
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(progressIndicator)
    stack.addArrangedSubview(locationLabel)
    stack.addArrangedSubview(sourceRow)
    stack.addArrangedSubview(buttons)
    progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    modelNameLabel.stringValue = manager.manifest.displayName
    modelDetailLabel.stringValue =
      "\(formatBytes(manager.manifest.totalBytes)) · \(manager.manifest.license)"
    selectSource(manager.selectedSource)
  }

  private func render(_ status: ModelManagerStatus) {
    statusLabel.stringValue = "状态：\(status.summary)"
    selectSource(manager.selectedSource)

    switch status {
    case .checking:
      progressIndicator.isIndeterminate = true
      progressIndicator.startAnimation(nil)
      locationLabel.stringValue = "位置：正在检查本机模型"
      primaryButton.title = "请稍候"
      primaryButton.isEnabled = false
      repairButton.isEnabled = false
      deleteButton.isEnabled = false
    case .repairRequired(let reason):
      stopProgress()
      locationLabel.stringValue = "位置：\(reason)"
      primaryButton.title = "下载模型"
      primaryButton.isEnabled = true
      repairButton.isEnabled = true
      deleteButton.isEnabled = true
    case .downloading(let completedBytes, let totalBytes, let sourceName):
      progressIndicator.isIndeterminate = false
      progressIndicator.doubleValue = Double(completedBytes) / Double(max(totalBytes, 1))
      locationLabel.stringValue =
        "正在从 \(sourceName) 下载 \(formatBytes(completedBytes)) / \(formatBytes(totalBytes))"
      primaryButton.title = "暂停"
      primaryButton.isEnabled = true
      repairButton.isEnabled = false
      deleteButton.isEnabled = true
    case .paused:
      stopProgress()
      locationLabel.stringValue = "位置：已保留可继续下载的部分文件"
      primaryButton.title = "继续下载"
      primaryButton.isEnabled = true
      repairButton.isEnabled = true
      deleteButton.isEnabled = true
    case .loading:
      progressIndicator.isIndeterminate = true
      progressIndicator.startAnimation(nil)
      locationLabel.stringValue = "位置：正在验证并加载模型"
      primaryButton.title = "请稍候"
      primaryButton.isEnabled = false
      repairButton.isEnabled = false
      deleteButton.isEnabled = true
    case .ready(let location, let isReadOnly):
      stopProgress()
      locationLabel.stringValue =
        isReadOnly
        ? "位置：开发只读缓存（不会由本窗口修改）"
        : "位置：\(location.path)"
      primaryButton.title = "检查并重新加载"
      primaryButton.isEnabled = true
      repairButton.isEnabled = true
      deleteButton.isEnabled = !isReadOnly
    case .deleting:
      progressIndicator.isIndeterminate = true
      progressIndicator.startAnimation(nil)
      locationLabel.stringValue = "位置：正在释放运行时并删除本机下载"
      primaryButton.title = "请稍候"
      primaryButton.isEnabled = false
      repairButton.isEnabled = false
      deleteButton.isEnabled = false
    case .failed(let reason):
      stopProgress()
      locationLabel.stringValue = "位置：\(reason)"
      primaryButton.title = "重试下载"
      primaryButton.isEnabled = true
      repairButton.isEnabled = true
      deleteButton.isEnabled = true
    }
  }

  private func stopProgress() {
    progressIndicator.stopAnimation(nil)
    progressIndicator.isIndeterminate = false
    progressIndicator.doubleValue = 0
  }

  private func selectSource(_ source: ModelDownloadSource) {
    sourcePopup.selectItem(withTitle: source.name)
  }

  @objc private func sourceChanged() {
    guard let source = selectedSourceFromPopup() else {
      return
    }
    manager.download(preferredSource: source)
  }

  @objc private func primaryAction() {
    switch manager.status {
    case .downloading:
      manager.pause()
    default:
      manager.download(preferredSource: selectedSourceFromPopup())
    }
  }

  @objc private func repair() {
    manager.repair()
  }

  @objc private func deleteModel() {
    manager.deleteOwnedModel()
  }

  private func selectedSourceFromPopup() -> ModelDownloadSource? {
    guard let identifier = sourcePopup.selectedItem?.representedObject as? String else {
      return nil
    }
    return manager.manifest.sources.first { $0.id == identifier }
  }
}

private func formatBytes(_ bytes: Int64) -> String {
  ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
