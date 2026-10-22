import AVFoundation
import AppKit
import ApplicationServices
import Carbon
import ShanshuoCore

protocol PermissionProviding: AnyObject {
  var microphonePermission: PermissionStatus { get }
  var accessibilityPermission: PermissionStatus { get }
}

protocol PermissionRequesting: PermissionProviding {
  func requestMicrophoneAccess(completion: @escaping (Bool) -> Void)
}

final class SystemPermissionService: PermissionRequesting {
  var microphonePermission: PermissionStatus {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return .authorized
    case .denied:
      return .denied
    case .restricted:
      return .restricted
    case .notDetermined:
      return .notDetermined
    @unknown default:
      return .denied
    }
  }

  var accessibilityPermission: PermissionStatus {
    AXIsProcessTrusted() ? .authorized : .denied
  }

  func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      DispatchQueue.main.async {
        completion(granted)
      }
    }
  }
}

/// Keeps the platform AX object only in the app layer. The pure core receives the corresponding
/// `TargetSnapshot`, which contains no field contents.
struct SystemFocusSnapshot {
  let target: TargetSnapshot
  let element: AXUIElement?
}

protocol FocusInspecting: AnyObject {
  func snapshot() -> SystemFocusSnapshot
  func match(_ expected: SystemFocusSnapshot, _ actual: SystemFocusSnapshot) -> FocusMatch
}

final class SystemFocusInspector: FocusInspecting {
  func snapshot() -> SystemFocusSnapshot {
    let application = NSWorkspace.shared.frontmostApplication
    let bundleIdentifier = application?.bundleIdentifier
    let processIdentifier = application.map { Int32($0.processIdentifier) }
    let systemSecure = IsSecureEventInputEnabled()

    guard AXIsProcessTrusted(), let application else {
      return SystemFocusSnapshot(
        target: TargetSnapshot(
          bundleIdentifier: bundleIdentifier,
          processIdentifier: processIdentifier,
          elementIdentifier: nil,
          isEditable: false,
          isSecure: systemSecure
        ),
        element: nil
      )
    }

    let focusedElement = focusedElement(for: application.processIdentifier)
    guard let focusedElement else {
      return SystemFocusSnapshot(
        target: TargetSnapshot(
          bundleIdentifier: bundleIdentifier,
          processIdentifier: processIdentifier,
          elementIdentifier: nil,
          isEditable: false,
          isSecure: systemSecure
        ),
        element: nil
      )
    }

    let role = stringAttribute(focusedElement, kAXRoleAttribute as String) ?? "unknown"
    let subrole = stringAttribute(focusedElement, kAXSubroleAttribute as String) ?? ""
    let isSecure = systemSecure || subrole == (kAXSecureTextFieldSubrole as String)
    let isEditable = isEditableTextControl(
      focusedElement,
      bundleIdentifier: bundleIdentifier,
      role: role,
      subrole: subrole
    )
    let accessibilityIdentifier = stringAttribute(focusedElement, kAXIdentifierAttribute as String)
    let identity = accessibilityIdentifier ?? "\(processIdentifier ?? -1):\(role):\(subrole)"

    return SystemFocusSnapshot(
      target: TargetSnapshot(
        bundleIdentifier: bundleIdentifier,
        processIdentifier: processIdentifier,
        elementIdentifier: identity,
        isEditable: isEditable,
        isSecure: isSecure
      ),
      element: focusedElement
    )
  }

  func match(_ expected: SystemFocusSnapshot, _ actual: SystemFocusSnapshot) -> FocusMatch {
    guard expected.target.processIdentifier == actual.target.processIdentifier else {
      return .changed
    }
    guard let expectedElement = expected.element, let actualElement = actual.element else {
      return .unknown
    }
    return CFEqual(expectedElement, actualElement) ? .same : .changed
  }

  private func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    if let value = Self.axElementAttribute(systemWide, kAXFocusedUIElementAttribute as String) {
      return value
    }

    let application = AXUIElementCreateApplication(processIdentifier)
    if let value = Self.axElementAttribute(application, kAXFocusedUIElementAttribute as String) {
      return value
    }
    return nil
  }

  static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
  }

  static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    copyAttribute(element, attribute) as? String
  }

  static func axElementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copyAttribute(element, attribute),
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
  }

  static func axValueAttribute(_ element: AXUIElement, _ attribute: String) -> AXValue? {
    guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    return unsafeBitCast(value, to: AXValue.self)
  }

  static func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var isSettable = DarwinBoolean(false)
    let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable)
    return result == .success && isSettable.boolValue
  }

  private func isEditableTextControl(
    _ element: AXUIElement,
    bundleIdentifier: String?,
    role: String,
    subrole: String
  ) -> Bool {
    if isAttributeSettable(element, kAXSelectedTextAttribute as String) {
      return true
    }

    let textControlRoles = ["AXTextField", "AXTextArea", "AXComboBox"]
    let isKnownTextControl = textControlRoles.contains(role) || subrole == "AXSearchField"
    let hasSelectionRange = copyAttribute(element, kAXSelectedTextRangeAttribute as String) != nil
    let canSetValue = isAttributeSettable(element, kAXValueAttribute as String)
    if isKnownTextControl && (hasSelectionRange || canSetValue) {
      return true
    }

    let terminalBundleIdentifiers: Set<String> = [
      "com.apple.Terminal",
      "com.googlecode.iterm2",
    ]
    return terminalBundleIdentifiers.contains(bundleIdentifier ?? "")
      && role == "AXTextArea"
      && hasSelectionRange
  }

  private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    Self.copyAttribute(element, attribute)
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    Self.stringAttribute(element, attribute)
  }

  private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    Self.isAttributeSettable(element, attribute)
  }
}

protocol HotkeyMonitoring: AnyObject {
  var isShortcutAvailable: Bool { get }
  var onHold: ((HoldShortcut, Bool) -> Void)? { get set }
  var onCancel: (() -> Void)? { get set }
  var onOtherKey: (() -> Void)? { get set }
  var selectedShortcut: HoldShortcut { get set }
  func refresh(accessibilityAuthorized: Bool)
  func setCancellationInterception(_ enabled: Bool)
  func setTriggeringSuspended(_ suspended: Bool)
  func stop()
}

/// Accessibility-enabled event tap for Fn/right Option and Carbon fallback for ⌃⇧Space. It never
/// requests input-monitoring permission.
final class SystemHotkeyMonitor: HotkeyMonitoring {
  var onHold: ((HoldShortcut, Bool) -> Void)?
  var onCancel: (() -> Void)?
  var onOtherKey: (() -> Void)?
  var selectedShortcut: HoldShortcut = .function {
    didSet {
      updateCarbonShortcutRegistration()
    }
  }
  private(set) var isShortcutAvailable = false

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var functionDown = false
  private var rightOptionDown = false
  private var singleModifierKeyCode: UInt16?
  private var customShortcutState = CustomHoldShortcutEventReducer()
  private var accessibilityAuthorized = false
  private var cancellationInterception = false
  private var triggeringSuspended = false
  private var carbonShortcut: EventHotKeyRef?
  private var carbonEscapeShortcuts: [EventHotKeyRef] = []
  private var carbonHandler: EventHandlerRef?
  private let signature = OSType(0x5353_484B)  // SSHK

  init() {
    installCarbonHandler()
  }

  deinit {
    stop()
  }

  func refresh(accessibilityAuthorized: Bool) {
    self.accessibilityAuthorized = accessibilityAuthorized
    if accessibilityAuthorized {
      installEventTapIfNeeded()
    } else {
      removeEventTap()
    }
    updateCarbonShortcutRegistration()
  }

  func setCancellationInterception(_ enabled: Bool) {
    cancellationInterception = enabled
    if accessibilityAuthorized {
      return
    }
    setCarbonEscape(enabled)
  }

  func setTriggeringSuspended(_ suspended: Bool) {
    triggeringSuspended = suspended
    customShortcutState.reset()
    functionDown = false
    rightOptionDown = false
    singleModifierKeyCode = nil
    if suspended {
      unregisterCarbonShortcut(&carbonShortcut)
      return
    }
    updateCarbonShortcutRegistration()
  }

  func stop() {
    removeEventTap()
    unregisterCarbonShortcut(&carbonShortcut)
    setCarbonEscape(false)
    if let carbonHandler {
      RemoveEventHandler(carbonHandler)
      self.carbonHandler = nil
    }
  }

  private func installEventTapIfNeeded() {
    guard eventTap == nil else {
      if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return
    }

    let eventMask =
      (1 << CGEventType.flagsChanged.rawValue)
      | (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.keyUp.rawValue)
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(eventMask),
        callback: { _, type, event, userInfo in
          guard let userInfo else {
            return Unmanaged.passUnretained(event)
          }
          let monitor = Unmanaged<SystemHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
          return monitor.handleEvent(type, event)
        },
        userInfo: pointer
      )
    else {
      isShortcutAvailable = false
      return
    }

    self.eventTap = eventTap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    isShortcutAvailable = true
  }

  private func removeEventTap() {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
    }
    eventTap = nil
    runLoopSource = nil
    functionDown = false
    rightOptionDown = false
    singleModifierKeyCode = nil
    customShortcutState.reset()
    if accessibilityAuthorized {
      isShortcutAvailable = false
    }
  }

  private func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    // Shortcut recording is handled by the settings window's first responder. The global tap
    // remains installed but must neither begin a session nor consume the candidate key.
    guard !triggeringSuspended else {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged {
      if keyCode == Int64(kVK_Function) {
        updateFunction(isDown: event.flags.contains(.maskSecondaryFn))
      } else if keyCode == Int64(kVK_RightOption) {
        let deviceRightOptionMask: UInt64 = 0x40
        updateRightOption(isDown: event.flags.rawValue & deviceRightOptionMask != 0)
      }
      updateSingleModifierShortcut(keyCode: UInt16(keyCode), flags: event.flags)
      updateCustomShortcutForModifierChange(event: event)
      return Unmanaged.passUnretained(event)
    }

    if keyCode == Int64(kVK_Escape), type == .keyDown {
      let shouldConsume = Self.handleEscape(
        cancellationInterceptionEnabled: cancellationInterception,
        onCancel: onCancel
      )
      return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    if let result = handleCustomShortcutKeyEvent(type: type, event: event) {
      return result ? nil : Unmanaged.passUnretained(event)
    }

    if type == .keyDown,
      event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
      functionDown || rightOptionDown || singleModifierKeyCode != nil
        || customShortcutState.isHolding
    {
      let holdsLegacyShortcut =
        functionDown || rightOptionDown || singleModifierKeyCode != nil
      let shouldCancel = Self.reduceOtherKey(
        state: &customShortcutState,
        legacyShortcutIsHolding: holdsLegacyShortcut
      )
      singleModifierKeyCode = nil
      if shouldCancel {
        onOtherKey?()
      }
    }
    return Unmanaged.passUnretained(event)
  }

  private func updateFunction(isDown: Bool) {
    guard functionDown != isDown else {
      return
    }
    functionDown = isDown
    if isFunctionShortcut(selectedShortcut) {
      onHold?(selectedShortcut, isDown)
    }
  }

  /// Captures the interception state before cancellation resets it. Kept separately so the event
  /// tap's behavior is testable without manufacturing a CGEvent in a test process.
  static func handleEscape(
    cancellationInterceptionEnabled: Bool,
    onCancel: (() -> Void)?
  ) -> Bool {
    let shouldConsume = DictationRules.shouldConsumeEscape(
      cancellationInterceptionEnabled: cancellationInterceptionEnabled
    )
    onCancel?()
    return shouldConsume
  }

  /// Routes an unrelated key through the same reducer used by the event tap. The reducer clears
  /// the held session but intentionally keeps the physical trigger until its final key-up, so
  /// repeats and the release cannot leak into the target application after cancellation.
  static func reduceOtherKey(
    state: inout CustomHoldShortcutEventReducer,
    legacyShortcutIsHolding: Bool
  ) -> Bool {
    let customEffect = state.otherKeyPressed()
    return legacyShortcutIsHolding || customEffect == .cancelAndConsume
  }

  private func updateRightOption(isDown: Bool) {
    guard rightOptionDown != isDown else {
      return
    }
    rightOptionDown = isDown
    if isRightOptionShortcut(selectedShortcut) {
      onHold?(selectedShortcut, isDown)
    }
  }

  private func updateSingleModifierShortcut(keyCode: UInt16, flags: CGEventFlags) {
    guard let expectedModifier = modifier(for: keyCode) else {
      return
    }

    guard expectedModifier != .function, expectedModifier != .rightOption else {
      return
    }
    guard isSingleModifierShortcut(selectedShortcut, modifier: expectedModifier) else {
      if singleModifierKeyCode != nil, singleModifierKeyCode != keyCode {
        singleModifierKeyCode = nil
        onOtherKey?()
      }
      return
    }

    let isDown = modifier(expectedModifier, isDownIn: flags)
    if isDown {
      guard singleModifierKeyCode != keyCode else {
        return
      }
      singleModifierKeyCode = keyCode
      onHold?(selectedShortcut, true)
      return
    }

    guard singleModifierKeyCode == keyCode else {
      return
    }
    singleModifierKeyCode = nil
    onHold?(selectedShortcut, false)
  }

  private func installCarbonHandler() {
    var eventTypes = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userInfo in
        guard let userInfo else {
          return noErr
        }
        let monitor = Unmanaged<SystemHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handleCarbonEvent(event)
        return noErr
      },
      eventTypes.count,
      &eventTypes,
      pointer,
      &carbonHandler
    )

  }

  private func updateCarbonShortcutRegistration() {
    if triggeringSuspended {
      unregisterCarbonShortcut(&carbonShortcut)
      return
    }
    let needsCopyOnlyShortcut = !accessibilityAuthorized
    guard needsCopyOnlyShortcut else {
      unregisterCarbonShortcut(&carbonShortcut)
      if accessibilityAuthorized {
        isShortcutAvailable = eventTap != nil
      }
      return
    }

    guard carbonShortcut == nil else {
      isShortcutAvailable = true
      return
    }
    let status = RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(controlKey | shiftKey),
      EventHotKeyID(signature: signature, id: 1),
      GetApplicationEventTarget(),
      0,
      &carbonShortcut
    )
    isShortcutAvailable = status == noErr && carbonShortcut != nil
  }

  private func handleCarbonEvent(_ event: EventRef?) {
    guard let event else {
      return
    }
    var identifier = EventHotKeyID()
    GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &identifier
    )
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    if identifier.id == 1, !accessibilityAuthorized, !triggeringSuspended {
      onHold?(.copyOnlyControlShiftSpace, pressed)
    } else if identifier.id != 1, pressed {
      onCancel?()
    }
  }

  private func setCarbonEscape(_ enabled: Bool) {
    if enabled && carbonEscapeShortcuts.isEmpty {
      let modifierSets: [UInt32] = [0, UInt32(controlKey | shiftKey)]
      for (index, modifiers) in modifierSets.enumerated() {
        var reference: EventHotKeyRef?
        RegisterEventHotKey(
          UInt32(kVK_Escape),
          modifiers,
          EventHotKeyID(signature: signature, id: UInt32(10 + index)),
          GetApplicationEventTarget(),
          0,
          &reference
        )
        if let reference {
          carbonEscapeShortcuts.append(reference)
        }
      }
    } else if !enabled {
      for shortcut in carbonEscapeShortcuts {
        UnregisterEventHotKey(shortcut)
      }
      carbonEscapeShortcuts.removeAll()
    }
  }

  private func unregisterCarbonShortcut(_ shortcut: inout EventHotKeyRef?) {
    if let shortcut {
      UnregisterEventHotKey(shortcut)
    }
    shortcut = nil
  }

  /// Returns `true` when the custom trigger must be consumed. The reducer keeps consuming the
  /// trigger through its final key-up after a required modifier has already ended the session.
  private func handleCustomShortcutKeyEvent(type: CGEventType, event: CGEvent) -> Bool? {
    guard let descriptor = selectedShortcut.descriptor,
      let keyCode = descriptor.keyCode
    else {
      return nil
    }

    let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    guard eventKeyCode == keyCode else {
      return nil
    }

    switch type {
    case .keyDown:
      let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
      let effect = customShortcutState.keyDown(
        keyCode: eventKeyCode,
        modifiers: eventModifiers(event.flags),
        descriptor: descriptor,
        isAutorepeat: isAutorepeat
      )
      switch effect {
      case .beginAndConsume:
        onHold?(selectedShortcut, true)
        return true
      case .consume:
        return true
      case .passThrough:
        return false
      case .endAndConsume, .cancelAndConsume:
        return true
      }
    case .keyUp:
      switch customShortcutState.keyUp(keyCode: eventKeyCode) {
      case .endAndConsume:
        onHold?(selectedShortcut, false)
        return true
      case .consume:
        return true
      case .passThrough:
        return false
      case .beginAndConsume, .cancelAndConsume:
        return true
      }
    default:
      return nil
    }
  }

  private func updateCustomShortcutForModifierChange(event: CGEvent) {
    guard let descriptor = selectedShortcut.descriptor,
      descriptor.keyCode != nil
    else {
      return
    }

    let effect = customShortcutState.modifierStateChanged(
      modifiers: eventModifiers(event.flags),
      descriptor: descriptor
    )
    if effect == .endAndConsume {
      onHold?(selectedShortcut, false)
    }
  }

  private func eventModifiers(_ flags: CGEventFlags) -> HotkeyModifiers {
    var modifiers: HotkeyModifiers = []
    if flags.contains(.maskControl) {
      modifiers.insert(.control)
    }
    if flags.contains(.maskShift) {
      modifiers.insert(.shift)
    }
    let deviceRightOptionMask: UInt64 = 0x40
    let rightOptionIsDown = flags.rawValue & deviceRightOptionMask != 0
    if flags.contains(.maskAlternate), !rightOptionIsDown {
      modifiers.insert(.option)
    }
    if rightOptionIsDown {
      modifiers.insert(.rightOption)
    }
    if flags.contains(.maskCommand) {
      modifiers.insert(.command)
    }
    if flags.contains(.maskSecondaryFn) {
      modifiers.insert(.function)
    }
    return modifiers
  }

  private func isFunctionShortcut(_ shortcut: HoldShortcut) -> Bool {
    shortcut == .function
      || shortcut.descriptor == HotkeyDescriptor(keyCode: nil, modifiers: .function)
  }

  private func isRightOptionShortcut(_ shortcut: HoldShortcut) -> Bool {
    shortcut == .rightOption
      || shortcut.descriptor == HotkeyDescriptor(keyCode: nil, modifiers: .rightOption)
  }

  private func isSingleModifierShortcut(_ shortcut: HoldShortcut, modifier: HotkeyModifiers) -> Bool
  {
    shortcut.descriptor == HotkeyDescriptor(keyCode: nil, modifiers: modifier)
  }

  private func modifier(_ modifier: HotkeyModifiers, isDownIn flags: CGEventFlags) -> Bool {
    switch modifier {
    case .control:
      return flags.contains(.maskControl)
    case .shift:
      return flags.contains(.maskShift)
    case .option:
      return flags.contains(.maskAlternate)
    case .command:
      return flags.contains(.maskCommand)
    default:
      return false
    }
  }

  private func modifier(for keyCode: UInt16) -> HotkeyModifiers? {
    switch keyCode {
    case UInt16(kVK_Control):
      return .control
    case UInt16(kVK_Shift):
      return .shift
    case UInt16(kVK_Option):
      return .option
    case UInt16(kVK_Command):
      return .command
    default:
      return nil
    }
  }
}
