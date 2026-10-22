import Foundation

enum PauseMode: String, Equatable {
  case active
  case untilManualResume
  case untilDeadline
}

struct PauseSnapshot: Equatable {
  let mode: PauseMode
  let deadline: Date?

  var isPaused: Bool {
    mode != .active
  }
}

/// Persists an absolute pause deadline, rather than a duration. Reopening the app or waking the
/// Mac therefore cannot extend a one-hour pause.
final class PauseController {
  private enum Key {
    static let mode = "pause.mode"
    static let deadline = "pause.deadline"
  }

  private let defaults: UserDefaults
  private let now: () -> Date

  init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.now = now
  }

  func snapshot() -> PauseSnapshot {
    refreshExpiredPause()
    guard let mode = PauseMode(rawValue: defaults.string(forKey: Key.mode) ?? "") else {
      return PauseSnapshot(mode: .active, deadline: nil)
    }
    let deadline = defaults.object(forKey: Key.deadline) as? Date
    return PauseSnapshot(mode: mode, deadline: deadline)
  }

  func pauseForOneHour() -> PauseSnapshot {
    let deadline = now().addingTimeInterval(60 * 60)
    defaults.set(PauseMode.untilDeadline.rawValue, forKey: Key.mode)
    defaults.set(deadline, forKey: Key.deadline)
    return PauseSnapshot(mode: .untilDeadline, deadline: deadline)
  }

  func pauseUntilManualResume() -> PauseSnapshot {
    defaults.set(PauseMode.untilManualResume.rawValue, forKey: Key.mode)
    defaults.removeObject(forKey: Key.deadline)
    return PauseSnapshot(mode: .untilManualResume, deadline: nil)
  }

  func resume() -> PauseSnapshot {
    defaults.removeObject(forKey: Key.mode)
    defaults.removeObject(forKey: Key.deadline)
    return PauseSnapshot(mode: .active, deadline: nil)
  }

  @discardableResult
  func refreshExpiredPause() -> Bool {
    guard PauseMode(rawValue: defaults.string(forKey: Key.mode) ?? "") == .untilDeadline,
      let deadline = defaults.object(forKey: Key.deadline) as? Date,
      deadline <= now()
    else {
      return false
    }
    _ = resume()
    return true
  }
}
