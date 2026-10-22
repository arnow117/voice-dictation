import AppKit
import ApplicationServices

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

protocol RecordingSoundPlaying: AnyObject {
  var isEnabled: Bool { get set }
  func playStart()
}

extension SystemRecordingSoundPlayer: SoundPreferenceControlling {}

final class SystemRecordingSoundPlayer: RecordingSoundPlaying {
  var isEnabled = true

  func playStart() {
    guard isEnabled else {
      return
    }
    NSSound.beep()
  }
}

/// A nonactivating panel keeps the user's target app focused. The recording state is only returned
/// as visible after both the panel and the menu status have been updated.
final class RecordingPill: RecordingIndicating {
  private let panel: NSPanel
  private let label: NSTextField
  private let directInsertButton: NSButton
  private let statusButton: NSStatusBarButton
  private let statusMenuItem: NSMenuItem
  private let soundPlayer: RecordingSoundPlaying
  private let requestDirectInsertion: () -> Void
  private var baseText = ""
  private var displayGeneration = 0

  init(
    statusButton: NSStatusBarButton,
    statusMenuItem: NSMenuItem,
    soundPlayer: RecordingSoundPlaying,
    requestDirectInsertion: @escaping () -> Void
  ) {
    self.statusButton = statusButton
    self.statusMenuItem = statusMenuItem
    self.soundPlayer = soundPlayer
    self.requestDirectInsertion = requestDirectInsertion
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 42),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true

    let content = NSView(frame: panel.contentView?.bounds ?? .zero)
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
    content.layer?.cornerRadius = 21

    let dot = NSView(frame: NSRect(x: 16, y: 15, width: 12, height: 12))
    dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor.systemRed.cgColor
    dot.layer?.cornerRadius = 6

    label = NSTextField(labelWithString: "")
    label.textColor = .white
    label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    label.frame = NSRect(x: 38, y: 11, width: 326, height: 20)

    directInsertButton = NSButton(
      title: "开启直接插入",
      target: nil,
      action: nil
    )
    directInsertButton.bezelStyle = .rounded
    directInsertButton.font = .systemFont(ofSize: 12, weight: .medium)
    directInsertButton.frame = NSRect(x: 254, y: 7, width: 112, height: 28)
    directInsertButton.isHidden = true
    directInsertButton.target = self
    directInsertButton.action = #selector(requestDirectInsertionFromPill)

    content.addSubview(dot)
    content.addSubview(label)
    content.addSubview(directInsertButton)
    panel.contentView = content
  }

  var isAvailable: Bool {
    panel.contentView != nil && statusButton.window != nil
  }

  func showRecording() -> Bool {
    precondition(Thread.isMainThread)
    displayGeneration &+= 1
    hideDirectInsertAction()
    baseText = "闪说 · 正在录音"
    label.stringValue = baseText
    statusMenuItem.title = "状态：正在录音"
    statusButton.image = NSImage(
      systemSymbolName: "waveform.badge.mic", accessibilityDescription: "闪说正在录音")
    placeOnActiveScreen()
    panel.orderFrontRegardless()
    panel.display()
    guard panel.isVisible && statusMenuItem.title == "状态：正在录音" else {
      return false
    }
    soundPlayer.playStart()
    return true
  }

  func updateRecording(level: Float, elapsed: TimeInterval, countdown: Int?) {
    let elapsedText = String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
    let levelCount = min(8, Int((level * 12).rounded(.up)))
    let levelText =
      String(repeating: "▮", count: levelCount) + String(repeating: "▯", count: 8 - levelCount)
    let countdownText = countdown.map { " · 剩 \($0) 秒" } ?? ""
    label.stringValue = "\(baseText) \(elapsedText)\(countdownText) \(levelText)"
    statusMenuItem.title = "状态：正在录音"
  }

  func showProcessing() {
    displayGeneration &+= 1
    hideDirectInsertAction()
    baseText = "闪说 · 正在识别"
    label.stringValue = baseText
    statusMenuItem.title = "状态：正在识别"
    statusButton.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "闪说正在识别")
  }

  func showMessage(_ message: String, hideAfter: TimeInterval = 1.5) {
    displayGeneration &+= 1
    let messageGeneration = displayGeneration
    hideDirectInsertAction()
    baseText = "闪说 · \(message)"
    label.stringValue = baseText
    statusMenuItem.title = "状态：\(message)"
    placeOnActiveScreen()
    panel.orderFrontRegardless()
    panel.display()
    DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self] in
      guard self?.displayGeneration == messageGeneration else {
        return
      }
      self?.hide()
    }
  }

  func showCopyOnlyResult(_ message: String) {
    displayGeneration &+= 1
    let messageGeneration = displayGeneration
    baseText = "闪说 · \(message)"
    label.stringValue = baseText
    label.frame.size.width = 210
    statusMenuItem.title = "状态：\(message)"
    directInsertButton.isHidden = false
    panel.ignoresMouseEvents = false
    placeOnActiveScreen()
    panel.orderFrontRegardless()
    panel.display()
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      guard self?.displayGeneration == messageGeneration else {
        return
      }
      self?.hide()
    }
  }

  func showBusyFeedback() {
    statusMenuItem.title = "状态：上一段仍在处理"
  }

  func hide() {
    displayGeneration &+= 1
    hideDirectInsertAction()
    panel.orderOut(nil)
    statusMenuItem.title = "状态：就绪"
    statusButton.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "闪说")
  }

  @objc private func requestDirectInsertionFromPill() {
    requestDirectInsertion()
  }

  private func hideDirectInsertAction() {
    directInsertButton.isHidden = true
    label.frame.size.width = 326
    panel.ignoresMouseEvents = true
  }

  /// Uses the frontmost application's focused window when Accessibility can provide it. The mouse
  /// location is only a fallback for applications that do not expose a focused-window frame.
  private func placeOnActiveScreen() {
    let screen = screenForFocusedWindow() ?? screenUnderMouse() ?? NSScreen.main
    guard let screen else {
      return
    }
    let frame = screen.visibleFrame
    panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 60))
  }

  private func screenForFocusedWindow() -> NSScreen? {
    guard let application = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    guard
      let window = SystemFocusInspector.axElementAttribute(
        appElement, kAXFocusedWindowAttribute as String),
      let position = SystemFocusInspector.axValueAttribute(window, kAXPositionAttribute as String)
    else {
      return nil
    }
    var point = CGPoint.zero
    guard AXValueGetValue(position, .cgPoint, &point) else {
      return nil
    }
    guard let primaryScreen = NSScreen.screens.first else {
      return nil
    }
    let accessibilityPoint = CGPoint(x: point.x + 20, y: point.y + 20)
    let appKitPoint = RecordingPillGeometry.appKitPoint(
      fromAccessibilityPoint: accessibilityPoint,
      primaryScreenFrame: primaryScreen.frame
    )
    return NSScreen.screens.first { $0.frame.contains(appKitPoint) }
  }

  private func screenUnderMouse() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
  }
}
