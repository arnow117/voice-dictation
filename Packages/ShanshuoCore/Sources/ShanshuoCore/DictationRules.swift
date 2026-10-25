import Foundation

/// Pure rules for the hold-to-talk session. Platform code supplies live permission and focus facts;
/// this module never imports AppKit or performs I/O.
public enum DictationPhase: String, Equatable, Sendable {
  case idle
  case starting
  case listening
  case stopping
  case recognizing
  case formatting
  case inserting
  case cancelled
  case failed
}

public enum PermissionStatus: String, Equatable, Sendable {
  case authorized
  case denied
  case notDetermined
  case restricted

  public var isAuthorized: Bool {
    self == .authorized
  }
}

public enum StartRejection: String, Equatable, Sendable {
  case paused
  case secureField
  case busy
  case microphonePermission
  case microphoneUnavailable
  case modelUnavailable
  case indicatorUnavailable
}

public enum StartDecision: Equatable, Sendable {
  case allowed
  case rejected(StartRejection)

  public var message: String {
    switch self {
    case .allowed:
      return ""
    case .rejected(.paused):
      return "语音输入已暂停"
    case .rejected(.secureField):
      return "密码框中不支持语音输入"
    case .rejected(.busy):
      return "上一段仍在处理"
    case .rejected(.microphonePermission):
      return "缺少麦克风权限"
    case .rejected(.microphoneUnavailable):
      return "麦克风不可用"
    case .rejected(.modelUnavailable):
      return "语音模型需要修复"
    case .rejected(.indicatorUnavailable):
      return "录音提示无法显示，未开始录音"
    }
  }
}

public struct StartContext: Equatable, Sendable {
  public var isPaused: Bool
  public var isBusy: Bool
  public var microphonePermission: PermissionStatus
  public var microphoneAvailable: Bool
  public var modelReady: Bool
  public var indicatorAvailable: Bool
  public var secureInputActive: Bool

  public init(
    isPaused: Bool,
    isBusy: Bool,
    microphonePermission: PermissionStatus,
    microphoneAvailable: Bool,
    modelReady: Bool,
    indicatorAvailable: Bool,
    secureInputActive: Bool
  ) {
    self.isPaused = isPaused
    self.isBusy = isBusy
    self.microphonePermission = microphonePermission
    self.microphoneAvailable = microphoneAvailable
    self.modelReady = modelReady
    self.indicatorAvailable = indicatorAvailable
    self.secureInputActive = secureInputActive
  }
}

/// A privacy-preserving description of a focused target. `elementIdentifier` is deliberately
/// optional: an unknown element must not receive synthetic text input.
public struct TargetSnapshot: Equatable, Sendable {
  public var bundleIdentifier: String?
  public var processIdentifier: Int32?
  public var elementIdentifier: String?
  public var isEditable: Bool
  public var isSecure: Bool

  public init(
    bundleIdentifier: String?,
    processIdentifier: Int32?,
    elementIdentifier: String?,
    isEditable: Bool,
    isSecure: Bool
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.processIdentifier = processIdentifier
    self.elementIdentifier = elementIdentifier
    self.isEditable = isEditable
    self.isSecure = isSecure
  }

  public var hasKnownIdentity: Bool {
    processIdentifier != nil && elementIdentifier != nil
  }
}

public enum FocusMatch: Equatable, Sendable {
  case same
  case changed
  case unknown
}

public enum InsertionAction: Equatable, Sendable {
  case insert
  case copy
  case discard
}

public struct InsertionDecision: Equatable, Sendable {
  public let action: InsertionAction
  public let message: String

  public init(action: InsertionAction, message: String) {
    self.action = action
    self.message = message
  }
}

public struct InsertionContext: Equatable, Sendable {
  public var releasedTarget: TargetSnapshot
  public var currentTarget: TargetSnapshot
  public var focusMatch: FocusMatch
  public var accessibilityPermission: PermissionStatus
  public var secureInputActive: Bool

  public init(
    releasedTarget: TargetSnapshot,
    currentTarget: TargetSnapshot,
    focusMatch: FocusMatch,
    accessibilityPermission: PermissionStatus,
    secureInputActive: Bool
  ) {
    self.releasedTarget = releasedTarget
    self.currentTarget = currentTarget
    self.focusMatch = focusMatch
    self.accessibilityPermission = accessibilityPermission
    self.secureInputActive = secureInputActive
  }
}

public enum ReleaseDisposition: Equatable, Sendable {
  case discardMisfire
  case recognize
}

public enum DictationRules {
  public static let minimumHold = TimeInterval(0.3)
  public static let maximumRecording = TimeInterval(180)
  public static let countdownStartsAt = TimeInterval(165)
  public static let historyRetention = TimeInterval(7 * 24 * 60 * 60)

  public static func startDecision(_ context: StartContext) -> StartDecision {
    if context.isPaused {
      return .rejected(.paused)
    }
    if context.secureInputActive {
      return .rejected(.secureField)
    }
    if context.isBusy {
      return .rejected(.busy)
    }
    if !context.microphonePermission.isAuthorized {
      return .rejected(.microphonePermission)
    }
    if !context.microphoneAvailable {
      return .rejected(.microphoneUnavailable)
    }
    if !context.modelReady {
      return .rejected(.modelUnavailable)
    }
    if !context.indicatorAvailable {
      return .rejected(.indicatorUnavailable)
    }
    return .allowed
  }

  public static func releaseDisposition(heldFor duration: TimeInterval) -> ReleaseDisposition {
    duration < minimumHold ? .discardMisfire : .recognize
  }

  /// `nil` until the final 15 seconds; then the number of whole seconds remaining.
  public static func countdownSeconds(elapsed: TimeInterval) -> Int? {
    guard elapsed >= countdownStartsAt else {
      return nil
    }
    let remaining = max(0, maximumRecording - elapsed)
    return Int(ceil(remaining))
  }

  public static func shouldAutoStop(elapsed: TimeInterval) -> Bool {
    elapsed >= maximumRecording
  }

  /// The event tap must decide this before calling cancellation, because cancellation disables the
  /// interception flag as part of session cleanup.
  public static func shouldConsumeEscape(cancellationInterceptionEnabled: Bool) -> Bool {
    cancellationInterceptionEnabled
  }

  public static func insertionDecision(_ context: InsertionContext) -> InsertionDecision {
    if context.secureInputActive || context.releasedTarget.isSecure
      || context.currentTarget.isSecure
    {
      return InsertionDecision(
        action: .discard,
        message: "密码框中不支持语音输入，本次内容已丢弃"
      )
    }

    guard context.focusMatch == .same, context.releasedTarget.hasKnownIdentity else {
      return InsertionDecision(action: .copy, message: "焦点已变化，已复制到剪贴板")
    }

    guard context.currentTarget.isEditable else {
      return InsertionDecision(action: .copy, message: "未找到输入框，已复制到剪贴板")
    }

    guard context.accessibilityPermission.isAuthorized else {
      return InsertionDecision(action: .copy, message: "仅复制模式：已复制，按 ⌘V 粘贴")
    }

    return InsertionDecision(action: .insert, message: "已插入")
  }

  public static func retainHistory<Record>(
    _ records: [Record],
    now: Date,
    createdAt: (Record) -> Date
  ) -> [Record] {
    records.filter { now.timeIntervalSince(createdAt($0)) <= historyRetention }
  }
}

/// Per-session generation token. The coordinator increments it whenever it invalidates a session;
/// asynchronous capture and ASR completions must compare their captured token before changing UI.
public struct SessionGeneration: Equatable, Hashable, Sendable {
  public private(set) var value: UInt64

  public init(value: UInt64 = 0) {
    self.value = value
  }

  @discardableResult
  public mutating func invalidate() -> SessionGeneration {
    value &+= 1
    return self
  }
}
