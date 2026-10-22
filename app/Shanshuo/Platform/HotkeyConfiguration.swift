import Carbon
import Foundation

/// The modifier requirements for a hold shortcut. This is deliberately independent of AppKit so
/// preferences and event matching can be tested without an event tap or input-monitoring access.
struct HotkeyModifiers: OptionSet, Codable, Equatable {
  let rawValue: UInt

  static let control = HotkeyModifiers(rawValue: 1 << 0)
  static let shift = HotkeyModifiers(rawValue: 1 << 1)
  static let option = HotkeyModifiers(rawValue: 1 << 2)
  static let command = HotkeyModifiers(rawValue: 1 << 3)
  static let function = HotkeyModifiers(rawValue: 1 << 4)
  static let rightOption = HotkeyModifiers(rawValue: 1 << 5)

  static let ordinaryKeyModifiers: HotkeyModifiers = [
    .control, .shift, .option, .command, .function, .rightOption,
  ]
  static let supportedSingleModifiers: HotkeyModifiers = [
    .control, .shift, .option, .command, .function, .rightOption,
  ]

  /// Caps Lock and unrelated function-key representation must not prevent an otherwise exact
  /// ordinary-key hold. A requested Fn modifier is checked separately by the descriptor.
  static let exactOrdinaryModifiers: HotkeyModifiers = [
    .control, .shift, .option, .command, .rightOption,
  ]
}

/// A serializable shortcut for a non-legacy hold trigger. `keyCode == nil` represents a single
/// modifier. Ordinary keys always require at least one modifier.
struct HotkeyDescriptor: Codable, Equatable {
  let keyCode: UInt16?
  let modifiers: HotkeyModifiers

  init(keyCode: UInt16?, modifiers: HotkeyModifiers) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  var validationError: String? {
    if keyCode == nil {
      let isExactlyOneModifier =
        modifiers.intersection(.supportedSingleModifiers).rawValue
        .nonzeroBitCount == 1
      let hasOnlySupportedModifier = modifiers.isSubset(of: .supportedSingleModifiers)
      return isExactlyOneModifier && hasOnlySupportedModifier
        ? nil
        : "单修饰键只能选择一个 Control、Shift、Option、Command、Fn 或右 Option"
    }

    guard !modifiers.intersection(.ordinaryKeyModifiers).isEmpty else {
      return "普通按键必须同时按住一个修饰键"
    }

    return isReservedSystemCombination ? "这个组合键由 macOS 保留，请换一个组合" : nil
  }

  var isValid: Bool {
    validationError == nil
  }

  func matchesOrdinaryKeyEvent(modifiers eventModifiers: HotkeyModifiers) -> Bool {
    let expectedOrdinary = modifiers.intersection(.exactOrdinaryModifiers)
    let actualOrdinary = eventModifiers.intersection(.exactOrdinaryModifiers)
    guard expectedOrdinary == actualOrdinary else {
      return false
    }

    if modifiers.contains(.function) {
      return eventModifiers.contains(.function)
    }
    return true
  }

  /// These combinations are consumed by macOS before an accessibility event tap can provide a
  /// reliable, non-surprising hold interaction. This is intentionally a small known-reserved
  /// list; an event-tap installation failure is reported separately as unavailable.
  private var isReservedSystemCombination: Bool {
    guard let keyCode else {
      return false
    }

    let commandShortcuts: Set<UInt16> = [48, 49, 50]  // Tab, Space, grave accent
    let controlArrowShortcuts: Set<UInt16> = [123, 124, 125, 126]
    if modifiers.contains(.command), commandShortcuts.contains(keyCode) {
      return true
    }
    if modifiers.contains(.control), controlArrowShortcuts.contains(keyCode) {
      return true
    }
    return false
  }
}

/// Legacy preferences remain readable, while new custom bindings persist an explicit keycode and
/// modifier descriptor. The fallback value is an effective mode, not a user preference rewrite.
enum HoldShortcut: Equatable {
  case function
  case rightOption
  case copyOnlyControlShiftSpace
  case custom(HotkeyDescriptor)

  var storageValue: String {
    switch self {
    case .function:
      return "function"
    case .rightOption:
      return "rightOption"
    case .copyOnlyControlShiftSpace:
      return "copyOnlyControlShiftSpace"
    case .custom(let descriptor):
      guard let data = try? JSONEncoder().encode(descriptor) else {
        return "function"
      }
      return "custom:" + data.base64EncodedString()
    }
  }

  init?(storageValue: String) {
    switch storageValue {
    case "function":
      self = .function
    case "rightOption":
      self = .rightOption
    case "copyOnlyControlShiftSpace":
      self = .copyOnlyControlShiftSpace
    default:
      guard storageValue.hasPrefix("custom:") else {
        return nil
      }
      let encodedDescriptor = String(storageValue.dropFirst("custom:".count))
      guard let data = Data(base64Encoded: encodedDescriptor),
        let descriptor = try? JSONDecoder().decode(HotkeyDescriptor.self, from: data),
        descriptor.isValid
      else {
        return nil
      }
      self = .custom(descriptor)
    }
  }

  var displayName: String {
    switch self {
    case .function:
      return "Fn"
    case .rightOption:
      return "右 Option"
    case .copyOnlyControlShiftSpace:
      return "⌃⇧ Space"
    case .custom(let descriptor):
      return descriptor.displayName
    }
  }

  var descriptor: HotkeyDescriptor? {
    switch self {
    case .function:
      return HotkeyDescriptor(keyCode: nil, modifiers: .function)
    case .rightOption:
      return HotkeyDescriptor(keyCode: nil, modifiers: .rightOption)
    case .copyOnlyControlShiftSpace:
      return HotkeyDescriptor(keyCode: 49, modifiers: [.control, .shift])
    case .custom(let descriptor):
      return descriptor
    }
  }
}

enum HotkeyProjection {
  static func effectiveShortcut(
    preferred: HoldShortcut,
    accessibilityAuthorized: Bool
  ) -> HoldShortcut {
    accessibilityAuthorized ? preferred : .copyOnlyControlShiftSpace
  }
}

extension HotkeyDescriptor {
  var displayName: String {
    if keyCode == nil {
      return HotkeyDescriptor.modifierLabel(for: modifiers)
    }

    let labels = [
      modifiers.contains(.control) ? "⌃" : "",
      modifiers.contains(.shift) ? "⇧" : "",
      modifiers.contains(.option) ? "⌥" : "",
      modifiers.contains(.rightOption) ? "右⌥" : "",
      modifiers.contains(.command) ? "⌘" : "",
      modifiers.contains(.function) ? "Fn" : "",
    ].joined()
    return labels + HotkeyDescriptor.keyName(for: keyCode!)
  }

  private static func modifierLabel(for modifiers: HotkeyModifiers) -> String {
    if modifiers == .control {
      return "Control"
    }
    if modifiers == .shift {
      return "Shift"
    }
    if modifiers == .option {
      return "Option"
    }
    if modifiers == .command {
      return "Command"
    }
    if modifiers == .function {
      return "Fn"
    }
    if modifiers == .rightOption {
      return "右 Option"
    }
    return "不可用的修饰键"
  }

  private static func keyName(for keyCode: UInt16) -> String {
    let namedKeys: [UInt16: String] = [
      36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
      123: "←", 124: "→", 125: "↓", 126: "↑",
      122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
      98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
      105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
      80: "F19", 90: "F20",
    ]
    if let name = namedKeys[keyCode] {
      return name
    }
    return currentLayoutKeyName(for: keyCode) ?? "未识别按键"
  }

  /// Uses the byte buffer inside `kTISPropertyUnicodeKeyLayoutData`. The property itself is a
  /// CFData object; treating the object's pointer as a UCKeyboardLayout points at object metadata
  /// and produces an unreliable label (or no label) for ordinary keys.
  static func currentLayoutKeyName(for keyCode: UInt16) -> String? {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let layoutDataPointer = TISGetInputSourceProperty(
        inputSource,
        kTISPropertyUnicodeKeyLayoutData
      )
    else {
      return nil
    }

    let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue()
    return translatedKeyName(for: keyCode, layoutData: layoutData)
  }

  /// Kept separate from TIS lookup so the harness can execute UCKeyTranslate against a live
  /// current-layout CFData object when the test process has access to one.
  static func translatedKeyName(for keyCode: UInt16, layoutData: CFData) -> String? {
    guard let layoutBytes = CFDataGetBytePtr(layoutData) else {
      return nil
    }

    let keyboardLayout = UnsafeRawPointer(layoutBytes).assumingMemoryBound(
      to: UCKeyboardLayout.self)
    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 8)
    let status = UCKeyTranslate(
      keyboardLayout,
      keyCode,
      UInt16(kUCKeyActionDisplay),
      0,
      UInt32(LMGetKbdType()),
      OptionBits(kUCKeyTranslateNoDeadKeysBit),
      &deadKeyState,
      characters.count,
      &length,
      &characters
    )
    guard status == noErr, length > 0 else {
      return nil
    }

    return String(utf16CodeUnits: characters, count: Int(length)).uppercased()
  }
}

/// Pure state for the custom ordinary-key event stream. Once the physical trigger was consumed,
/// its repeats and final key-up remain consumed even if required modifiers are released first.
struct CustomHoldShortcutEventReducer {
  enum Effect: Equatable {
    case passThrough
    case beginAndConsume
    case endAndConsume
    case cancelAndConsume
    case consume
  }

  private(set) var isHolding = false
  private(set) var consumedTriggerKeyCode: UInt16?

  mutating func keyDown(
    keyCode: UInt16,
    modifiers: HotkeyModifiers,
    descriptor: HotkeyDescriptor,
    isAutorepeat: Bool
  ) -> Effect {
    guard descriptor.keyCode == keyCode else {
      return .passThrough
    }
    if consumedTriggerKeyCode == keyCode {
      return .consume
    }
    guard !isAutorepeat, descriptor.matchesOrdinaryKeyEvent(modifiers: modifiers) else {
      return .passThrough
    }

    isHolding = true
    consumedTriggerKeyCode = keyCode
    return .beginAndConsume
  }

  mutating func keyUp(keyCode: UInt16) -> Effect {
    guard consumedTriggerKeyCode == keyCode else {
      return .passThrough
    }
    consumedTriggerKeyCode = nil
    if isHolding {
      isHolding = false
      return .endAndConsume
    }
    return .consume
  }

  mutating func modifierStateChanged(
    modifiers: HotkeyModifiers,
    descriptor: HotkeyDescriptor
  ) -> Effect {
    guard isHolding, !descriptor.matchesOrdinaryKeyEvent(modifiers: modifiers) else {
      return .passThrough
    }
    isHolding = false
    return .endAndConsume
  }

  mutating func otherKeyPressed() -> Effect {
    guard isHolding else {
      return .passThrough
    }
    isHolding = false
    return .cancelAndConsume
  }

  mutating func reset() {
    isHolding = false
    consumedTriggerKeyCode = nil
  }
}

/// Recorder state delays committing a single modifier until its release, so a modifier followed by
/// an ordinary key is captured as one chord rather than being committed on modifier-down.
enum HotkeyCaptureResult: Equatable {
  case captured(HoldShortcut)
  case rejected(String)
}

struct HotkeyCaptureState {
  private var pendingSingleModifier: HotkeyModifiers?
  private(set) var rightOptionIsHeld = false

  mutating func modifierChanged(keyCode: UInt16, isPressed: Bool) -> HoldShortcut? {
    guard let modifier = Self.modifier(for: keyCode) else {
      return nil
    }
    if modifier == .rightOption {
      rightOptionIsHeld = isPressed
    }

    if isPressed {
      pendingSingleModifier = modifier
      return nil
    }
    guard pendingSingleModifier == modifier else {
      return nil
    }
    pendingSingleModifier = nil
    return Self.shortcut(for: modifier)
  }

  mutating func ordinaryKeyPressed(
    keyCode: UInt16,
    modifiers: HotkeyModifiers
  ) -> HotkeyCaptureResult {
    pendingSingleModifier = nil
    let descriptor = HotkeyDescriptor(keyCode: keyCode, modifiers: modifiers)
    if let error = descriptor.validationError {
      return .rejected(error)
    }
    return .captured(.custom(descriptor))
  }

  mutating func reset() {
    pendingSingleModifier = nil
    rightOptionIsHeld = false
  }

  private static func modifier(for keyCode: UInt16) -> HotkeyModifiers? {
    switch keyCode {
    case UInt16(kVK_Control):
      return .control
    case UInt16(kVK_Shift):
      return .shift
    case UInt16(kVK_Option):
      return .option
    case UInt16(kVK_Command):
      return .command
    case UInt16(kVK_Function):
      return .function
    case UInt16(kVK_RightOption):
      return .rightOption
    default:
      return nil
    }
  }

  private static func shortcut(for modifier: HotkeyModifiers) -> HoldShortcut {
    if modifier == .function {
      return .function
    }
    if modifier == .rightOption {
      return .rightOption
    }
    return .custom(HotkeyDescriptor(keyCode: nil, modifiers: modifier))
  }
}
