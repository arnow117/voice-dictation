import AudioToolbox
import Foundation

struct InputDevice: Equatable {
  let uid: String
  let name: String
}

/// Only process-private CoreAudio aggregates are hidden from settings. This keeps user-created
/// aggregates and virtual devices available while avoiding persistence of an app's temporary
/// default aggregate UID.
enum InputDeviceVisibility {
  static func shouldOffer(isPrivateAggregate: Bool) -> Bool {
    !isPrivateAggregate
  }
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

/// The concrete input route selected for one preparation. A follow-default plan deliberately
/// records the device that was the system default at this point in time; the next operation
/// resolves the plan again instead of reusing this snapshot blindly.
struct ResolvedInputDevicePlan: Equatable {
  let plan: InputDeviceSessionPlan
  let deviceID: AudioDeviceID
  let deviceUID: String?
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
  func deviceUID(for deviceID: AudioDeviceID) -> String?
  func defaultInputDeviceID() -> AudioDeviceID?
  func currentInputDeviceID() -> AudioDeviceID?
  func apply(deviceID: AudioDeviceID) throws
}

enum InputDeviceSessionConfigurator {
  /// Explicitly applies the current system default as well as a saved explicit choice. Reusing an
  /// AVAudioEngine after a selected device does not reset its input unit merely by stopping it.
  static func configure(
    plan: InputDeviceSessionPlan,
    using adapter: InputDeviceConfiguring
  ) -> Bool {
    guard let resolved = resolve(plan: plan, using: adapter) else {
      return false
    }
    return apply(resolved.deviceID, using: adapter)
  }

  /// Resolves a saved preference to a concrete route exactly once for a preparation ticket.
  /// Callers must retain this value while they wait for AVAudioEngine's configuration event.
  static func resolve(
    plan: InputDeviceSessionPlan,
    using adapter: InputDeviceConfiguring
  ) -> ResolvedInputDevicePlan? {
    guard let deviceID = resolvedDeviceID(for: plan, using: adapter) else {
      return nil
    }
    return ResolvedInputDevicePlan(
      plan: plan,
      deviceID: deviceID,
      deviceUID: adapter.deviceUID(for: deviceID)
    )
  }

  /// Resolve the exact device the app input unit must use for one immutable session plan. The
  /// caller may compare this value with the audio unit after a configuration notification settles.
  static func resolvedDeviceID(
    for plan: InputDeviceSessionPlan,
    using adapter: InputDeviceConfiguring
  ) -> AudioDeviceID? {
    switch plan.resolve(devices: adapter.availableDevices()) {
    case .systemDefault:
      return adapter.defaultInputDeviceID()
    case .unavailable:
      return nil
    case .selected(let device):
      return adapter.deviceID(for: device.uid)
    }
  }

  static func apply(_ deviceID: AudioDeviceID, using adapter: InputDeviceConfiguring)
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
