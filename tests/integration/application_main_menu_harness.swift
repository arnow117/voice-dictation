import AppKit
import Foundation

private struct ClipboardItemData {
  let type: NSPasteboard.PasteboardType
  let data: Data
}

private typealias ClipboardSnapshot = [[ClipboardItemData]]

private final class PasteObservation {
  var didObserve = false
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func snapshotClipboard(_ pasteboard: NSPasteboard) -> ClipboardSnapshot {
  (pasteboard.pasteboardItems ?? []).map { item in
    item.types.compactMap { type in
      guard let data = item.data(forType: type) else {
        return nil
      }
      return ClipboardItemData(type: type, data: data)
    }
  }
}

private func restoreClipboard(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) -> Bool {
  pasteboard.clearContents()

  guard !snapshot.isEmpty else {
    return true
  }

  let items = snapshot.map { itemData in
    let item = NSPasteboardItem()
    for data in itemData {
      item.setData(data.data, forType: data.type)
    }
    return item
  }
  return pasteboard.writeObjects(items)
}

private func command(named title: String, in menu: NSMenu) -> NSMenuItem {
  guard let item = menu.item(withTitle: title) else {
    fputs("FAIL: missing Edit command \(title)\n", stderr)
    exit(1)
  }
  return item
}

@main
enum ApplicationMainMenuHarness {
  static func main() {
    _ = NSApplication.shared

    let settingsTarget = NSObject()
    let mainMenu = ApplicationMainMenu.make(
      applicationName: "闪说",
      settingsTarget: settingsTarget,
      settingsAction: #selector(NSObject.description),
      terminationTarget: NSApp
    )

    guard let applicationMenu = mainMenu.items.first?.submenu else {
      check(false, "production main menu includes the application submenu")
      return
    }
    check(
      applicationMenu.item(withTitle: "设置…")?.target === settingsTarget,
      "settings continues to target the application delegate")
    check(
      applicationMenu.item(withTitle: "退出闪说")?.target === NSApp,
      "quit continues to target NSApplication")

    guard let editMenu = mainMenu.item(withTitle: "编辑")?.submenu else {
      check(false, "production main menu includes an Edit submenu")
      return
    }

    let cut = command(named: "剪切", in: editMenu)
    let copy = command(named: "复制", in: editMenu)
    let paste = command(named: "粘贴", in: editMenu)
    let selectAll = command(named: "全选", in: editMenu)

    check(cut.action == #selector(NSTextView.cut(_:)), "Cut uses the native responder action")
    check(copy.action == #selector(NSTextView.copy(_:)), "Copy uses the native responder action")
    check(paste.action == #selector(NSTextView.paste(_:)), "Paste uses the native responder action")
    check(
      selectAll.action == #selector(NSTextView.selectAll(_:)),
      "Select All uses the native responder action")

    for command in [cut, copy, paste, selectAll] {
      check(command.target == nil, "Edit commands are resolved through the first responder")
      check(
        command.keyEquivalentModifierMask == .command,
        "Edit commands use Command key equivalents")
    }

    let practiceTextView = PracticeTextView(frame: .zero)
    practiceTextView.string = "selected-text"
    practiceTextView.setSelectedRange(
      NSRange(location: 0, length: (practiceTextView.string as NSString).length))

    let didSelectAll = practiceTextView.tryToPerform(
      #selector(NSTextView.selectAll(_:)),
      with: selectAll
    )
    check(didSelectAll, "Select All reaches the production practice text view")
    check(
      practiceTextView.selectedRange()
        == NSRange(
          location: 0,
          length: (practiceTextView.string as NSString).length
        ),
      "Select All selects the practice text view contents"
    )

    let pasteObservation = PasteObservation()
    practiceTextView.onPaste = {
      pasteObservation.didObserve = true
    }

    let temporaryPasteboard = NSPasteboard.withUniqueName()
    let canWriteTemporaryPasteboard = temporaryPasteboard.setString(
      "shanshuo-menu-test-\(UUID().uuidString)",
      forType: .string
    )
    if canWriteTemporaryPasteboard {
      let pasteboard = NSPasteboard.general
      let clipboardSnapshot = snapshotClipboard(pasteboard)
      defer {
        check(
          restoreClipboard(clipboardSnapshot, to: pasteboard),
          "the native menu harness restores the clipboard")
      }

      pasteboard.clearContents()
      check(
        pasteboard.setString("shanshuo-menu-test-\(UUID().uuidString)", forType: .string),
        "the native menu harness can set isolated test clipboard data"
      )
      verifyPasteRoute(practiceTextView, menuItem: paste, observation: pasteObservation)
    } else {
      verifyPasteRoute(practiceTextView, menuItem: paste, observation: pasteObservation)
      print("shared pasteboard unavailable; skipped clipboard data and restoration check")
    }

    print("application main menu harness passed")
  }

  private static func verifyPasteRoute(
    _ practiceTextView: PracticeTextView,
    menuItem: NSMenuItem,
    observation: PasteObservation
  ) {
    let didPaste = practiceTextView.tryToPerform(#selector(NSTextView.paste(_:)), with: menuItem)
    check(didPaste, "Paste reaches the production practice text view")
    check(
      observation.didObserve,
      "Paste reaches PracticeTextView.paste before AppKit handles clipboard data"
    )
  }
}
