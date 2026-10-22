import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ShanshuoCore

struct CapturedAudio {
  var samples: [Float]
  let sampleRate: Int
  let duration: TimeInterval

  mutating func erase() {
    samples.withUnsafeMutableBufferPointer { buffer in
      buffer.initialize(repeating: 0)
    }
    samples.removeAll(keepingCapacity: false)
  }
}

enum AudioCaptureError: Error {
  case unavailable
  case failedToStart
}

protocol AudioCaptureOperation: AnyObject {
  func cancel()
}

protocol AudioCapturing: AnyObject {
  /// A lock-protected cache. AVAudioEngine is never queried from the caller's thread.
  var isAvailable: Bool { get }
  var onInterruption: ((AudioCaptureOperation) -> Void)? { get set }
  var availableInputDevices: [InputDevice] { get }
  var selectedInputDeviceUID: String? { get set }
  func prepare()
  @discardableResult
  func start(
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) -> AudioCaptureOperation
  func stop(_ operation: AudioCaptureOperation, completion: @escaping (CapturedAudio) -> Void)
}

/// The only audio store is this process-memory buffer. Engine prepare/start/stop and tap
/// installation all run on one serial queue, so a slow cold start cannot block an event-tap
/// callback on the main thread. Cancellation invalidates the operation under a lock before its
/// queued cleanup runs, which makes a late start completion stop and discard instead of reviving a
/// session.
final class MemoryAudioCapture: AudioCapturing {
  static let sampleRate = 16_000
  private static let maximumSamples = Int(DictationRules.maximumRecording) * sampleRate

  private var engine: AVAudioEngine
  private var inputDeviceConfigurator: InputDeviceConfiguring
  private let engineQueue: DispatchQueue
  private let engineEvents: AudioEngineEventObserving
  private let makeEngine: () -> AVAudioEngine
  private let makeInputDeviceConfigurator: (AVAudioEngine) -> InputDeviceConfiguring
  private let availabilityProvider: (() -> Bool)?
  private let inputFormatProvider: (() -> InputFormatSignature?)?
  private let configurationConfirmationTimeout: DispatchTimeInterval
  private let prepareEngine: (AVAudioEngine) -> Void
  private let stateLock = NSLock()
  private var converter: AVAudioConverter?
  private var samples: [Float] = []
  private var levelHandler: ((Float) -> Void)?
  private var activeOperationIdentifier: UInt64?
  // The engine queue must retain an operation until its queued start/stop work has released the
  // input tap. A weak reference can disappear after a natural microphone-test stop, leaving an
  // engine stop closure with nothing to execute.
  private var activeOperation: MemoryAudioCaptureOperation?
  private var nextOperationIdentifier: UInt64 = 0
  private var isRunning = false
  private var cachedAvailability = false
  private var tapIsInstalled = false
  private var engineEventObservation: AudioEngineEventObservation?
  private var requestedInputDeviceUID: String?
  private var preparedInputRoute: PreparedInputRoute?
  private var activePreparation: InputPreparation?
  private var pendingPreparation: PendingPreparation?
  private var nextPreparationGeneration: UInt64 = 0
  private var engineConfigurationEpoch: UInt64 = 0
  private var engineInstanceEpoch: UInt64 = 0

  var onInterruption: ((AudioCaptureOperation) -> Void)? {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return interruptionHandler
    }
    set {
      stateLock.lock()
      interruptionHandler = newValue
      stateLock.unlock()
    }
  }
  private var interruptionHandler: ((AudioCaptureOperation) -> Void)?

  init(
    engine: AVAudioEngine = AVAudioEngine(),
    engineEvents: AudioEngineEventObserving = SystemAudioEngineEventSource(),
    inputDeviceConfigurator: InputDeviceConfiguring? = nil,
    engineQueue: DispatchQueue? = nil,
    availabilityProvider: (() -> Bool)? = nil,
    inputFormatProvider: (() -> InputFormatSignature?)? = nil,
    configurationConfirmationTimeout: DispatchTimeInterval = .seconds(2),
    prepareEngine: ((AVAudioEngine) -> Void)? = nil,
    engineFactory: @escaping () -> AVAudioEngine = { AVAudioEngine() }
  ) {
    self.engine = engine
    self.engineQueue =
      engineQueue
      ?? DispatchQueue(label: "com.arnow117.shanshuo.audio-engine", qos: .userInitiated)
    if let inputDeviceConfigurator {
      self.inputDeviceConfigurator = inputDeviceConfigurator
      makeInputDeviceConfigurator = { _ in inputDeviceConfigurator }
    } else {
      self.inputDeviceConfigurator = EngineInputDeviceConfigurator(inputNode: engine.inputNode)
      makeInputDeviceConfigurator = { replacementEngine in
        EngineInputDeviceConfigurator(inputNode: replacementEngine.inputNode)
      }
    }
    self.engineEvents = engineEvents
    makeEngine = engineFactory
    self.availabilityProvider = availabilityProvider
    self.inputFormatProvider = inputFormatProvider
    self.configurationConfirmationTimeout = configurationConfirmationTimeout
    self.prepareEngine = prepareEngine ?? { $0.prepare() }
    installEngineEventObservation()
  }

  deinit {
    engineEventObservation?.cancel()
  }

  var isAvailable: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cachedAvailability
  }

  var availableInputDevices: [InputDevice] {
    inputDeviceConfigurator.availableDevices()
  }

  var selectedInputDeviceUID: String? {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return requestedInputDeviceUID
    }
    set {
      stateLock.lock()
      requestedInputDeviceUID = newValue
      let hasActiveOperation = activeOperationIdentifier != nil
      stateLock.unlock()
      if !hasActiveOperation {
        prepare()
      }
    }
  }

  func prepare() {
    let plan = currentInputDevicePlan()
    engineQueue.async { [weak self] in
      guard let self else {
        return
      }
      guard !self.hasActiveOperation() else {
        return
      }
      self.beginPreparation(for: plan, operationIdentifier: nil, completion: nil)
    }
  }

  @discardableResult
  func start(
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) -> AudioCaptureOperation {
    let operation = makeOperation()
    let lease = QueuedAudioOperationLease(operation)
    engineQueue.async { [weak self, lease] in
      guard let self else {
        return
      }
      self.startOnEngineQueue(lease.operation, onLevel: onLevel, completion: completion)
    }
    return operation
  }

  func stop(_ operation: AudioCaptureOperation, completion: @escaping (CapturedAudio) -> Void) {
    guard let operation = operation as? MemoryAudioCaptureOperation else {
      DispatchQueue.main.async {
        completion(Self.emptyAudio)
      }
      return
    }
    let lease = QueuedAudioOperationLease(operation)
    engineQueue.async { [weak self, lease] in
      guard let self else {
        return
      }
      let audio = self.stopOnEngineQueue(lease.operation)
      DispatchQueue.main.async {
        completion(audio)
      }
    }
  }

  private func makeOperation() -> MemoryAudioCaptureOperation {
    stateLock.lock()
    nextOperationIdentifier &+= 1
    let identifier = nextOperationIdentifier
    let inputDevicePlan = InputDeviceSessionPlan(preferredUID: requestedInputDeviceUID)
    let operation = MemoryAudioCaptureOperation(
      identifier: identifier,
      inputDevicePlan: inputDevicePlan,
      capture: self
    )
    activeOperationIdentifier = identifier
    activeOperation = operation
    isRunning = false
    levelHandler = nil
    eraseSamplesLocked()
    stateLock.unlock()
    return operation
  }

  private func startOnEngineQueue(
    _ operation: MemoryAudioCaptureOperation,
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) {
    guard isCurrent(operation) else {
      return
    }

    guard
      let resolvedRoute = InputDeviceSessionConfigurator.resolve(
        plan: operation.inputDevicePlan,
        using: inputDeviceConfigurator
      )
    else {
      markInputPlanUnready()
      completeStart(
        operation,
        result: .failure(AudioCaptureError.unavailable),
        completion: completion
      )
      return
    }

    if activePreparation == nil, preparedRouteMatches(resolvedRoute) {
      armCaptureOnEngineQueue(
        operation,
        resolvedRoute: resolvedRoute,
        onLevel: onLevel,
        completion: completion
      )
      return
    }

    beginPreparation(
      for: operation.inputDevicePlan,
      resolvedRoute: resolvedRoute,
      operationIdentifier: operation.identifier
    ) {
      [weak self, operation] didPrepare in
      guard let self, self.isCurrent(operation) else {
        return
      }
      guard didPrepare else {
        self.completeStart(
          operation, result: .failure(AudioCaptureError.unavailable), completion: completion)
        return
      }
      self.armCaptureOnEngineQueue(
        operation,
        resolvedRoute: resolvedRoute,
        onLevel: onLevel,
        completion: completion
      )
    }
  }

  private func armCaptureOnEngineQueue(
    _ operation: MemoryAudioCaptureOperation,
    resolvedRoute: ResolvedInputDevicePlan,
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) {
    guard isCurrent(operation), preparedRouteMatches(resolvedRoute) else {
      return
    }

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Self.sampleRate),
        channels: 1,
        interleaved: false
      ),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else {
      markInputPlanUnready()
      completeStart(
        operation, result: .failure(AudioCaptureError.unavailable), completion: completion)
      return
    }

    stateLock.lock()
    let isStillCurrent = activeOperationIdentifier == operation.identifier
    if isStillCurrent {
      self.converter = converter
      levelHandler = onLevel
      isRunning = true
    }
    stateLock.unlock()
    guard isStillCurrent else {
      return
    }

    input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
      [weak self, operation] buffer, _ in
      guard let self else {
        return
      }
      self.consume(buffer, operation: operation)
    }
    tapIsInstalled = true

    do {
      engine.prepare()
      try engine.start()
    } catch {
      stopEngineOnEngineQueue()
      markInputPlanUnready()
      completeStart(
        operation, result: .failure(AudioCaptureError.failedToStart), completion: completion)
      return
    }

    guard isCurrent(operation) else {
      stopEngineOnEngineQueue()
      return
    }
    completeStart(operation, result: .success(()), completion: completion)
  }

  private func stopOnEngineQueue(_ operation: MemoryAudioCaptureOperation) -> CapturedAudio {
    guard isCurrent(operation) else {
      return Self.emptyAudio
    }
    activePreparation = nil
    stopEngineOnEngineQueue()

    stateLock.lock()
    guard activeOperationIdentifier == operation.identifier else {
      stateLock.unlock()
      return Self.emptyAudio
    }
    let audio = CapturedAudio(
      samples: samples,
      sampleRate: Self.sampleRate,
      duration: Double(samples.count) / Double(Self.sampleRate)
    )
    samples.removeAll(keepingCapacity: false)
    activeOperationIdentifier = nil
    activeOperation = nil
    stateLock.unlock()
    return audio
  }

  fileprivate func cancel(operationIdentifier: UInt64) {
    stateLock.lock()
    guard activeOperationIdentifier == operationIdentifier else {
      stateLock.unlock()
      return
    }
    activeOperationIdentifier = nil
    activeOperation = nil
    isRunning = false
    converter = nil
    levelHandler = nil
    eraseSamplesLocked()
    stateLock.unlock()

    engineQueue.async { [weak self] in
      guard let self else {
        return
      }
      self.discardPendingPreparation(for: operationIdentifier)
      self.stopEngineOnEngineQueue()
    }
  }

  private func completeStart(
    _ operation: MemoryAudioCaptureOperation,
    result: Result<Void, Error>,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) {
    guard isCurrent(operation) else {
      return
    }
    DispatchQueue.main.async {
      completion(operation, result)
    }
  }

  private func consume(_ inputBuffer: AVAudioPCMBuffer, operation: MemoryAudioCaptureOperation) {
    stateLock.lock()
    guard activeOperationIdentifier == operation.identifier, isRunning, let converter else {
      stateLock.unlock()
      return
    }
    let levelHandler = self.levelHandler

    let ratio = Double(Self.sampleRate) / inputBuffer.format.sampleRate
    let capacity = AVAudioFrameCount(max(1, (Double(inputBuffer.frameLength) * ratio).rounded(.up)))
    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: converter.outputFormat,
        frameCapacity: capacity
      )
    else {
      stateLock.unlock()
      return
    }

    var consumedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
      if consumedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumedInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }
    guard status != .error, conversionError == nil, let channel = outputBuffer.floatChannelData?[0]
    else {
      stateLock.unlock()
      return
    }

    let values = UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
    appendSamplesLocked(Array(values))
    let peak = values.reduce(Float.zero) { max($0, abs($1)) }
    stateLock.unlock()

    DispatchQueue.main.async { [weak self, weak operation] in
      guard let self, let operation, self.isCurrent(operation) else {
        return
      }
      levelHandler?(peak)
    }
  }

  private func stopEngineOnEngineQueue() {
    stateLock.lock()
    isRunning = false
    converter = nil
    levelHandler = nil
    stateLock.unlock()

    if tapIsInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapIsInstalled = false
    }
    engine.stop()
  }

  private func installEngineEventObservation() {
    let observedEngineEpoch = engineInstanceEpoch
    engineEventObservation = engineEvents.observe(engine: engine) { [weak self] in
      self?.handleEngineConfigurationChange(for: observedEngineEpoch)
    }
  }

  private func handleEngineConfigurationChange(for observedEngineEpoch: UInt64) {
    engineQueue.async { [weak self] in
      guard let self, self.engineInstanceEpoch == observedEngineEpoch else {
        return
      }
      self.handleEngineConfigurationChangeOnEngineQueue()
    }
  }

  private func handleEngineConfigurationChangeOnEngineQueue() {
    engineConfigurationEpoch &+= 1
    if var preparation = activePreparation {
      // `setDeviceID` can deliver this notification after it returns. This ticket has not armed a
      // tap, so record the new graph epoch and revalidate the same immutable route before it can
      // become ready. The ticket's target ID is never resolved again here.
      guard preparation.engineInstanceEpoch == engineInstanceEpoch else {
        return
      }
      preparation.recordConfigurationChange(engineEpoch: engineConfigurationEpoch)
      activePreparation = preparation
      prepareEngine(engine)
      schedulePreparationCommit(preparation)
      return
    }
    preparedInputRoute = nil
    let hadActiveOperation = hasActiveOperation()
    if hadActiveOperation {
      interruptActiveOperationOnEngineQueue()
    }
    markInputPlanUnready()
    beginPreparation(for: currentInputDevicePlan(), operationIdentifier: nil, completion: nil)
  }

  private func interruptActiveOperationOnEngineQueue() {
    let interruptedOperation = invalidateActiveOperation()
    stopEngineOnEngineQueue()
    markInputPlanUnready()

    guard let interruptedOperation else {
      return
    }
    let handler = onInterruption
    DispatchQueue.main.async {
      handler?(interruptedOperation)
    }
  }

  /// Physical input format is only one prerequisite. The public cache becomes true later, after a
  /// preparation ticket proves that this exact route and graph epoch are ready together.
  private func inputIsPhysicallyAvailableOnEngineQueue() -> Bool {
    if let availabilityProvider {
      return availabilityProvider()
    }
    let format = engine.inputNode.outputFormat(forBus: 0)
    return format.sampleRate > 0 && format.channelCount > 0
  }

  private func currentInputFormatSignature() -> InputFormatSignature? {
    if let inputFormatProvider {
      return inputFormatProvider()
    }

    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      return nil
    }
    return InputFormatSignature(sampleRate: format.sampleRate, channelCount: format.channelCount)
  }

  private func preparedRouteMatches(_ resolvedRoute: ResolvedInputDevicePlan) -> Bool {
    guard let preparedInputRoute,
      preparedInputRoute.plan == resolvedRoute.plan,
      preparedInputRoute.deviceID == resolvedRoute.deviceID,
      preparedInputRoute.deviceUID == resolvedRoute.deviceUID,
      preparedInputRoute.engineInstanceEpoch == engineInstanceEpoch,
      preparedInputRoute.configurationEpoch == engineConfigurationEpoch,
      inputDeviceConfigurator.currentInputDeviceID() == resolvedRoute.deviceID,
      currentInputFormatSignature() == preparedInputRoute.inputFormat
    else {
      return false
    }
    return true
  }

  private func beginPreparation(
    for plan: InputDeviceSessionPlan,
    resolvedRoute: ResolvedInputDevicePlan? = nil,
    operationIdentifier: UInt64?,
    completion: ((Bool) -> Void)?
  ) {
    guard !isRunning else {
      completion?(false)
      return
    }

    if activePreparation != nil {
      guard
        let pendingResolvedRoute = resolvedRoute
          ?? InputDeviceSessionConfigurator.resolve(
            plan: plan,
            using: inputDeviceConfigurator
          )
      else {
        markInputPlanUnready()
        completion?(false)
        return
      }
      pendingPreparation = PendingPreparation(
        plan: plan,
        resolvedRoute: pendingResolvedRoute,
        operationIdentifier: operationIdentifier,
        completion: completion
      )
      return
    }

    stopEngineOnEngineQueue()
    guard
      let resolvedRoute = resolvedRoute
        ?? InputDeviceSessionConfigurator.resolve(
          plan: plan,
          using: inputDeviceConfigurator
        )
    else {
      markInputPlanUnready()
      completion?(false)
      return
    }

    let deviceAlreadyApplied =
      inputDeviceConfigurator.currentInputDeviceID() == resolvedRoute.deviceID
    nextPreparationGeneration &+= 1
    let preparation = InputPreparation(
      generation: nextPreparationGeneration,
      revision: 0,
      plan: plan,
      operationIdentifier: operationIdentifier,
      targetDeviceID: resolvedRoute.deviceID,
      targetDeviceUID: resolvedRoute.deviceUID,
      engineInstanceEpoch: engineInstanceEpoch,
      engineEpoch: engineConfigurationEpoch,
      requiresConfigurationConfirmation: !deviceAlreadyApplied,
      observedConfigurationConfirmation: false,
      completion: completion
    )
    activePreparation = preparation
    preparedInputRoute = nil

    guard
      deviceAlreadyApplied
        || InputDeviceSessionConfigurator.apply(
          resolvedRoute.deviceID, using: inputDeviceConfigurator)
    else {
      markInputPlanUnready()
      finishPreparation(preparation, didPrepare: false)
      return
    }

    prepareEngine(engine)
    if preparation.requiresConfigurationConfirmation {
      scheduleConfigurationConfirmationTimeout(preparation)
    } else {
      schedulePreparationCommit(preparation)
    }
  }

  private func schedulePreparationCommit(_ preparation: InputPreparation) {
    engineQueue.async { [weak self] in
      guard let self else {
        return
      }
      self.commitPreparation(preparation)
    }
  }

  /// A timeout is only a safe rejection path. It never makes a device plan ready: an actual route
  /// change must first deliver a graph configuration event for this generation.
  private func scheduleConfigurationConfirmationTimeout(_ preparation: InputPreparation) {
    engineQueue.asyncAfter(deadline: .now() + configurationConfirmationTimeout) { [weak self] in
      guard let self, self.activePreparation == preparation,
        preparation.requiresConfigurationConfirmation,
        !preparation.observedConfigurationConfirmation
      else {
        return
      }
      self.failTimedOutPreparation(preparation)
    }
  }

  private func commitPreparation(_ expected: InputPreparation) {
    guard activePreparation == expected,
      expected.engineInstanceEpoch == engineInstanceEpoch,
      expected.engineEpoch == engineConfigurationEpoch,
      !expected.requiresConfigurationConfirmation || expected.observedConfigurationConfirmation
    else {
      return
    }

    let isPreparedForExpectedDevice =
      expected.targetDeviceID == inputDeviceConfigurator.currentInputDeviceID()
    let inputIsPhysicallyAvailable = inputIsPhysicallyAvailableOnEngineQueue()
    let inputFormat = currentInputFormatSignature()
    let didPrepare =
      isPreparedForExpectedDevice && inputIsPhysicallyAvailable
      && inputFormat != nil
    if let inputFormat, didPrepare {
      preparedInputRoute = PreparedInputRoute(
        plan: expected.plan,
        deviceID: expected.targetDeviceID,
        deviceUID: expected.targetDeviceUID,
        engineInstanceEpoch: engineInstanceEpoch,
        configurationEpoch: engineConfigurationEpoch,
        inputFormat: inputFormat
      )
    }
    publishPreparedAvailability(didPrepare)
    finishPreparation(expected, didPrepare: didPrepare)
  }

  private func finishPreparation(_ preparation: InputPreparation, didPrepare: Bool) {
    guard activePreparation == preparation else {
      return
    }
    activePreparation = nil
    if !didPrepare {
      preparedInputRoute = nil
    }
    preparation.completion?(didPrepare)

    guard let pending = pendingPreparation else {
      return
    }
    pendingPreparation = nil
    guard pending.operationIdentifier.map(isOperationIdentifierCurrent) ?? true else {
      return
    }

    // If this ticket never received its required configuration event, its queue can still hold an
    // arbitrarily late callback. Do not begin the queued request on the same engine: report it as
    // unready instead, so that callback cannot be mistaken for the replacement ticket's event.
    guard
      didPrepare || !preparation.requiresConfigurationConfirmation
        || preparation.observedConfigurationConfirmation
    else {
      pending.completion?(false)
      return
    }
    beginPreparation(
      for: pending.plan,
      resolvedRoute: pending.resolvedRoute,
      operationIdentifier: pending.operationIdentifier,
      completion: pending.completion
    )
  }

  /// A ticket that never receives its own graph-completion notification is not safe to reuse. A
  /// replacement engine gives the next request a distinct notification source, so a late event
  /// from this timed-out engine cannot confirm or interrupt that later request.
  private func failTimedOutPreparation(_ preparation: InputPreparation) {
    guard activePreparation == preparation else {
      return
    }

    markInputPlanUnready()
    activePreparation = nil
    preparedInputRoute = nil
    preparation.completion?(false)

    if let pendingPreparation {
      self.pendingPreparation = nil
      if pendingPreparation.operationIdentifier.map(isOperationIdentifierCurrent) ?? true {
        pendingPreparation.completion?(false)
      }
    }

    retireEngineOnEngineQueue()
  }

  private func retireEngineOnEngineQueue() {
    engineEventObservation?.cancel()
    stopEngineOnEngineQueue()

    engine = makeEngine()
    inputDeviceConfigurator = makeInputDeviceConfigurator(engine)
    tapIsInstalled = false
    preparedInputRoute = nil
    engineConfigurationEpoch = 0
    engineInstanceEpoch &+= 1
    installEngineEventObservation()
    markInputPlanUnready()
  }

  private func publishPreparedAvailability(_ isAvailable: Bool) {
    stateLock.lock()
    defer { stateLock.unlock() }
    cachedAvailability = isAvailable
  }

  private func markInputPlanUnready() {
    stateLock.lock()
    cachedAvailability = false
    stateLock.unlock()
  }

  private func currentInputDevicePlan() -> InputDeviceSessionPlan {
    stateLock.lock()
    defer { stateLock.unlock() }
    return InputDeviceSessionPlan(preferredUID: requestedInputDeviceUID)
  }

  private func hasActiveOperation() -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return activeOperationIdentifier != nil
  }

  private func isCurrent(_ operation: MemoryAudioCaptureOperation) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return activeOperationIdentifier == operation.identifier
  }

  private func isOperationIdentifierCurrent(_ identifier: UInt64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return activeOperationIdentifier == identifier
  }

  private func discardPendingPreparation(for operationIdentifier: UInt64) {
    guard pendingPreparation?.operationIdentifier == operationIdentifier else {
      return
    }
    pendingPreparation = nil
  }

  private func invalidateActiveOperation() -> MemoryAudioCaptureOperation? {
    stateLock.lock()
    let operation = activeOperation
    guard activeOperationIdentifier != nil else {
      stateLock.unlock()
      return nil
    }
    activeOperationIdentifier = nil
    activeOperation = nil
    isRunning = false
    converter = nil
    levelHandler = nil
    eraseSamplesLocked()
    stateLock.unlock()
    return operation
  }

  private func appendSamplesLocked(_ newSamples: [Float]) {
    let remainingCapacity = Self.maximumSamples - samples.count
    guard remainingCapacity > 0 else {
      return
    }
    samples.append(contentsOf: newSamples.prefix(remainingCapacity))
  }

  private func eraseSamplesLocked() {
    samples.withUnsafeMutableBufferPointer { buffer in
      buffer.initialize(repeating: 0)
    }
    samples.removeAll(keepingCapacity: false)
  }

  private static var emptyAudio: CapturedAudio {
    CapturedAudio(samples: [], sampleRate: sampleRate, duration: 0)
  }
}

/// The production adapter changes only this process's AVAudioEngine input unit. It resolves the
/// system default per operation, so the next recording follows an OS default change without moving
/// an active capture or changing the OS default itself.
private final class EngineInputDeviceConfigurator: InputDeviceConfiguring {
  private let inputNode: AVAudioInputNode

  init(inputNode: AVAudioInputNode) {
    self.inputNode = inputNode
  }

  func availableDevices() -> [InputDevice] {
    SystemInputDevices.available()
  }

  func deviceID(for uid: String) -> AudioDeviceID? {
    SystemInputDevices.deviceID(for: uid)
  }

  func deviceUID(for deviceID: AudioDeviceID) -> String? {
    SystemInputDevices.deviceUID(for: deviceID)
  }

  func defaultInputDeviceID() -> AudioDeviceID? {
    SystemInputDevices.defaultInputDeviceID()
  }

  func currentInputDeviceID() -> AudioDeviceID? {
    inputNode.auAudioUnit.deviceID
  }

  func apply(deviceID: AudioDeviceID) throws {
    try inputNode.auAudioUnit.setDeviceID(deviceID)
  }
}

private enum SystemInputDevices {
  static func available() -> [InputDevice] {
    allDeviceIDs().compactMap { deviceID in
      guard hasInputStreams(deviceID),
        InputDeviceVisibility.shouldOffer(isPrivateAggregate: isPrivateAggregateDevice(deviceID)),
        let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
        let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
      else {
        return nil
      }
      return InputDevice(uid: uid, name: name)
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  static func deviceID(for uid: String) -> AudioDeviceID? {
    allDeviceIDs().first { deviceID in
      stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) == uid
        && hasInputStreams(deviceID)
        && InputDeviceVisibility.shouldOffer(
          isPrivateAggregate: isPrivateAggregateDevice(deviceID)
        )
    }
  }

  static func deviceUID(for deviceID: AudioDeviceID) -> String? {
    stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
  }

  static func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var defaultDeviceID = AudioDeviceID(kAudioObjectUnknown)
    var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
    let result = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &byteCount,
      &defaultDeviceID
    )
    guard result == noErr, defaultDeviceID != AudioDeviceID(kAudioObjectUnknown) else {
      return nil
    }
    return defaultDeviceID
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount
      ) == noErr
    else {
      return []
    }
    let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
    var devices = Array(repeating: AudioDeviceID(), count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount,
        &devices
      ) == noErr
    else {
      return []
    }
    return devices
  }

  private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr,
      byteCount >= MemoryLayout<AudioBufferList>.size
    else {
      return false
    }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(byteCount), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, storage) == noErr
    else {
      return false
    }
    let buffers = storage.assumingMemoryBound(to: AudioBufferList.self)
    return buffers.pointee.mNumberBuffers > 0
  }

  /// CoreAudio marks automatic default aggregates as private in their aggregate composition.
  /// This excludes only process-private devices; user-created aggregates and virtual input
  /// hardware remain selectable by stable UID.
  private static func isPrivateAggregateDevice(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioAggregateDevicePropertyComposition,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFDictionary>?
    var byteCount = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value) == noErr,
      let composition = value?.takeUnretainedValue() as NSDictionary?,
      let isPrivate = composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber
    else {
      return false
    }
    return isPrivate.boolValue
  }

  private static func stringProperty(
    _ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector
  )
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value) == noErr else {
      return nil
    }
    return value?.takeUnretainedValue() as String?
  }
}

struct InputFormatSignature: Equatable {
  let sampleRate: Double
  let channelCount: AVAudioChannelCount
}

private struct PreparedInputRoute: Equatable {
  let plan: InputDeviceSessionPlan
  let deviceID: AudioDeviceID
  let deviceUID: String?
  let engineInstanceEpoch: UInt64
  let configurationEpoch: UInt64
  let inputFormat: InputFormatSignature
}

struct InputPreparation: Equatable {
  let generation: UInt64
  var revision: UInt64
  let plan: InputDeviceSessionPlan
  let operationIdentifier: UInt64?
  let targetDeviceID: AudioDeviceID
  let targetDeviceUID: String?
  let engineInstanceEpoch: UInt64
  var engineEpoch: UInt64
  let requiresConfigurationConfirmation: Bool
  var observedConfigurationConfirmation: Bool
  let completion: ((Bool) -> Void)?

  static func == (lhs: InputPreparation, rhs: InputPreparation) -> Bool {
    lhs.generation == rhs.generation
      && lhs.revision == rhs.revision
      && lhs.plan == rhs.plan
      && lhs.operationIdentifier == rhs.operationIdentifier
      && lhs.targetDeviceID == rhs.targetDeviceID
      && lhs.targetDeviceUID == rhs.targetDeviceUID
      && lhs.engineInstanceEpoch == rhs.engineInstanceEpoch
      && lhs.engineEpoch == rhs.engineEpoch
      && lhs.requiresConfigurationConfirmation == rhs.requiresConfigurationConfirmation
      && lhs.observedConfigurationConfirmation == rhs.observedConfigurationConfirmation
  }

  mutating func recordConfigurationChange(engineEpoch: UInt64) {
    revision &+= 1
    self.engineEpoch = engineEpoch
    observedConfigurationConfirmation = true
  }
}

private struct PendingPreparation {
  let plan: InputDeviceSessionPlan
  let resolvedRoute: ResolvedInputDevicePlan
  let operationIdentifier: UInt64?
  let completion: ((Bool) -> Void)?
}

private final class MemoryAudioCaptureOperation: AudioCaptureOperation {
  let identifier: UInt64
  let inputDevicePlan: InputDeviceSessionPlan
  private weak var capture: MemoryAudioCapture?

  init(identifier: UInt64, inputDevicePlan: InputDeviceSessionPlan, capture: MemoryAudioCapture) {
    self.identifier = identifier
    self.inputDevicePlan = inputDevicePlan
    self.capture = capture
  }

  func cancel() {
    capture?.cancel(operationIdentifier: identifier)
  }
}
