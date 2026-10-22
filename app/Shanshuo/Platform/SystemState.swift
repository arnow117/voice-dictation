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

enum HoldShortcut: Equatable {
  case function
  case rightOption
  case copyOnlyControlShiftSpace
}

protocol HotkeyMonitoring: AnyObject {
  var isShortcutAvailable: Bool { get }
  var onHold: ((HoldShortcut, Bool) -> Void)? { get set }
  var onCancel: (() -> Void)? { get set }
  var onOtherKey: (() -> Void)? { get set }
  var selectedShortcut: HoldShortcut { get set }
  func refresh(accessibilityAuthorized: Bool)
  func setCancellationInterception(_ enabled: Bool)
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
  private var accessibilityAuthorized = false
  private var cancellationInterception = false
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

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged {
      if keyCode == Int64(kVK_Function) {
        updateFunction(isDown: event.flags.contains(.maskSecondaryFn))
      } else if keyCode == Int64(kVK_RightOption) {
        let deviceRightOptionMask: UInt64 = 0x40
        updateRightOption(isDown: event.flags.rawValue & deviceRightOptionMask != 0)
      }
      return Unmanaged.passUnretained(event)
    }

    if keyCode == Int64(kVK_Escape), type == .keyDown {
      let shouldConsume = Self.handleEscape(
        cancellationInterceptionEnabled: cancellationInterception,
        onCancel: onCancel
      )
      return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    if type == .keyDown,
      event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
      functionDown || rightOptionDown
    {
      onOtherKey?()
    }
    return Unmanaged.passUnretained(event)
  }

  private func updateFunction(isDown: Bool) {
    guard functionDown != isDown else {
      return
    }
    functionDown = isDown
    if selectedShortcut == .function {
      onHold?(.function, isDown)
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

  private func updateRightOption(isDown: Bool) {
    guard rightOptionDown != isDown else {
      return
    }
    rightOptionDown = isDown
    if selectedShortcut == .rightOption {
      onHold?(.rightOption, isDown)
    }
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
    let needsCopyOnlyShortcut =
      !accessibilityAuthorized || selectedShortcut == .copyOnlyControlShiftSpace
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
    if identifier.id == 1,
      !accessibilityAuthorized || selectedShortcut == .copyOnlyControlShiftSpace
    {
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
}
