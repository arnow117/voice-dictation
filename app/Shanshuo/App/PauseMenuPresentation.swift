import Foundation

/// Keeps the menu's pause choices in sync with the persisted pause state. The AppDelegate maps
/// these explicit commands to AppModel methods; the menu never infers a manual pause from a title.
struct PauseMenuPresentation: Equatable {
  let showPauseForOneHour: Bool
  let showPauseUntilManualResume: Bool
  let showResume: Bool

  init(snapshot: PauseSnapshot) {
    showPauseForOneHour = !snapshot.isPaused
    showPauseUntilManualResume = !snapshot.isPaused
    showResume = snapshot.isPaused
  }
}
