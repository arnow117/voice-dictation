import AudioToolbox
import Foundation

private enum FakeDeviceError: Error {
  case unavailable
}

private final class FakeInputDeviceConfigurator: InputDeviceConfiguring {
  var devices: [InputDevice]
  var deviceIDsByUID: [String: AudioDeviceID]
  var systemDefaultDeviceID: AudioDeviceID?
  private var currentDeviceID: AudioDeviceID?
  private(set) var appliedDeviceIDs: [AudioDeviceID] = []

  init(
    devices: [InputDevice],
    deviceIDsByUID: [String: AudioDeviceID],
    systemDefaultDeviceID: AudioDeviceID?
  ) {
    self.devices = devices
    self.deviceIDsByUID = deviceIDsByUID
    self.systemDefaultDeviceID = systemDefaultDeviceID
  }

  func availableDevices() -> [InputDevice] {
    devices
  }

  func deviceID(for uid: String) -> AudioDeviceID? {
    deviceIDsByUID[uid]
  }

  func deviceUID(for deviceID: AudioDeviceID) -> String? {
    deviceIDsByUID.first { $0.value == deviceID }?.key
  }

  func defaultInputDeviceID() -> AudioDeviceID? {
    systemDefaultDeviceID
  }

  func currentInputDeviceID() -> AudioDeviceID? {
    currentDeviceID
  }

  func apply(deviceID: AudioDeviceID) throws {
    guard devices.contains(where: { deviceIDsByUID[$0.uid] == deviceID }) else {
      throw FakeDeviceError.unavailable
    }
    appliedDeviceIDs.append(deviceID)
    currentDeviceID = deviceID
  }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
enum InputDeviceSelectionHarness {
  static func main() {
    let builtIn = InputDevice(uid: "built-in", name: "Mac microphone")
    let usb = InputDevice(uid: "usb", name: "USB microphone")

    check(
      !InputDeviceVisibility.shouldOffer(isPrivateAggregate: true),
      "a process-private CoreAudio aggregate is not offered or persisted as a user device"
    )
    check(
      InputDeviceVisibility.shouldOffer(isPrivateAggregate: false),
      "a user-created aggregate or virtual device remains selectable"
    )

    check(
      InputDeviceSelection.resolve(preferredUID: nil, devices: [builtIn, usb]) == .systemDefault,
      "following default leaves device choice to the next engine start"
    )
    check(
      InputDeviceSelection.resolve(preferredUID: "usb", devices: [builtIn, usb]) == .selected(usb),
      "a stable UID resolves the selected input for a new capture"
    )
    check(
      InputDeviceSelection.resolve(preferredUID: "usb", devices: [builtIn]) == .unavailable("usb"),
      "a missing selected input rejects the new capture rather than silently substituting a device"
    )

    let activeSessionPlan = InputDeviceSessionPlan(preferredUID: "built-in")
    let changedPreference = "usb"
    let activeSessionDevice = activeSessionPlan.resolve(devices: [builtIn, usb])
    let nextSessionDevice = InputDeviceSessionPlan(preferredUID: changedPreference).resolve(
      devices: [builtIn, usb]
    )
    check(
      activeSessionDevice == .selected(builtIn) && nextSessionDevice == .selected(usb),
      "a changed preference cannot alter an already-created operation plan"
    )

    let configurator = FakeInputDeviceConfigurator(
      devices: [builtIn, usb],
      deviceIDsByUID: ["built-in": 10, "usb": 20],
      systemDefaultDeviceID: 20
    )
    check(
      InputDeviceSessionConfigurator.configure(
        plan: InputDeviceSessionPlan(preferredUID: "built-in"),
        using: configurator
      ),
      "a selected device applies to the app input unit for its operation"
    )
    check(
      configurator.appliedDeviceIDs == [10],
      "the first operation applies the selected device A"
    )

    check(
      InputDeviceSessionConfigurator.configure(
        plan: InputDeviceSessionPlan(preferredUID: nil),
        using: configurator
      ),
      "following the system default applies the current default instead of retaining A"
    )
    check(
      configurator.appliedDeviceIDs == [10, 20],
      "selected A followed by default B reconfigures the reused app input unit to B"
    )

    configurator.systemDefaultDeviceID = 10
    check(
      InputDeviceSessionConfigurator.configure(
        plan: InputDeviceSessionPlan(preferredUID: nil),
        using: configurator
      ),
      "the next default-following operation resolves the system default again"
    )
    check(
      configurator.appliedDeviceIDs == [10, 20, 10],
      "a changed OS default affects the next operation without changing the active-session plan"
    )
    print("input device selection harness passed")
  }
}
