import Foundation
import ShanshuoCore

enum ASRServiceError: Error {
  case modelNotReady
}

protocol ASRRecognizing: AnyObject {
  var isReady: Bool { get }
  func load(completion: @escaping (Result<Void, Error>) -> Void)
  func transcribe(_ audio: CapturedAudio, completion: @escaping (Result<String, Error>) -> Void)
  func unload()
}

/// All Qwen runtime lifetime operations happen on this one serial user-initiated queue. sherpa-onnx
/// recognizers are not thread-safe, so the model is never created, decoded, or destroyed elsewhere.
final class Qwen3ASRService: ASRRecognizing {
  private let queue = DispatchQueue(label: "com.arnow117.shanshuo.asr", qos: .userInitiated)
  private let files: Qwen3ModelFiles
  private var recognizer: Qwen3Recognizer?
  private var ready = false

  init(files: Qwen3ModelFiles) {
    self.files = files
  }

  var isReady: Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    return ready
  }

  func load(completion: @escaping (Result<Void, Error>) -> Void) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let result = Result {
        let recognizer = try Qwen3Recognizer(files: self.files)
        self.recognizer = recognizer
      }
      DispatchQueue.main.async {
        self.ready = result.isSuccess
        completion(result)
      }
    }
  }

  func transcribe(_ audio: CapturedAudio, completion: @escaping (Result<String, Error>) -> Void) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      guard let recognizer = self.recognizer else {
        DispatchQueue.main.async {
          completion(.failure(ASRServiceError.modelNotReady))
        }
        return
      }

      var samples = audio.samples
      defer {
        samples.withUnsafeMutableBufferPointer { buffer in
          buffer.initialize(repeating: 0)
        }
        samples.removeAll(keepingCapacity: false)
      }

      let decoding = Qwen3ChunkDecoder.decode(
        samples: samples,
        sampleRate: audio.sampleRate,
        recognizer: recognizer
      )
      DispatchQueue.main.async {
        completion(.success(decoding.text))
      }
    }
  }

  func unload() {
    queue.async { [weak self] in
      self?.recognizer = nil
      DispatchQueue.main.async {
        self?.ready = false
      }
    }
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
