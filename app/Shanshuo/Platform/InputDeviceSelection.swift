import AudioToolbox
import Foundation

struct InputDevice: Equatable {
  let uid: String
  let name: String
}

enum InputDeviceResolution: Equatable {
  case systemDefault
  case selected(InputDevice)
  case unavailable(String)
}

/// An immutable device choice captured when a capture operation is created. The engine resolves
/// this plan later on its own queue, so a settings change while start is pending only affects the
/// next operation.
struct InputDeviceSessionPlan: Equatable {
  let preferredUID: String?

  func resolve(devices: [InputDevice]) -> InputDeviceResolution {
    guard let preferredUID else {
      return .systemDefault
    }
    guard let selected = devices.first(where: { $0.uid == preferredUID }) else {
      return .unavailable(preferredUID)
    }
    return .selected(selected)
  }
}

/// Resolves a saved preference only when a new audio operation begins. An active capture keeps the
/// device it started with; the caller must explicitly handle an engine interruption if that active
/// device disappears.
enum InputDeviceSelection {
  static func resolve(preferredUID: String?, devices: [InputDevice]) -> InputDeviceResolution {
    InputDeviceSessionPlan(preferredUID: preferredUID).resolve(devices: devices)
  }
}

/// This adapter only selects an input for the app's own audio unit. It never changes the macOS
/// default input device. A capture operation calls it once from the engine queue using the immutable
/// preference snapshot it received when the operation was created.
protocol InputDeviceConfiguring: AnyObject {
  func availableDevices() -> [InputDevice]
  func deviceID(for uid: String) -> AudioDeviceID?
  func defaultInputDeviceID() -> AudioDeviceID?
  func apply(deviceID: AudioDeviceID) throws
}

enum InputDeviceSessionConfigurator {
  /// Explicitly applies the current system default as well as a saved explicit choice. Reusing an
  /// AVAudioEngine after a selected device does not reset its input unit merely by stopping it.
  static func configure(
    plan: InputDeviceSessionPlan,
    using adapter: InputDeviceConfiguring
  ) -> Bool {
    switch plan.resolve(devices: adapter.availableDevices()) {
    case .systemDefault:
      guard let defaultDeviceID = adapter.defaultInputDeviceID() else {
        return false
      }
      return apply(defaultDeviceID, using: adapter)
    case .unavailable:
      return false
    case .selected(let device):
      guard let deviceID = adapter.deviceID(for: device.uid) else {
        return false
      }
      return apply(deviceID, using: adapter)
    }
  }

  private static func apply(_ deviceID: AudioDeviceID, using adapter: InputDeviceConfiguring)
    -> Bool
  {
    do {
      try adapter.apply(deviceID: deviceID)
      return true
    } catch {
      return false
    }
  }
}
