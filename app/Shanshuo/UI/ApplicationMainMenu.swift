import AppKit

enum ApplicationMainMenu {
  static func make(
    applicationName: String,
    settingsTarget: AnyObject,
    settingsAction: Selector,
    terminationTarget: AnyObject
  ) -> NSMenu {
    let mainMenu = NSMenu()
    mainMenu.addItem(
      makeApplicationMenuItem(
        applicationName: applicationName,
        settingsTarget: settingsTarget,
        settingsAction: settingsAction,
        terminationTarget: terminationTarget
      )
    )
    mainMenu.addItem(makeEditMenuItem())
    return mainMenu
  }

  private static func makeApplicationMenuItem(
    applicationName: String,
    settingsTarget: AnyObject,
    settingsAction: Selector,
    terminationTarget: AnyObject
  ) -> NSMenuItem {
    let applicationItem = NSMenuItem(
      title: applicationName,
      action: nil,
      keyEquivalent: ""
    )
    let applicationMenu = NSMenu(title: applicationName)

    let settingsItem = NSMenuItem(
      title: "设置…",
      action: settingsAction,
      keyEquivalent: ","
    )
    settingsItem.target = settingsTarget
    applicationMenu.addItem(settingsItem)
    applicationMenu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "退出\(applicationName)",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    quitItem.target = terminationTarget
    applicationMenu.addItem(quitItem)

    applicationItem.submenu = applicationMenu
    return applicationItem
  }

  private static func makeEditMenuItem() -> NSMenuItem {
    let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "编辑")
    editMenu.autoenablesItems = true

    editMenu.addItem(
      makeEditCommand(title: "剪切", action: #selector(NSTextView.cut(_:)), keyEquivalent: "x")
    )
    editMenu.addItem(
      makeEditCommand(title: "复制", action: #selector(NSTextView.copy(_:)), keyEquivalent: "c")
    )
    editMenu.addItem(
      makeEditCommand(title: "粘贴", action: #selector(NSTextView.paste(_:)), keyEquivalent: "v")
    )
    editMenu.addItem(.separator())
    editMenu.addItem(
      makeEditCommand(
        title: "全选",
        action: #selector(NSTextView.selectAll(_:)),
        keyEquivalent: "a"
      )
    )

    editItem.submenu = editMenu
    return editItem
  }

  private static func makeEditCommand(
    title: String,
    action: Selector,
    keyEquivalent: String
  ) -> NSMenuItem {
    let command = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    command.keyEquivalentModifierMask = .command
    command.target = nil
    return command
  }
}
