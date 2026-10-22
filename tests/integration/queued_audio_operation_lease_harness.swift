import AVFoundation
import AudioToolbox
import Foundation
import ShanshuoCore

private final class NoopAudioEngineEventObservation: AudioEngineEventObservation {
  func cancel() {}
}

private final class NoopAudioEngineEventSource: AudioEngineEventObserving {
  func observe(
    engine: AVAudioEngine,
    onConfigurationChange: @escaping () -> Void
  ) -> AudioEngineEventObservation {
    NoopAudioEngineEventObservation()
  }
}

private final class ControlledAudioEngineEventSource: AudioEngineEventObserving {
  private var handlers: [UUID: () -> Void] = [:]
  private var observationOrder: [UUID] = []
  private(set) var emittedEventCount = 0

  func observe(
    engine: AVAudioEngine,
    onConfigurationChange: @escaping () -> Void
  ) -> AudioEngineEventObservation {
    let identifier = UUID()
    handlers[identifier] = onConfigurationChange
    observationOrder.append(identifier)
    return ControlledAudioEngineEventObservation { [weak self] in
      self?.handlers[identifier] = nil
    }
  }

  func emitConfigurationChange() {
    emittedEventCount += 1
    guard let latestIdentifier = observationOrder.last else {
      return
    }
    handlers[latestIdentifier]?()
  }

  func emitConfigurationChange(observationAt index: Int) {
    emittedEventCount += 1
    guard observationOrder.indices.contains(index) else {
      return
    }
    let identifier = observationOrder[index]
    handlers[identifier]?()
  }
}

private final class ControlledAudioEngineEventObservation: AudioEngineEventObservation {
  private var onCancel: (() -> Void)?

  init(onCancel: @escaping () -> Void) {
    self.onCancel = onCancel
  }

  func cancel() {
    onCancel?()
    onCancel = nil
  }

  deinit {
    cancel()
  }
}

private final class UnavailableInputDeviceConfigurator: InputDeviceConfiguring {
  private(set) var defaultLookupCount = 0
  private(set) var applyCount = 0

  func availableDevices() -> [InputDevice] {
    []
  }

  func deviceID(for uid: String) -> AudioDeviceID? {
    nil
  }

  func deviceUID(for deviceID: AudioDeviceID) -> String? {
    nil
  }

  func defaultInputDeviceID() -> AudioDeviceID? {
    defaultLookupCount += 1
    return nil
  }

  func currentInputDeviceID() -> AudioDeviceID? {
    nil
  }

  func apply(deviceID: AudioDeviceID) throws {
    applyCount += 1
  }
}

private final class DelayedSetupInputDeviceConfigurator: InputDeviceConfiguring {
  private let eventSource: ControlledAudioEngineEventSource
  private let device = InputDevice(uid: "test-input", name: "Test input")
  private(set) var currentDeviceID: AudioDeviceID?

  init(eventSource: ControlledAudioEngineEventSource) {
    self.eventSource = eventSource
  }

  func availableDevices() -> [InputDevice] {
    [device]
  }

  func deviceID(for uid: String) -> AudioDeviceID? {
    uid == device.uid ? 10 : nil
  }

  func deviceUID(for deviceID: AudioDeviceID) -> String? {
    deviceID == 10 ? device.uid : nil
  }

  func defaultInputDeviceID() -> AudioDeviceID? {
    10
  }

  func currentInputDeviceID() -> AudioDeviceID? {
    currentDeviceID
  }

  func replaceCurrentDeviceID(_ deviceID: AudioDeviceID?) {
    currentDeviceID = deviceID
  }

  func apply(deviceID: AudioDeviceID) throws {
    currentDeviceID = deviceID
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(120)) { [eventSource] in
      eventSource.emitConfigurationChange()
    }
  }
}

private final class RouteChangingInputDeviceConfigurator: InputDeviceConfiguring {
  private let eventSource: ControlledAudioEngineEventSource
  private let configurationEventDelay: DispatchTimeInterval
  private let firstDevice = InputDevice(uid: "first", name: "First input")
  private let secondDevice = InputDevice(uid: "second", name: "Second input")
  var defaultDeviceID: AudioDeviceID = 10
  private(set) var currentDeviceID: AudioDeviceID?
  private(set) var appliedDeviceIDs: [AudioDeviceID] = []

  init(
    eventSource: ControlledAudioEngineEventSource,
    configurationEventDelay: DispatchTimeInterval = .milliseconds(120),
    currentDeviceID: AudioDeviceID? = nil
  ) {
    self.eventSource = eventSource
    self.configurationEventDelay = configurationEventDelay
    self.currentDeviceID = currentDeviceID
  }

  func availableDevices() -> [InputDevice] {
    [firstDevice, secondDevice]
  }

  func deviceID(for uid: String) -> AudioDeviceID? {
    switch uid {
    case firstDevice.uid:
      return 10
    case secondDevice.uid:
      return 20
    default:
      return nil
    }
  }

  func deviceUID(for deviceID: AudioDeviceID) -> String? {
    switch deviceID {
    case 10:
      return firstDevice.uid
    case 20:
      return secondDevice.uid
    default:
      return nil
    }
  }

  func defaultInputDeviceID() -> AudioDeviceID? {
    defaultDeviceID
  }

  func currentInputDeviceID() -> AudioDeviceID? {
    currentDeviceID
  }

  func replaceCurrentDeviceID(_ deviceID: AudioDeviceID?) {
    currentDeviceID = deviceID
  }

  func apply(deviceID: AudioDeviceID) throws {
    currentDeviceID = deviceID
    appliedDeviceIDs.append(deviceID)
    DispatchQueue.global().asyncAfter(deadline: .now() + configurationEventDelay) { [eventSource] in
      eventSource.emitConfigurationChange()
    }
  }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func waitForMainQueue(
  _ condition: @escaping () -> Bool,
  timeout: TimeInterval = 1
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition(), Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return condition()
}

@main
enum QueuedAudioOperationLeaseHarness {
  static func main() {
    testPreparationGeneration()
    testDelayedPreparationConfigurationChange()
    testCancelledPreparationDrainsBeforeNextRoute()
    testUnconfirmedPreparationRejectsPendingRequest()
    testFollowDefaultRevalidatesPreparedRoute()
    testQueuedPreparationKeepsResolvedRoute()
    testTimedOutEngineIgnoresLateRouteEvent()
    testAvailabilityRequiresCompletedPreparation()
    testQueuedOperationOwnership()
    print("queued audio operation lease harness passed")
  }

  private static func testPreparationGeneration() {
    let plan = InputDeviceSessionPlan(preferredUID: nil)
    var preparation = InputPreparation(
      generation: 1,
      revision: 0,
      plan: plan,
      operationIdentifier: nil,
      targetDeviceID: 10,
      targetDeviceUID: "first",
      engineInstanceEpoch: 1,
      engineEpoch: 4,
      requiresConfigurationConfirmation: true,
      observedConfigurationConfirmation: false,
      completion: nil
    )
    let settleScheduledBeforeNotification = preparation

    preparation.recordConfigurationChange(engineEpoch: 5)
    check(
      settleScheduledBeforeNotification != preparation,
      "a delayed configuration notification invalidates the settle work scheduled by start"
    )
    check(
      preparation.plan == plan && preparation.generation == 1 && preparation.targetDeviceID == 10,
      "the delayed setup notification preserves the immutable input plan, target device, and generation"
    )
    check(
      preparation.engineEpoch == 5 && preparation.observedConfigurationConfirmation,
      "a preparation only accepts graph completion after its configuration epoch advances"
    )
  }

  private static func testQueuedOperationOwnership() {
    let engineQueue = DispatchQueue(label: "shanshuo.actual-memory-audio-capture-test")
    let configurator = UnavailableInputDeviceConfigurator()
    let capture = MemoryAudioCapture(
      engineEvents: NoopAudioEngineEventSource(),
      inputDeviceConfigurator: configurator,
      engineQueue: engineQueue,
      availabilityProvider: { false },
      inputFormatProvider: { nil }
    )

    engineQueue.suspend()

    var startError: Error?
    var didReceiveStart = false
    var didReceiveStop = false
    weak var releasedCallerOperation: AnyObject?

    var operation: AudioCaptureOperation? = capture.start(
      onLevel: { _ in
        fputs("FAIL: unavailable input must not begin microphone capture\n", stderr)
        exit(1)
      },
      completion: { _, result in
        if case .failure(let error) = result {
          startError = error
        }
        didReceiveStart = true
      }
    )
    releasedCallerOperation = operation
    capture.stop(operation!) { audio in
      check(audio.samples.isEmpty, "unavailable start stop callback discards audio")
      didReceiveStop = true
    }
    operation = nil

    check(
      releasedCallerOperation != nil,
      "actual MemoryAudioCapture retains queued start and stop work after caller releases operation"
    )

    engineQueue.resume()

    check(
      waitForMainQueue({ didReceiveStart && didReceiveStop }),
      "actual queued MemoryAudioCapture delivers both start and stop callbacks"
    )
    check(startError is AudioCaptureError, "unavailable input reaches the start callback")
    check(
      configurator.defaultLookupCount == 1 && configurator.applyCount == 0,
      "unavailable adapter prevents engine input setup and microphone capture"
    )
    check(
      waitForMainQueue({ releasedCallerOperation == nil }),
      "operation is released after real queued cleanup finishes"
    )

  }

  private static func testCancelledPreparationDrainsBeforeNextRoute() {
    let engineQueue = DispatchQueue(label: "shanshuo.preparation-generation-test")
    let eventSource = ControlledAudioEngineEventSource()
    let configurator = RouteChangingInputDeviceConfigurator(eventSource: eventSource)
    let capture = MemoryAudioCapture(
      engineEvents: eventSource,
      inputDeviceConfigurator: configurator,
      engineQueue: engineQueue,
      availabilityProvider: { false },
      inputFormatProvider: { nil },
      configurationConfirmationTimeout: .milliseconds(500),
      prepareEngine: { _ in }
    )

    var firstStartCallback = false
    let firstOperation = capture.start(
      onLevel: { _ in
        fputs("FAIL: preparation must not capture before its route is confirmed\n", stderr)
        exit(1)
      },
      completion: { _, _ in firstStartCallback = true }
    )
    runMainLoop(for: 0.02)
    firstOperation.cancel()

    configurator.defaultDeviceID = 20
    var secondStartCallback = false
    var secondStartError: Error?
    _ = capture.start(
      onLevel: { _ in
        fputs("FAIL: a replacement preparation must not capture before confirmation\n", stderr)
        exit(1)
      },
      completion: { _, result in
        secondStartCallback = true
        if case .failure(let error) = result {
          secondStartError = error
        }
      }
    )

    runMainLoop(for: 0.06)
    check(
      configurator.appliedDeviceIDs == [10],
      "a cancelled route A drains before the replacement default B is configured"
    )
    check(!secondStartCallback, "the replacement request cannot consume route A's pending state")

    check(
      waitForMainQueue({ eventSource.emittedEventCount >= 1 }),
      "the delayed graph notification for cancelled route A is observed by its own draining ticket"
    )
    check(
      waitForMainQueue({ configurator.appliedDeviceIDs == [10, 20] }),
      "only after route A drains does the replacement request configure default B"
    )
    check(
      !secondStartCallback,
      "route A's delayed callback cannot complete the replacement B ticket"
    )
    check(
      waitForMainQueue({ secondStartCallback }, timeout: 1),
      "the replacement request completes only after its own configuration event"
    )
    check(secondStartError is AudioCaptureError, "the no-hardware harness reports B as unready")
    check(!firstStartCallback, "the cancelled route A never reports a late start")
  }

  private static func testDelayedPreparationConfigurationChange() {
    let engineQueue = DispatchQueue(label: "shanshuo.preparation-event-order-test")
    let eventSource = ControlledAudioEngineEventSource()
    let configurator = DelayedSetupInputDeviceConfigurator(eventSource: eventSource)
    let capture = MemoryAudioCapture(
      engineEvents: eventSource,
      inputDeviceConfigurator: configurator,
      engineQueue: engineQueue,
      availabilityProvider: { false },
      inputFormatProvider: { nil },
      configurationConfirmationTimeout: .milliseconds(300),
      prepareEngine: { _ in }
    )

    var didReceiveStart = false
    var receivedError: Error?
    _ = capture.start(
      onLevel: { _ in
        fputs("FAIL: preparation must not arm a microphone tap before readiness\n", stderr)
        exit(1)
      },
      completion: { _, result in
        didReceiveStart = true
        if case .failure(let error) = result {
          receivedError = error
        }
      }
    )

    runMainLoop(for: 0.1)
    check(
      !didReceiveStart,
      "a route-changing preparation cannot complete merely because the setter returned"
    )
    check(
      waitForMainQueue({ eventSource.emittedEventCount == 1 }),
      "a controlled configuration notification arrives after the start request begins preparation"
    )
    check(
      waitForMainQueue({ didReceiveStart }, timeout: 1),
      "the revalidated preparation reports its result after the delayed configuration event settles"
    )
    check(receivedError is AudioCaptureError, "an unready input never reaches engine start")
  }

  private static func testUnconfirmedPreparationRejectsPendingRequest() {
    let engineQueue = DispatchQueue(label: "shanshuo.unconfirmed-preparation-test")
    let eventSource = ControlledAudioEngineEventSource()
    let configurator = RouteChangingInputDeviceConfigurator(
      eventSource: eventSource,
      configurationEventDelay: .milliseconds(300)
    )
    let capture = MemoryAudioCapture(
      engineEvents: eventSource,
      inputDeviceConfigurator: configurator,
      engineQueue: engineQueue,
      availabilityProvider: { false },
      inputFormatProvider: { nil },
      configurationConfirmationTimeout: .milliseconds(80),
      prepareEngine: { _ in }
    )

    let firstOperation = capture.start(onLevel: { _ in }, completion: { _, _ in })
    runMainLoop(for: 0.02)
    firstOperation.cancel()

    configurator.defaultDeviceID = 20
    var didReceiveReplacementResult = false
    var replacementError: Error?
    _ = capture.start(
      onLevel: { _ in
        fputs("FAIL: an unconfirmed route must not capture audio\n", stderr)
        exit(1)
      },
      completion: { _, result in
        didReceiveReplacementResult = true
        if case .failure(let error) = result {
          replacementError = error
        }
      }
    )

    check(
      waitForMainQueue({ didReceiveReplacementResult }, timeout: 1),
      "a replacement request receives an explicit unavailable result when route A never confirms"
    )
    check(replacementError is AudioCaptureError, "an unconfirmed route reports unavailable")
    check(
      configurator.appliedDeviceIDs == [10],
      "a timed-out route A cannot begin replacement B on the same engine"
    )
  }

  private static func testFollowDefaultRevalidatesPreparedRoute() {
    let engineQueue = DispatchQueue(label: "shanshuo.default-route-revalidation-test")
    let eventSource = ControlledAudioEngineEventSource()
    let configurator = RouteChangingInputDeviceConfigurator(
      eventSource: eventSource,
      configurationEventDelay: .seconds(5),
      currentDeviceID: 10
    )
    let format = InputFormatSignature(sampleRate: 48_000, channelCount: 1)
    let capture = MemoryAudioCapture(
      engineEvents: eventSource,
      inputDeviceConfigurator: configurator,
      engineQueue: engineQueue,
      availabilityProvider: { true },
      inputFormatProvider: { format },
      prepareEngine: { _ in }
    )

    capture.prepare()
    runMainLoop(for: 0.05)
    check(
      configurator.appliedDeviceIDs.isEmpty,
      "a preparation records an already-applied default route without touching the input unit"
    )

    configurator.defaultDeviceID = 20
    capture.prepare()
    check(
      waitForMainQueue({ configurator.appliedDeviceIDs == [20] }),
      "the next follow-default preparation resolves B instead of reusing prepared default A"
    )

    eventSource.emitConfigurationChange()
    runMainLoop(for: 0.05)
  }

  private static func testTimedOutEngineIgnoresLateRouteEvent() {
    let engineQueue = DispatchQueue(label: "shanshuo.timed-out-engine-isolation-test")
    let eventSource = ControlledAudioEngineEventSource()
    let configurator = RouteChangingInputDeviceConfigurator(
      eventSource: eventSource,
      configurationEventDelay: .seconds(5)
    )
    let capture = MemoryAudioCapture(
      engineEvents: eventSource,
      inputDeviceConfigurator: configurator,
      engineQueue: engineQueue,
      availabilityProvider: { false },
      inputFormatProvider: { nil },
      configurationConfirmationTimeout: .milliseconds(40),
      prepareEngine: { _ in }
    )

    var firstDidFail = false
    _ = capture.start(
      onLevel: { _ in },
      completion: { _, result in
        if case .failure = result {
          firstDidFail = true
        }
      }
    )
    check(
      waitForMainQueue({ firstDidFail }),
      "an unconfirmed route A fails before its engine is retired"
    )

    configurator.defaultDeviceID = 20
    var secondDidComplete = false
    _ = capture.start(
      onLevel: { _ in },
      completion: { _, _ in
        secondDidComplete = true
      }
    )
    check(
      waitForMainQueue({ configurator.appliedDeviceIDs == [10, 20] }),
      "a later B request configures a replacement engine after A timed out"
    )

    eventSource.emitConfigurationChange(observationAt: 0)
    runMainLoop(for: 0.01)
    check(
      !secondDidComplete,
      "a late configuration event from retired A cannot complete or interrupt B"
    )
    check(
      configurator.appliedDeviceIDs == [10, 20],
      "a late event from retired A cannot begin another preparation on B's engine"
    )

    eventSource.emitConfigurationChange()
    check(
      waitForMainQueue({ secondDidComplete }),
      "only B's own replacement-engine event can complete B's preparation"
    )
  }

  private static func testQueuedPreparationKeepsResolvedRoute() {
    let engineQueue = DispatchQueue(label: "shanshuo.queued-route-snapshot-test")
    let eventSource = ControlledAudioEngineEventSource()
    let configurator = RouteChangingInputDeviceConfigurator(
      eventSource: eventSource,
      configurationEventDelay: .seconds(5)
    )
    let capture = MemoryAudioCapture(
      engineEvents: eventSource,
      inputDeviceConfigurator: configurator,
      engineQueue: engineQueue,
      availabilityProvider: { false },
      inputFormatProvider: { nil },
      prepareEngine: { _ in }
    )

    _ = capture.start(onLevel: { _ in }, completion: { _, _ in })
    check(
      waitForMainQueue({ configurator.appliedDeviceIDs == [10] }),
      "the first preparation configures default A"
    )

    configurator.defaultDeviceID = 20
    var bDidComplete = false
    var bError: Error?
    _ = capture.start(
      onLevel: { _ in
        fputs("FAIL: queued B must not arm capture before its own preparation\n", stderr)
        exit(1)
      },
      completion: { _, result in
        bDidComplete = true
        if case .failure(let error) = result {
          bError = error
        }
      }
    )

    runMainLoop(for: 0.02)
    configurator.defaultDeviceID = 30
    eventSource.emitConfigurationChange()
    check(
      waitForMainQueue({ configurator.appliedDeviceIDs == [10, 20] }),
      "B keeps its resolved route after the system default advances to C"
    )
    check(
      !configurator.appliedDeviceIDs.contains(30),
      "draining A never configures the later default C for B's request"
    )

    eventSource.emitConfigurationChange()
    check(
      waitForMainQueue({ bDidComplete }),
      "queued B reports a result instead of hanging behind A's preparation"
    )
    check(bError is AudioCaptureError, "the no-hardware B result is an explicit unavailable error")
  }

  private static func testAvailabilityRequiresCompletedPreparation() {
    let format = InputFormatSignature(sampleRate: 48_000, channelCount: 1)
    let timeoutQueue = DispatchQueue(label: "shanshuo.timeout-availability-test")
    let timeoutEvents = ControlledAudioEngineEventSource()
    let timeoutConfigurator = RouteChangingInputDeviceConfigurator(
      eventSource: timeoutEvents,
      configurationEventDelay: .seconds(5)
    )
    let timeoutCapture = MemoryAudioCapture(
      engineEvents: timeoutEvents,
      inputDeviceConfigurator: timeoutConfigurator,
      engineQueue: timeoutQueue,
      availabilityProvider: { true },
      inputFormatProvider: { format },
      configurationConfirmationTimeout: .milliseconds(40),
      prepareEngine: { _ in }
    )

    timeoutCapture.prepare()
    runMainLoop(for: 0.08)
    check(
      !timeoutCapture.isAvailable,
      "a replacement engine with a valid physical format stays unavailable after route A times out"
    )

    let mismatchQueue = DispatchQueue(label: "shanshuo.route-mismatch-availability-test")
    let mismatchEvents = ControlledAudioEngineEventSource()
    let mismatchConfigurator = RouteChangingInputDeviceConfigurator(
      eventSource: mismatchEvents,
      configurationEventDelay: .seconds(5)
    )
    let mismatchCapture = MemoryAudioCapture(
      engineEvents: mismatchEvents,
      inputDeviceConfigurator: mismatchConfigurator,
      engineQueue: mismatchQueue,
      availabilityProvider: { true },
      inputFormatProvider: { format },
      prepareEngine: { _ in }
    )

    mismatchCapture.prepare()
    check(
      waitForMainQueue({ mismatchConfigurator.appliedDeviceIDs == [10] }),
      "the mismatch test begins a route A preparation"
    )
    mismatchConfigurator.replaceCurrentDeviceID(20)
    mismatchEvents.emitConfigurationChange()
    runMainLoop(for: 0.05)
    check(
      !mismatchCapture.isAvailable,
      "a physically valid but wrong input route never publishes ready"
    )
  }
}

private func runMainLoop(for duration: TimeInterval) {
  let deadline = Date().addingTimeInterval(duration)
  while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
}
