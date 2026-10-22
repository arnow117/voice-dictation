import Foundation

private final class TestClock {
  var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
}

private final class ManualDeferredActionScheduler: DeferredActionScheduling {
  private var actions: [() -> Void] = []

  func enqueue(_ action: @escaping () -> Void) {
    actions.append(action)
  }

  func runQueuedActions() {
    let queuedActions = actions
    actions.removeAll()
    for action in queuedActions {
      action()
    }
  }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
enum OnboardingStateHarness {
  static func main() {
    let suite = "shanshuo-onboarding-state-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let progressStore = OnboardingProgressStore(defaults: defaults)
    var progress = progressStore.load()
    check(progress.firstIncomplete() == .welcome, "fresh onboarding starts with welcome")
    progress.visited.insert(.microphone)
    progress.completed.insert(.welcome)
    progress.completed.insert(.microphone)
    progress.skipped.insert(.accessibility)
    progressStore.save(progress)
    let resumed = OnboardingProgressStore(defaults: defaults).load()
    check(resumed.hasVisited(.microphone), "visited steps persist for back navigation")
    check(resumed.completed.contains(.microphone), "completed markers persist for resume")
    check(resumed.skipped.contains(.accessibility), "skipped markers persist without audio or text")
    check(
      resumed.firstIncomplete() == .model, "restart continues at first incomplete effective step")

    let clock = TestClock()
    let pause = PauseController(defaults: defaults, now: { clock.date })
    let oneHour = pause.pauseForOneHour()
    check(
      oneHour.mode == .untilDeadline && oneHour.deadline == clock.date.addingTimeInterval(3_600),
      "pause stores an absolute deadline")
    clock.date = clock.date.addingTimeInterval(1_800)
    check(
      PauseController(defaults: defaults, now: { clock.date }).snapshot().isPaused,
      "restart does not shorten an active pause")
    clock.date = clock.date.addingTimeInterval(1_801)
    let restartedPause = PauseController(defaults: defaults, now: { clock.date })
    check(
      !restartedPause.snapshot().isPaused, "expired pause does not extend after restart or wake")
    check(restartedPause.pauseUntilManualResume().isPaused, "manual pause persists")
    check(
      !PauseController(defaults: defaults, now: { clock.date }).resume().isPaused,
      "manual resume clears persisted pause")

    let activePauseMenu = PauseMenuPresentation(
      snapshot: PauseSnapshot(mode: .active, deadline: nil)
    )
    check(
      activePauseMenu.showPauseForOneHour
        && activePauseMenu.showPauseUntilManualResume
        && !activePauseMenu.showResume,
      "active menu exposes both one-hour and manual pause commands"
    )
    let manualPauseMenu = PauseMenuPresentation(
      snapshot: PauseSnapshot(mode: .untilManualResume, deadline: nil)
    )
    check(
      !manualPauseMenu.showPauseForOneHour
        && !manualPauseMenu.showPauseUntilManualResume
        && manualPauseMenu.showResume,
      "manual pause menu exposes the resume command"
    )

    let scheduler = ManualDeferredActionScheduler()
    let deferredStartGate = DeferredActionGate(scheduler: scheduler)
    var viewIsStillEligible = true
    var deferredCaptureStarts = 0
    deferredStartGate.schedule(
      when: { viewIsStillEligible },
      action: { deferredCaptureStarts += 1 }
    )
    // Closing the window invalidates the queued main-loop start before it can capture audio.
    viewIsStillEligible = false
    deferredStartGate.invalidate()
    scheduler.runQueuedActions()
    check(
      deferredCaptureStarts == 0,
      "closing the microphone-test window prevents a queued capture start"
    )

    viewIsStillEligible = true
    deferredStartGate.schedule(
      when: { viewIsStillEligible },
      action: { deferredCaptureStarts += 1 }
    )
    // Leaving the microphone-test step follows the same invalidation path.
    viewIsStillEligible = false
    deferredStartGate.invalidate()
    scheduler.runQueuedActions()
    check(
      deferredCaptureStarts == 0,
      "leaving the microphone-test step prevents a queued capture start"
    )

    viewIsStillEligible = true
    deferredStartGate.schedule(
      when: { viewIsStillEligible },
      action: { deferredCaptureStarts += 1 }
    )
    scheduler.runQueuedActions()
    check(
      deferredCaptureStarts == 1,
      "an eligible visible microphone-test step starts capture once"
    )

    var practice = PracticeSessionState()
    let copiedAttempt = UUID()
    practice.beginAttempt(copiedAttempt, initialText: "")
    check(
      !practice.verifyPastedReadback("prefilled text"),
      "prefilled practice text has no matching copied-result evidence"
    )
    practice.expectCopiedText("copied result", attemptID: copiedAttempt)
    check(
      !practice.verifyPastedReadback("copied result"),
      "typing a matching string without a paste request cannot complete practice"
    )
    practice.notePasteRequest()
    check(
      practice.verifyPastedReadback("copied result"),
      "a real paste request and exact copied result can complete practice"
    )
    practice.clear()
    check(
      !practice.succeeded && practice.expectedPasteText == nil && !practice.pasteWasRequested,
      "closing or leaving practice clears its in-memory text evidence"
    )
    let unverifiedAttempt = UUID()
    practice.beginAttempt(unverifiedAttempt, initialText: "direct result")
    check(
      !practice.verifyDirectReadback(
        "direct result",
        expectedText: "direct result",
        attemptID: unverifiedAttempt,
        isVerifiedDirectInsertion: false
      ),
      "matching prefilled text cannot prove an unverified direct paste"
    )
    practice.notePasteRequest()
    check(
      !practice.verifyDirectReadback(
        "direct result",
        expectedText: "direct result",
        attemptID: unverifiedAttempt,
        isVerifiedDirectInsertion: false
      ),
      "an old prefill equal to the result cannot pass after an unrelated paste event"
    )
    practice.clear()
    let deliveredAttempt = UUID()
    practice.beginAttempt(deliveredAttempt, initialText: "")
    practice.notePasteRequest()
    check(
      practice.verifyDirectReadback(
        "direct result",
        expectedText: "direct result",
        attemptID: deliveredAttempt,
        isVerifiedDirectInsertion: false
      ),
      "a current-attempt paste and changed exact readback prove an unverified direct delivery"
    )
    practice.clear()
    let verifiedAttempt = UUID()
    practice.beginAttempt(verifiedAttempt, initialText: "verified result")
    check(
      practice.verifyDirectReadback(
        "verified result",
        expectedText: "verified result",
        attemptID: verifiedAttempt,
        isVerifiedDirectInsertion: true
      ),
      "a verified direct receipt and exact native control readback complete practice"
    )

    print("onboarding state harness passed")
  }
}
