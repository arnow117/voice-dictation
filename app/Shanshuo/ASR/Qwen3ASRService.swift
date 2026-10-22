import Foundation
import ShanshuoCore

enum ASRServiceError: Error {
  case modelNotReady
}

protocol ASRRecognizing: AnyObject {
  var isReady: Bool { get }
  func load(completion: @escaping (Result<Void, Error>) -> Void)
  @discardableResult
  func transcribe(
    _ audio: CapturedAudio,
    completion: @escaping (Result<String, Error>) -> Void
  ) -> ASRTranscriptionOperation
  func unload()
}

protocol ASRTranscriptionOperation: AnyObject {
  func cancel()
}

protocol Qwen3Runtime: AnyObject {
  func transcribe(_ samples: [Float], sampleRate: Int, hotwords: [String]) -> String
}

extension Qwen3Recognizer: Qwen3Runtime {}

final class Qwen3ASRTranscriptionOperation: ASRTranscriptionOperation {
  private let lock = NSLock()
  private var cancelled = false
  private var samples: [Float]?

  init(samples: [Float]) {
    self.samples = samples
  }

  func cancel() {
    lock.lock()
    cancelled = true
    eraseSamplesLocked()
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  var bufferedSampleCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return samples?.count ?? 0
  }

  func takeSamplesIfActive() -> [Float]? {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else {
      return nil
    }
    let taken = samples
    samples = nil
    return taken
  }

  private func eraseSamplesLocked() {
    samples?.withUnsafeMutableBufferPointer { buffer in
      buffer.initialize(repeating: 0)
    }
    samples?.removeAll(keepingCapacity: false)
    samples = nil
  }
}

/// All Qwen runtime lifetime operations happen on this one serial user-initiated queue. sherpa-onnx
/// recognizers are not thread-safe, so the model is never created, decoded, or destroyed elsewhere.
final class Qwen3ASRService: ASRRecognizing, ModelRuntime {
  private let queue = DispatchQueue(label: "com.arnow117.shanshuo.asr", qos: .userInitiated)
  private let lifetimeLock = NSLock()
  private var lifetimeGeneration: UInt64 = 0
  private let legacyFiles: Qwen3ModelFiles?
  private let runtimeFactory: (Qwen3ModelFiles) throws -> Qwen3Runtime
  private var recognizer: Qwen3Runtime?
  private var ready = false

  init(files: Qwen3ModelFiles? = nil) {
    legacyFiles = files
    runtimeFactory = { files in
      try Qwen3Recognizer(files: files)
    }
  }

  init(
    files: Qwen3ModelFiles? = nil,
    runtimeFactory: @escaping (Qwen3ModelFiles) throws -> Qwen3Runtime
  ) {
    legacyFiles = files
    self.runtimeFactory = runtimeFactory
  }

  var isReady: Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    return ready
  }

  func load(completion: @escaping (Result<Void, Error>) -> Void) {
    guard let legacyFiles else {
      DispatchQueue.main.async {
        completion(.failure(ASRServiceError.modelNotReady))
      }
      return
    }
    load(files: legacyFiles, completion: completion)
  }

  /// The model manager calls this only after it has streamed, atomically promoted, and validated
  /// every pinned file. A generation guard prevents a load completed after delete/pause/repair
  /// from making the runtime ready again.
  func load(files: Qwen3ModelFiles, completion: @escaping (Result<Void, Error>) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let generation = beginLifetimeOperation()
    ready = false
    queue.async { [weak self] in
      guard let self else {
        return
      }
      guard self.isCurrentLifetimeOperation(generation) else {
        return
      }
      self.recognizer = nil
      let recognizerResult = Result {
        try self.runtimeFactory(files)
      }
      guard self.isCurrentLifetimeOperation(generation) else {
        return
      }
      if case .success(let recognizer) = recognizerResult {
        self.recognizer = recognizer
      }
      let result = recognizerResult.map { _ in () }
      DispatchQueue.main.async {
        guard self.isCurrentLifetimeOperation(generation) else {
          return
        }
        self.ready = result.isSuccess
        completion(result)
      }
    }
  }

  @discardableResult
  func transcribe(
    _ audio: CapturedAudio,
    completion: @escaping (Result<String, Error>) -> Void
  ) -> ASRTranscriptionOperation {
    let sampleRate = audio.sampleRate
    let operation = Qwen3ASRTranscriptionOperation(samples: audio.samples)
    let runtimeGeneration = currentLifetimeGeneration()
    queue.async { [weak self] in
      guard let self, let samples = operation.takeSamplesIfActive() else {
        return
      }
      defer {
        var mutableSamples = samples
        mutableSamples.withUnsafeMutableBufferPointer { buffer in
          buffer.initialize(repeating: 0)
        }
        mutableSamples.removeAll(keepingCapacity: false)
      }
      guard !operation.isCancelled, self.isCurrentLifetimeOperation(runtimeGeneration) else {
        return
      }
      guard let recognizer = self.recognizer else {
        DispatchQueue.main.async {
          guard !operation.isCancelled, self.isCurrentLifetimeOperation(runtimeGeneration) else {
            return
          }
          completion(.failure(ASRServiceError.modelNotReady))
        }
        return
      }
      let shouldContinue = {
        !operation.isCancelled && self.isCurrentLifetimeOperation(runtimeGeneration)
      }
      guard shouldContinue() else {
        return
      }
      let decoding = Qwen3ChunkDecoder.decode(
        samples: samples,
        sampleRate: sampleRate,
        shouldContinue: shouldContinue,
        decodeChunk: { chunk, sampleRate, hotwords in
          recognizer.transcribe(chunk, sampleRate: sampleRate, hotwords: hotwords)
        }
      )
      guard shouldContinue() else {
        return
      }
      DispatchQueue.main.async {
        guard !operation.isCancelled, self.isCurrentLifetimeOperation(runtimeGeneration) else {
          return
        }
        completion(.success(decoding.text))
      }
    }
    return operation
  }

  private func currentLifetimeGeneration() -> UInt64 {
    lifetimeLock.lock()
    defer { lifetimeLock.unlock() }
    return lifetimeGeneration
  }

  func unload() {
    unload(completion: {})
  }

  /// Completion runs on the main thread after the serial runtime queue has released the recognizer.
  /// Model deletion waits for this completion before touching the directory it mapped.
  func unload(completion: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    _ = beginLifetimeOperation()
    ready = false
    queue.async { [weak self] in
      self?.recognizer = nil
      DispatchQueue.main.async {
        completion()
      }
    }
  }

  private func beginLifetimeOperation() -> UInt64 {
    lifetimeLock.lock()
    lifetimeGeneration &+= 1
    let generation = lifetimeGeneration
    lifetimeLock.unlock()
    return generation
  }

  private func isCurrentLifetimeOperation(_ generation: UInt64) -> Bool {
    lifetimeLock.lock()
    defer { lifetimeLock.unlock() }
    return lifetimeGeneration == generation
  }
}

extension Result where Success == Void {
  fileprivate var isSuccess: Bool {
    if case .success = self {
      return true
    }
    return false
  }
}
