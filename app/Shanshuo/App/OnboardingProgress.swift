import Foundation

enum OnboardingStep: String, CaseIterable, Codable {
  case welcome
  case microphone
  case accessibility
  case model
  case microphoneTest
  case shortcut
  case practice
  case complete

  var title: String {
    switch self {
    case .welcome:
      return "欢迎"
    case .microphone:
      return "麦克风"
    case .accessibility:
      return "辅助功能"
    case .model:
      return "语音模型"
    case .microphoneTest:
      return "测试麦克风"
    case .shortcut:
      return "快捷键"
    case .practice:
      return "练习"
    case .complete:
      return "完成"
    }
  }
}

struct OnboardingProgress: Codable, Equatable {
  var visited: Set<OnboardingStep> = [.welcome]
  var completed: Set<OnboardingStep> = []
  var skipped: Set<OnboardingStep> = []

  func hasVisited(_ step: OnboardingStep) -> Bool {
    visited.contains(step)
  }

  func firstIncomplete() -> OnboardingStep {
    OnboardingStep.allCases.first { step in
      step != .complete && !completed.contains(step) && !skipped.contains(step)
    } ?? .complete
  }
}

/// Stores only navigation markers. Practice text, audio levels, and outcomes are intentionally
/// kept out of this value and never enter UserDefaults.
final class OnboardingProgressStore {
  private let defaults: UserDefaults
  private let key = "onboarding.progress"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> OnboardingProgress {
    guard let data = defaults.data(forKey: key),
      let progress = try? JSONDecoder().decode(OnboardingProgress.self, from: data)
    else {
      return OnboardingProgress()
    }
    return progress
  }

  func save(_ progress: OnboardingProgress) {
    guard let data = try? JSONEncoder().encode(progress) else {
      return
    }
    defaults.set(data, forKey: key)
  }
}
