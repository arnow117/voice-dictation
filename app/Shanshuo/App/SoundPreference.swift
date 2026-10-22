import Foundation

protocol SoundPreferenceControlling: AnyObject {
  var isEnabled: Bool { get set }
}

final class NoopSoundPreferenceController: SoundPreferenceControlling {
  var isEnabled = true
}
