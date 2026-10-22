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

  private let engine: AVAudioEngine
  private let inputDeviceConfigurator: InputDeviceConfiguring
  private let engineQueue = DispatchQueue(
    label: "com.arnow117.shanshuo.audio-engine",
    qos: .userInitiated
  )
  private let stateLock = NSLock()
  private var converter: AVAudioConverter?
  private var samples: [Float] = []
  private var levelHandler: ((Float) -> Void)?
  private var activeOperationIdentifier: UInt64?
  private weak var activeOperation: MemoryAudioCaptureOperation?
  private var nextOperationIdentifier: UInt64 = 0
  private var isRunning = false
  private var cachedAvailability = false
  private var tapIsInstalled = false
  private var engineEventObservation: AudioEngineEventObservation?
  private var requestedInputDeviceUID: String?

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
    inputDeviceConfigurator: InputDeviceConfiguring? = nil
  ) {
    self.engine = engine
    self.inputDeviceConfigurator =
      inputDeviceConfigurator ?? EngineInputDeviceConfigurator(inputNode: engine.inputNode)
    engineEventObservation = engineEvents.observe(engine: engine) { [weak self] in
      self?.handleEngineConfigurationChange()
    }
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
      stateLock.unlock()
    }
  }

  func prepare() {
    engineQueue.async { [weak self] in
      guard let self else {
        return
      }
      self.engine.prepare()
      self.updateAvailabilityOnEngineQueue()
    }
  }

  @discardableResult
  func start(
    onLevel: @escaping (Float) -> Void,
    completion: @escaping (AudioCaptureOperation, Result<Void, Error>) -> Void
  ) -> AudioCaptureOperation {
    let operation = makeOperation()
    engineQueue.async { [weak self, weak operation] in
      guard let self, let operation else {
        return
      }
      self.startOnEngineQueue(operation, onLevel: onLevel, completion: completion)
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
    engineQueue.async { [weak self, weak operation] in
      guard let self, let operation else {
        return
      }
      let audio = self.stopOnEngineQueue(operation)
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

    stopEngineOnEngineQueue()
    guard isCurrent(operation) else {
      return
    }

    guard configureInputDeviceForNewOperationOnEngineQueue(operation) else {
      updateAvailabilityOnEngineQueue()
      completeStart(
        operation, result: .failure(AudioCaptureError.unavailable), completion: completion)
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
      updateAvailabilityOnEngineQueue()
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
      [weak self, weak operation] buffer, _ in
      guard let self, let operation else {
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
      updateAvailabilityOnEngineQueue()
      completeStart(
        operation, result: .failure(AudioCaptureError.failedToStart), completion: completion)
      return
    }

    updateAvailabilityOnEngineQueue()
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
      self?.stopEngineOnEngineQueue()
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

  private func handleEngineConfigurationChange() {
    engineQueue.async { [weak self] in
      self?.interruptActiveOperationOnEngineQueue()
    }
  }

  private func interruptActiveOperationOnEngineQueue() {
    let interruptedOperation = invalidateActiveOperation()
    stopEngineOnEngineQueue()
    updateAvailabilityOnEngineQueue()

    guard let interruptedOperation else {
      return
    }
    let handler = onInterruption
    DispatchQueue.main.async {
      handler?(interruptedOperation)
    }
  }

  private func updateAvailabilityOnEngineQueue() {
    let format = engine.inputNode.outputFormat(forBus: 0)
    stateLock.lock()
    cachedAvailability = format.sampleRate > 0 && format.channelCount > 0
    stateLock.unlock()
  }

  /// Input choice is resolved only at the beginning of a new capture. Updating a preference while
  /// recording never moves an active engine to another microphone; a missing selected UID simply
  /// makes the next request unavailable until the user chooses another input or follows default.
  private func configureInputDeviceForNewOperationOnEngineQueue(
    _ operation: MemoryAudioCaptureOperation
  ) -> Bool {
    InputDeviceSessionConfigurator.configure(
      plan: operation.inputDevicePlan,
      using: inputDeviceConfigurator
    )
  }

  private func isCurrent(_ operation: MemoryAudioCaptureOperation) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return activeOperationIdentifier == operation.identifier
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

  func defaultInputDeviceID() -> AudioDeviceID? {
    SystemInputDevices.defaultInputDeviceID()
  }

  func apply(deviceID: AudioDeviceID) throws {
    try inputNode.auAudioUnit.setDeviceID(deviceID)
  }
}

private enum SystemInputDevices {
  static func available() -> [InputDevice] {
    allDeviceIDs().compactMap { deviceID in
      guard hasInputStreams(deviceID),
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
    }
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
