import AppKit

final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate
{
  private let model: AppModel
  private let tableView = NSTableView()
  private let historyEnabledButton = NSButton(
    checkboxWithTitle: "保存语音输入历史（默认保留 7 天）", target: nil, action: nil)
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let copyOriginalButton = NSButton(title: "复制原文", target: nil, action: nil)
  private let copyFinalButton = NSButton(title: "复制最终文本", target: nil, action: nil)
  private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
  private let clearButton = NSButton(title: "清空全部…", target: nil, action: nil)
  private let retryButton = NSButton(title: "重试", target: nil, action: nil)
  private var records: [HistoryRecord] = []
  private var observation: UUID?
  private var mutationRetryAction: (() -> Void)?
  private var queryRetryAction: (() -> Void)?

  init(model: AppModel) {
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 840, height: 420),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "语音输入历史"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    configureWindow()
    observation = model.observe { [weak self] snapshot in
      self?.historyEnabledButton.state = snapshot.historyEnabled ? .on : .off
      self?.statusLabel.stringValue =
        snapshot.historyFailure == nil
        ? "只显示最近 7 天的记录。关闭后不会再保存新记录。"
        : "无法访问历史。请检查本机存储空间和文件权限。"
      if snapshot.historyFailure == nil {
        self?.clearAllRetryActions()
      }
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
    reloadRecords()
  }

  private func configureWindow() {
    guard let contentView = window?.contentView else {
      return
    }
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
    ])

    historyEnabledButton.target = self
    historyEnabledButton.action = #selector(historyEnabledChanged)
    historyEnabledButton.setAccessibilityLabel("保存语音输入历史")
    statusLabel.maximumNumberOfLines = 0
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.setAccessibilityLabel("历史状态")

    let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
    timeColumn.title = "时间"
    timeColumn.width = 130
    let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
    appColumn.title = "目标应用"
    appColumn.width = 120
    let originalColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("original"))
    originalColumn.title = "原文"
    originalColumn.width = 260
    let finalColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("final"))
    finalColumn.title = "最终文本"
    finalColumn.width = 260
    tableView.addTableColumn(timeColumn)
    tableView.addTableColumn(appColumn)
    tableView.addTableColumn(originalColumn)
    tableView.addTableColumn(finalColumn)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.setAccessibilityLabel("最近七天语音输入历史")
    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    copyOriginalButton.target = self
    copyOriginalButton.action = #selector(copyOriginal)
    copyOriginalButton.setAccessibilityLabel("复制选中的历史原文")
    copyFinalButton.target = self
    copyFinalButton.action = #selector(copyFinal)
    copyFinalButton.setAccessibilityLabel("复制选中的历史最终文本")
    deleteButton.target = self
    deleteButton.action = #selector(deleteSelected)
    deleteButton.setAccessibilityLabel("删除选中的历史记录")
    clearButton.target = self
    clearButton.action = #selector(clearAll)
    clearButton.setAccessibilityLabel("清空所有语音输入历史")
    retryButton.target = self
    retryButton.action = #selector(retryLastOperation)
    retryButton.setAccessibilityLabel("重试失败的历史操作")
    retryButton.isHidden = true
    let buttons = NSStackView(
      views: [copyOriginalButton, copyFinalButton, deleteButton, clearButton, retryButton]
    )
    buttons.orientation = .horizontal
    buttons.spacing = 8

    stack.addArrangedSubview(historyEnabledButton)
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(scrollView)
    stack.addArrangedSubview(buttons)
    scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    scrollView.heightAnchor.constraint(equalToConstant: 270).isActive = true
  }

  private func reloadRecords() {
    model.historyRecords { [weak self] result in
      guard let self else {
        return
      }
      switch result {
      case .success(let records):
        self.records = records
        self.tableView.reloadData()
        self.clearQueryRetryAction()
      case .failure:
        self.statusLabel.stringValue = "无法读取历史。请检查本机存储空间和文件权限。"
        self.setQueryRetryAction { [weak self] in
          self?.reloadRecords()
        }
      }
    }
  }

  @objc private func historyEnabledChanged() {
    model.setHistoryEnabled(historyEnabledButton.state == .on)
  }

  @objc private func copyOriginal() {
    guard let record = selectedRecord() else {
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(record.recognizedText, forType: .string)
  }

  @objc private func copyFinal() {
    guard let record = selectedRecord() else {
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(record.finalText, forType: .string)
  }

  @objc private func deleteSelected() {
    guard let record = selectedRecord() else {
      return
    }
    delete(record)
  }

  private func delete(_ record: HistoryRecord) {
    model.deleteHistoryRecord(record) { [weak self] result in
      switch result {
      case .success:
        self?.reloadRecords()
      case .failure:
        self?.statusLabel.stringValue = "无法删除历史。请检查本机存储空间和文件权限后重试。"
        self?.setMutationRetryAction { [weak self] in
          self?.delete(record)
        }
      }
    }
  }

  @objc private func clearAll() {
    let alert = NSAlert()
    alert.messageText = "清空全部历史？"
    alert.informativeText = "此操作会删除本机保存的所有语音输入历史。"
    alert.addButton(withTitle: "清空")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else {
      return
    }
    clearConfirmed()
  }

  private func clearConfirmed() {
    model.clearHistory { [weak self] result in
      switch result {
      case .success:
        self?.reloadRecords()
      case .failure:
        self?.statusLabel.stringValue = "无法清空历史。请检查本机存储空间和文件权限后重试。"
        self?.setMutationRetryAction { [weak self] in
          self?.clearConfirmed()
        }
      }
    }
  }

  @objc private func retryLastOperation() {
    (mutationRetryAction ?? queryRetryAction)?()
  }

  private func setMutationRetryAction(_ action: @escaping () -> Void) {
    mutationRetryAction = action
    updateRetryButton()
  }

  private func setQueryRetryAction(_ action: @escaping () -> Void) {
    queryRetryAction = action
    updateRetryButton()
  }

  private func clearQueryRetryAction() {
    queryRetryAction = nil
    updateRetryButton()
  }

  private func clearAllRetryActions() {
    mutationRetryAction = nil
    queryRetryAction = nil
    updateRetryButton()
  }

  private func updateRetryButton() {
    retryButton.isHidden = mutationRetryAction == nil && queryRetryAction == nil
  }

  private func selectedRecord() -> HistoryRecord? {
    let row = tableView.selectedRow
    guard records.indices.contains(row) else {
      return nil
    }
    return records[row]
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    records.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard records.indices.contains(row), let tableColumn else {
      return nil
    }
    let identifier = tableColumn.identifier
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
      ?? NSTableCellView()
    cell.identifier = identifier
    let field: NSTextField
    if let existing = cell.textField {
      field = existing
    } else {
      field = NSTextField(labelWithString: "")
      field.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(field)
      NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      cell.textField = field
    }
    let record = records[row]
    switch identifier.rawValue {
    case "time":
      field.stringValue = DateFormatter.localizedString(
        from: record.createdAt,
        dateStyle: .short,
        timeStyle: .short
      )
    case "app":
      field.stringValue = record.targetAppName ?? record.targetBundleID ?? "未知应用"
    case "original":
      field.stringValue = record.recognizedText
    default:
      field.stringValue = record.finalText
    }
    return cell
  }
}
