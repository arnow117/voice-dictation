import AppKit
import ApplicationServices
import Carbon
import Foundation
import ShanshuoCore

struct InsertionReceipt {
  let targetProcessIdentifier: Int32
  let targetElementIdentifier: String
  let insertedText: String
  let method: String
  let insertedAt: Date
  let expiresAt: Date
}

enum TextInsertionResult {
  case inserted(InsertionReceipt)
  case copied(String)
  case discarded(String)
  case unverified(String)
}

protocol TextInserting: AnyObject {
  @discardableResult
  func insert(
    _ text: String,
    expectedTarget: SystemFocusSnapshot,
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation

  @discardableResult
  func copy(_ text: String, completion: @escaping (TextInsertionResult) -> Void)
    -> TextInsertionOperation
}

protocol ScheduledTextInsertionWork: AnyObject {
  func cancel()
}

protocol TextInsertionScheduling {
  func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
    -> ScheduledTextInsertionWork
}

protocol TextEventPosting {
  func postPaste()
  func postUnicode(_ text: String)
}

struct ClipboardItemData: Equatable {
  let type: String
  let data: Data
}

typealias ClipboardSnapshot = [[ClipboardItemData]]

protocol ClipboardControlling: AnyObject {
  var changeCount: Int { get }
  func snapshot() -> ClipboardSnapshot
  func writeTemporaryText(_ text: String, onRead: @escaping () -> Void) -> Int?
  func writeText(_ text: String) -> Bool
  func restore(_ snapshot: ClipboardSnapshot)
  func releaseTemporaryTextProvider()
}

/// Direct text input with live security/focus validation. The returned operation owns every delayed
/// paste action, so the coordinator can cancel it before it posts input or changes the clipboard.
final class SystemTextInserter: TextInserting {
  private static let terminalBundleIdentifiers: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
  ]
  // T002 only validated AX selected-text write/readback for Notes. Other applications use the
  // conservative paste route until T015 expands this list with real compatibility evidence.
  private static let axDirectBundleIdentifiers: Set<String> = ["com.apple.Notes"]

  private let permissions: PermissionProviding
  private let focusInspector: FocusInspecting
  private let clipboard: ClipboardControlling
  private let scheduler: TextInsertionScheduling
  private let eventPoster: TextEventPosting
  private let secureInputActive: () -> Bool

  init(
    permissions: PermissionProviding,
    focusInspector: FocusInspecting,
    clipboard: ClipboardControlling = SystemClipboard(),
    scheduler: TextInsertionScheduling = MainTextInsertionScheduler(),
    eventPoster: TextEventPosting = SystemTextEventPoster(),
    secureInputActive: @escaping () -> Bool = { IsSecureEventInputEnabled() }
  ) {
    self.permissions = permissions
    self.focusInspector = focusInspector
    self.clipboard = clipboard
    self.scheduler = scheduler
    self.eventPoster = eventPoster
    self.secureInputActive = secureInputActive
  }

  @discardableResult
  func insert(
    _ text: String,
    expectedTarget: SystemFocusSnapshot,
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation {
    let operation = ManagedTextInsertionOperation(completion: completion)
    guard !text.isEmpty else {
      operation.complete(.discarded("没有听到声音"))
      return operation
    }

    let current = focusInspector.snapshot()
    guard directInsertionIsStillAllowed(expectedTarget, current: current) else {
      copyOrDiscard(text, operation: operation)
      return operation
    }

    if let bundleIdentifier = current.target.bundleIdentifier,
      Self.terminalBundleIdentifiers.contains(bundleIdentifier)
    {
      typeIntoTerminalOrCopy(text, expectedTarget: expectedTarget, operation: operation)
      return operation
    }

    if let bundleIdentifier = current.target.bundleIdentifier,
      Self.axDirectBundleIdentifiers.contains(bundleIdentifier),
      let element = current.element,
      SystemFocusInspector.isAttributeSettable(element, kAXSelectedTextAttribute as String)
    {
      attemptAXInsertion(text, target: current, element: element, operation: operation)
      return operation
    }

    pasteAndRestore(text, expectedTarget: expectedTarget, operation: operation)
    return operation
  }

  @discardableResult
  func copy(
    _ text: String,
    completion: @escaping (TextInsertionResult) -> Void
  ) -> TextInsertionOperation {
    let operation = ManagedTextInsertionOperation(completion: completion)
    copyOrDiscard(text, operation: operation)
    return operation
  }

  private func attemptAXInsertion(
    _ text: String,
    target: SystemFocusSnapshot,
    element: AXUIElement,
    operation: ManagedTextInsertionOperation
  ) {
    guard operation.isActive else {
      return
    }
    let writeResult = AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFString
    )
    guard writeResult == .success else {
      pasteAndRestore(text, expectedTarget: target, operation: operation)
      return
    }

    let readback =
      SystemFocusInspector.copyAttribute(element, kAXSelectedTextAttribute as String) as? String
    guard readback == text,
      let processIdentifier = target.target.processIdentifier,
      let elementIdentifier = target.target.elementIdentifier
    else {
      operation.complete(.unverified("无法验证直接插入结果"))
      return
    }

    let insertedAt = Date()
    operation.complete(
      .inserted(
        InsertionReceipt(
          targetProcessIdentifier: processIdentifier,
          targetElementIdentifier: elementIdentifier,
          insertedText: text,
          method: "ax",
          insertedAt: insertedAt,
          expiresAt: insertedAt.addingTimeInterval(120)
        )
      )
    )
  }

  private func directInsertionIsStillAllowed(
    _ expectedTarget: SystemFocusSnapshot,
    current: SystemFocusSnapshot
  ) -> Bool {
    guard permissions.accessibilityPermission.isAuthorized else {
      return false
    }
    guard !current.target.isSecure, !secureInputActive() else {
      return false
    }
    return focusInspector.match(expectedTarget, current) == .same && current.target.isEditable
  }

  private func directInsertionIsStillAllowed(_ expectedTarget: SystemFocusSnapshot) -> Bool {
    directInsertionIsStillAllowed(expectedTarget, current: focusInspector.snapshot())
  }

  private func copyOrDiscard(_ text: String, operation: ManagedTextInsertionOperation) {
    guard operation.isActive else {
      return
    }
    let current = focusInspector.snapshot()
    guard !current.target.isSecure, !secureInputActive() else {
      operation.complete(.discarded("密码框中不支持语音输入，本次内容已丢弃"))
      return
    }

    let didWrite = clipboard.writeText(text)
    operation.complete(didWrite ? .copied("已复制，按 ⌘V 粘贴") : .unverified("无法写入剪贴板"))
  }

  private func pasteAndRestore(
    _ text: String,
    expectedTarget: SystemFocusSnapshot,
    operation: ManagedTextInsertionOperation
  ) {
    let originalClipboard = clipboard.snapshot()
    var temporaryChangeCount: Int?
    let didWriteTemporaryText = clipboard.writeTemporaryText(
      text,
      onRead: { [weak self, operation] in
        guard let self else {
          return
        }
        guard temporaryChangeCount != nil else {
          return
        }
        let callback = self.scheduler.schedule(after: 0) { [operation] in
          guard operation.isActive, operation.didPostPaste else {
            return
          }
          operation.complete(.unverified("已请求粘贴，无法验证插入结果"))
        }
        operation.add(callback)
      })
    guard let ownedChangeCount = didWriteTemporaryText else {
      copyOrDiscard(text, operation: operation)
      return
    }
    temporaryChangeCount = ownedChangeCount

    operation.onFinish = { [weak self] in
      guard let self else {
        return
      }
      self.restoreOriginalClipboardIfOwned(originalClipboard, ownedChangeCount: ownedChangeCount)
      self.clipboard.releaseTemporaryTextProvider()
    }

    let pasteWork = scheduler.schedule(after: 0.03) { [weak self, operation] in
      guard let self, operation.isActive else {
        return
      }
      guard self.clipboard.changeCount == ownedChangeCount else {
        operation.complete(.unverified("剪贴板已由其他操作更新，未执行粘贴"))
        return
      }
      guard self.directInsertionIsStillAllowed(expectedTarget) else {
        self.copyOrDiscard(text, operation: operation)
        return
      }
      operation.didPostPaste = true
      self.eventPoster.postPaste()
    }
    operation.add(pasteWork)

    let fallbackWork = scheduler.schedule(after: 1) { [operation] in
      guard operation.isActive else {
        return
      }
      operation.complete(.unverified("无法确认插入结果，已恢复剪贴板"))
    }
    operation.add(fallbackWork)
  }

  private func restoreOriginalClipboardIfOwned(
    _ snapshot: ClipboardSnapshot,
    ownedChangeCount: Int
  ) {
    guard
      ClipboardOwnership.mayRestore(
        ownedChangeCount: ownedChangeCount,
        currentChangeCount: clipboard.changeCount
      )
    else {
      return
    }
    clipboard.restore(snapshot)
  }

  private func typeIntoTerminalOrCopy(
    _ text: String,
    expectedTarget: SystemFocusSnapshot,
    operation: ManagedTextInsertionOperation
  ) {
    guard !text.contains("\n"), !text.contains("\r") else {
      copyOrDiscard(text, operation: operation)
      return
    }
    guard directInsertionIsStillAllowed(expectedTarget), operation.isActive else {
      copyOrDiscard(text, operation: operation)
      return
    }

    eventPoster.postUnicode(text)
    operation.complete(.unverified("已发送文本，终端无法验证插入结果"))
  }
}

private final class ManagedTextInsertionOperation: TextInsertionOperation {
  private let completion: (TextInsertionResult) -> Void
  private var scheduledWork: [ScheduledTextInsertionWork] = []
  private(set) var isActive = true
  var didPostPaste = false
  var onFinish: (() -> Void)?

  init(completion: @escaping (TextInsertionResult) -> Void) {
    self.completion = completion
  }

  func add(_ work: ScheduledTextInsertionWork) {
    guard isActive else {
      work.cancel()
      return
    }
    scheduledWork.append(work)
  }

  func complete(_ result: TextInsertionResult) {
    guard isActive else {
      return
    }
    isActive = false
    cancelScheduledWork()
    let finish = onFinish
    onFinish = nil
    finish?()
    completion(result)
  }

  func cancel() {
    guard isActive else {
      return
    }
    isActive = false
    cancelScheduledWork()
    let finish = onFinish
    onFinish = nil
    finish?()
  }

  private func cancelScheduledWork() {
    for work in scheduledWork {
      work.cancel()
    }
    scheduledWork.removeAll()
  }
}

private final class SystemClipboard: NSObject, ClipboardControlling {
  private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
  private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

  private let pasteboard: NSPasteboard
  private var pendingProvider: PasteboardTextProvider?

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  var changeCount: Int {
    pasteboard.changeCount
  }

  func snapshot() -> ClipboardSnapshot {
    (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in
        item.data(forType: type).map { ClipboardItemData(type: type.rawValue, data: $0) }
      }
    }
  }

  func writeTemporaryText(_ text: String, onRead: @escaping () -> Void) -> Int? {
    let item = NSPasteboardItem()
    let provider = PasteboardTextProvider(text: text, onRead: onRead)
    item.setDataProvider(provider, forTypes: [.string])
    item.setData(Data(), forType: Self.transientType)
    item.setData(Data(), forType: Self.concealedType)
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
      return nil
    }
    pendingProvider = provider
    return pasteboard.changeCount
  }

  func writeText(_ text: String) -> Bool {
    pendingProvider = nil
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }

  func restore(_ snapshot: ClipboardSnapshot) {
    pendingProvider = nil
    pasteboard.clearContents()
    let items = snapshot.map { itemData -> NSPasteboardItem in
      let item = NSPasteboardItem()
      for data in itemData {
        item.setData(data.data, forType: NSPasteboard.PasteboardType(data.type))
      }
      return item
    }
    if !items.isEmpty {
      pasteboard.writeObjects(items)
    }
  }

  func releaseTemporaryTextProvider() {
    pendingProvider = nil
  }
}

private final class PasteboardTextProvider: NSObject, NSPasteboardItemDataProvider {
  let text: String
  let onRead: () -> Void

  init(text: String, onRead: @escaping () -> Void) {
    self.text = text
    self.onRead = onRead
  }

  func pasteboard(
    _ pasteboard: NSPasteboard?,
    item: NSPasteboardItem,
    provideDataForType type: NSPasteboard.PasteboardType
  ) {
    item.setString(text, forType: type)
    onRead()
  }
}

private final class MainTextInsertionScheduler: TextInsertionScheduling {
  func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
    -> ScheduledTextInsertionWork
  {
    let work = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    return DispatchTextInsertionWork(work: work)
  }
}

private final class DispatchTextInsertionWork: ScheduledTextInsertionWork {
  private let work: DispatchWorkItem

  init(work: DispatchWorkItem) {
    self.work = work
  }

  func cancel() {
    work.cancel()
  }
}

private struct SystemTextEventPoster: TextEventPosting {
  func postPaste() {
    postKey(code: kVK_ANSI_V, flags: .maskCommand)
  }

  func postUnicode(_ text: String) {
    let source = CGEventSource(stateID: .combinedSessionState)
    let units = Array(text.utf16)
    var start = 0
    while start < units.count {
      let end = min(units.count, start + 20)
      let chunk = Array(units[start..<end])
      for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
        chunk.withUnsafeBufferPointer { buffer in
          event?.keyboardSetUnicodeString(
            stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        event?.post(tap: .cghidEventTap)
      }
      start = end
    }
  }

  private func postKey(code: Int, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for isDown in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: isDown)
      event?.flags = flags
      event?.post(tap: .cghidEventTap)
    }
  }
}
