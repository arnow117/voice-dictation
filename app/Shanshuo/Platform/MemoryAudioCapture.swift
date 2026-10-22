import AVFoundation
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

  private let engine = AVAudioEngine()
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

  init(engineEvents: AudioEngineEventObserving = SystemAudioEngineEventSource()) {
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
    let operation = MemoryAudioCaptureOperation(identifier: identifier, capture: self)
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

private final class MemoryAudioCaptureOperation: AudioCaptureOperation {
  let identifier: UInt64
  private weak var capture: MemoryAudioCapture?

  init(identifier: UInt64, capture: MemoryAudioCapture) {
    self.identifier = identifier
    self.capture = capture
  }

  func cancel() {
    capture?.cancel(operationIdentifier: identifier)
  }
}
