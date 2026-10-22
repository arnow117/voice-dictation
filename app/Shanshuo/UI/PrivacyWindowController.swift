import AppKit

final class PrivacyWindowController: NSWindowController {
  private let model: AppModel
  private let textLabel = NSTextField(wrappingLabelWithString: "")
  private var observation: UUID?

  init(model: AppModel) {
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 280),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "隐私"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
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

  private func configureWindow() {
    guard let contentView = window?.contentView else {
      return
    }
    textLabel.maximumNumberOfLines = 0
    textLabel.setAccessibilityLabel("闪说隐私说明")
    textLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(textLabel)
    NSLayoutConstraint.activate([
      textLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
      textLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
      textLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
      textLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
    ])
  }

  private func render(_ snapshot: AppStatusSnapshot) {
    let historyState = snapshot.historyEnabled ? "已开启" : "已关闭"
    textLabel.stringValue = """
      语音音频只保留在内存中，并在本次会话结束、取消或中断时丢弃。

      识别使用本机 Qwen3-ASR 模型完成，不会上传音频或文本。本版本不提供云端整理功能，也不发送遥测。

      语音输入历史\(historyState)，默认最多保留 7 天。历史数据库位置：
      \(Paths.historyDirectory.path)

      你可以在“语音输入历史”中关闭后续保存、删除单条或清空全部记录。
      """
  }
}
