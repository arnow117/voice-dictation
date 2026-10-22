import Foundation

/// An injectable main-queue boundary for UI work that must be deferred until after a view render.
/// Invalidating the gate makes already queued actions no-ops, including actions retained by the
/// main run loop while a window closes or changes onboarding steps.
protocol DeferredActionScheduling: AnyObject {
  func enqueue(_ action: @escaping () -> Void)
}

final class MainQueueDeferredActionScheduler: DeferredActionScheduling {
  func enqueue(_ action: @escaping () -> Void) {
    DispatchQueue.main.async(execute: action)
  }
}

final class DeferredActionGate {
  private let scheduler: DeferredActionScheduling
  private var generation: UInt64 = 0

  init(scheduler: DeferredActionScheduling = MainQueueDeferredActionScheduler()) {
    self.scheduler = scheduler
  }

  func schedule(
    when isStillEligible: @escaping () -> Bool,
    action: @escaping () -> Void
  ) {
    generation &+= 1
    let actionGeneration = generation
    scheduler.enqueue { [weak self] in
      guard let self,
        self.generation == actionGeneration,
        isStillEligible()
      else {
        return
      }
      action()
    }
  }

  func invalidate() {
    generation &+= 1
  }
}
