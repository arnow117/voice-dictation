import AVFoundation
import Foundation

protocol AudioEngineEventObservation: AnyObject {
  func cancel()
}

protocol AudioEngineEventObserving: AnyObject {
  func observe(
    engine: AVAudioEngine,
    onConfigurationChange: @escaping () -> Void
  ) -> AudioEngineEventObservation
}

/// AVAudioEngine reports graph/device reconfiguration independently of the app's periodic state
/// refresh. Every such event invalidates active capture: a replacement default microphone must not
/// continue an old session's audio.
final class SystemAudioEngineEventSource: AudioEngineEventObserving {
  private let notificationCenter: NotificationCenter

  init(notificationCenter: NotificationCenter = .default) {
    self.notificationCenter = notificationCenter
  }

  func observe(
    engine: AVAudioEngine,
    onConfigurationChange: @escaping () -> Void
  ) -> AudioEngineEventObservation {
    let audioDeviceChanged: (Notification) -> Void = { notification in
      guard let device = notification.object as? AVCaptureDevice,
        device.hasMediaType(.audio)
      else {
        return
      }
      onConfigurationChange()
    }
    let engineChange = notificationCenter.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { _ in
      onConfigurationChange()
    }
    let deviceDisconnected = notificationCenter.addObserver(
      forName: AVCaptureDevice.wasDisconnectedNotification,
      object: nil,
      queue: nil
    ) { notification in
      audioDeviceChanged(notification)
    }
    let deviceConnected = notificationCenter.addObserver(
      forName: AVCaptureDevice.wasConnectedNotification,
      object: nil,
      queue: nil
    ) { notification in
      audioDeviceChanged(notification)
    }
    return NotificationAudioEngineEventObservation(
      notificationCenter: notificationCenter,
      tokens: [engineChange, deviceDisconnected, deviceConnected]
    )
  }
}

private final class NotificationAudioEngineEventObservation: AudioEngineEventObservation {
  private let notificationCenter: NotificationCenter
  private var tokens: [NSObjectProtocol]

  init(notificationCenter: NotificationCenter, tokens: [NSObjectProtocol]) {
    self.notificationCenter = notificationCenter
    self.tokens = tokens
  }

  func cancel() {
    for token in tokens {
      notificationCenter.removeObserver(token)
    }
    tokens.removeAll()
  }

  deinit {
    cancel()
  }
}
