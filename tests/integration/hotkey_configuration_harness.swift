import Carbon
import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
enum HotkeyConfigurationHarness {
  static func main() {
    testLegacyAndCustomSerialization()
    testInvalidAndReservedBindings()
    testRecorderDelaysSingleModifierCommit()
    testCustomHoldEventReducer()
    testOtherKeyCancellationKeepsPhysicalTriggerConsumed()
    testReadableShortcutLabels()
    testCurrentLayoutTranslationWhenAvailable()
    print("hotkey configuration harness passed")
  }

  private static func testLegacyAndCustomSerialization() {
    check(HoldShortcut(storageValue: "function") == .function, "reads legacy Fn preference")
    check(
      HoldShortcut(storageValue: "rightOption") == .rightOption,
      "reads legacy right Option preference"
    )
    check(
      HoldShortcut(storageValue: "copyOnlyControlShiftSpace") == .copyOnlyControlShiftSpace,
      "reads legacy copy-only preference"
    )

    let descriptor = HotkeyDescriptor(keyCode: 40, modifiers: [.control, .shift])
    let shortcut = HoldShortcut.custom(descriptor)
    check(
      HoldShortcut(storageValue: shortcut.storageValue) == shortcut,
      "round-trips a custom keycode and modifier descriptor"
    )
    check(
      HotkeyProjection.effectiveShortcut(preferred: shortcut, accessibilityAuthorized: false)
        == .copyOnlyControlShiftSpace,
      "no-Accessibility fallback changes the effective shortcut without overwriting a custom preference"
    )
  }

  private static func testInvalidAndReservedBindings() {
    let bareKey = HotkeyDescriptor(keyCode: 40, modifiers: [])
    check(!bareKey.isValid, "rejects a bare ordinary key")

    let reservedCommandSpace = HotkeyDescriptor(keyCode: 49, modifiers: [.command])
    check(!reservedCommandSpace.isValid, "rejects Command-Space")

    let singleModifiers: [HotkeyModifiers] = [
      .control, .shift, .option, .command, .function, .rightOption,
    ]
    for modifier in singleModifiers {
      let descriptor = HotkeyDescriptor(keyCode: nil, modifiers: modifier)
      check(descriptor.isValid, "supports promised single modifier \(modifier.rawValue)")
    }
  }

  private static func testRecorderDelaysSingleModifierCommit() {
    var state = HotkeyCaptureState()
    check(
      state.modifierChanged(keyCode: UInt16(kVK_RightOption), isPressed: true) == nil,
      "right Option down waits for a possible chord"
    )
    check(state.rightOptionIsHeld, "right Option is remembered while a chord is recorded")
    let rightOptionChord = state.ordinaryKeyPressed(
      keyCode: 40,
      modifiers: [.rightOption]
    )
    check(
      rightOptionChord
        == .captured(.custom(HotkeyDescriptor(keyCode: 40, modifiers: [.rightOption]))),
      "right Option followed by an ordinary key records a chord instead of committing early"
    )
    check(
      state.modifierChanged(keyCode: UInt16(kVK_RightOption), isPressed: false) == nil,
      "releasing a modifier after a chord does not replace the captured chord"
    )

    state.reset()
    check(
      state.modifierChanged(keyCode: UInt16(kVK_Control), isPressed: true) == nil,
      "single Control also waits for release"
    )
    check(
      state.modifierChanged(keyCode: UInt16(kVK_Control), isPressed: false)
        == .custom(HotkeyDescriptor(keyCode: nil, modifiers: .control)),
      "a released unchorded modifier commits as a single-modifier shortcut"
    )
  }

  private static func testCustomHoldEventReducer() {
    let descriptor = HotkeyDescriptor(keyCode: 40, modifiers: [.control, .shift])
    var reducer = CustomHoldShortcutEventReducer()

    check(
      reducer.keyDown(
        keyCode: 40,
        modifiers: [.control, .shift, .option],
        descriptor: descriptor,
        isAutorepeat: false
      ) == .passThrough,
      "extra ordinary modifiers do not trigger an exact custom shortcut"
    )
    check(
      reducer.keyDown(
        keyCode: 40,
        modifiers: [.control, .shift],
        descriptor: descriptor,
        isAutorepeat: false
      ) == .beginAndConsume,
      "exact modifiers begin and consume the physical trigger"
    )
    check(
      reducer.modifierStateChanged(modifiers: [.control], descriptor: descriptor)
        == .endAndConsume,
      "required modifier release ends the hold once"
    )
    check(
      reducer.keyDown(
        keyCode: 40,
        modifiers: [.control],
        descriptor: descriptor,
        isAutorepeat: true
      ) == .consume,
      "trigger repeats remain consumed after modifier release"
    )
    check(
      reducer.keyUp(keyCode: 40) == .consume,
      "final trigger key-up remains consumed after the session already ended"
    )
    check(!reducer.isHolding, "modifier release cannot leave the old session holding")

    let rightOptionDescriptor = HotkeyDescriptor(keyCode: 40, modifiers: [.rightOption])
    check(
      rightOptionDescriptor.matchesOrdinaryKeyEvent(modifiers: [.rightOption]),
      "right Option chord matches its physical modifier"
    )
    check(
      !rightOptionDescriptor.matchesOrdinaryKeyEvent(modifiers: [.option]),
      "left and right Option remain distinct for exact matching"
    )
  }

  private static func testReadableShortcutLabels() {
    let ordinary = HotkeyDescriptor(keyCode: 40, modifiers: [.control, .shift])
    check(
      !ordinary.displayName.contains("键码"), "custom shortcut display never exposes storage keycodes"
    )
    check(ordinary.displayName.hasPrefix("⌃⇧"), "custom shortcut display keeps modifier symbols")
    check(
      HotkeyDescriptor(keyCode: 122, modifiers: [.option]).displayName.contains("F1"),
      "function keys have stable user-facing names"
    )
  }

  private static func testOtherKeyCancellationKeepsPhysicalTriggerConsumed() {
    let descriptor = HotkeyDescriptor(keyCode: 40, modifiers: [.control, .shift])
    var reducer = CustomHoldShortcutEventReducer()

    check(
      reducer.keyDown(
        keyCode: 40,
        modifiers: [.control, .shift],
        descriptor: descriptor,
        isAutorepeat: false
      ) == .beginAndConsume,
      "the production custom shortcut reducer begins a held K trigger"
    )
    check(
      SystemHotkeyMonitor.reduceOtherKey(state: &reducer, legacyShortcutIsHolding: false),
      "an unrelated J cancels the held custom shortcut through the production event route"
    )
    check(
      reducer.keyDown(
        keyCode: 40,
        modifiers: [.control, .shift],
        descriptor: descriptor,
        isAutorepeat: true
      ) == .consume,
      "K autorepeat remains consumed after J cancelled the session"
    )
    check(
      reducer.keyUp(keyCode: 40) == .consume,
      "K key-up remains consumed after J cancelled the session"
    )
  }

  private static func testCurrentLayoutTranslationWhenAvailable() {
    guard let keyName = HotkeyDescriptor.currentLayoutKeyName(for: 40) else {
      print(
        "current keyboard layout is unavailable in this harness process; GUI K-label check remains required"
      )
      return
    }

    check(!keyName.isEmpty, "a live Unicode keyboard layout translates keycode 40 to a label")
    check(keyName != "未识别按键", "a live Unicode keyboard layout never exposes an unresolved keycode")
    print("live current-layout translation exercised for keycode 40: \(keyName)")
  }
}
