import Foundation

// Minimal test-only stand-ins make the production service compile without the sherpa C bridge.
// The harness injects FakeRuntime, so Qwen3Recognizer is never instantiated.
struct Qwen3ModelFiles {}

final class Qwen3Recognizer {
  init(files: Qwen3ModelFiles) throws {}

  func transcribe(_ samples: [Float], sampleRate: Int, hotwords: [String]) -> String {
    "unused"
  }
}

protocol ModelRuntime: AnyObject {
  func load(files: Qwen3ModelFiles, completion: @escaping (Result<Void, Error>) -> Void)
  func unload(completion: @escaping () -> Void)
}

struct CapturedAudio {
  var samples: [Float]
  let sampleRate: Int
  let duration: TimeInterval
}

private final class FakeRuntime: Qwen3Runtime {
  private let lock = NSLock()
  private let firstDecodeStarted = DispatchSemaphore(value: 0)
  private let releaseFirstDecode = DispatchSemaphore(value: 0)
  private var blocksFirstDecode = true
  private(set) var decodeCount = 0

  func transcribe(_ samples: [Float], sampleRate: Int, hotwords: [String]) -> String {
    lock.lock()
    decodeCount += 1
    let callNumber = decodeCount
    let shouldBlock = blocksFirstDecode
    if shouldBlock {
      blocksFirstDecode = false
    }
    lock.unlock()

    if shouldBlock {
      firstDecodeStarted.signal()
      _ = releaseFirstDecode.wait(timeout: .now() + 2)
    }
    return "chunk\(callNumber)"
  }

  func waitForFirstDecode() -> Bool {
    firstDecodeStarted.wait(timeout: .now() + 2) == .success
  }

  func releaseFirst() {
    releaseFirstDecode.signal()
  }

  func decodedChunks() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return decodeCount
  }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func waitForMain(_ condition: @escaping () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(2)
  while !condition(), Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return condition()
}

private func audibleAudio(chunks: Int) -> CapturedAudio {
  let sampleRate = 100
  let samplesPerChunk = sampleRate * 20
  let samples = Array(repeating: Float(0.1), count: chunks * samplesPerChunk)
  return CapturedAudio(
    samples: samples,
    sampleRate: sampleRate,
    duration: TimeInterval(chunks * 20)
  )
}

@main
enum ASRCancellationHarnessMain {
  static func main() {
    let runtime = FakeRuntime()
    let service = Qwen3ASRService(files: nil) { _ in runtime }
    var loadComplete = false
    service.load(files: Qwen3ModelFiles()) { result in
      if case .success = result {
        loadComplete = true
      }
    }
    check(waitForMain { loadComplete }, "injected runtime must load")

    var staleResultDelivered = false
    let firstOperation = service.transcribe(audibleAudio(chunks: 3)) { _ in
      staleResultDelivered = true
    }
    check(runtime.waitForFirstDecode(), "first chunk must start before cancellation")

    // A queued operation canceled before the serial queue reaches it must never decode.
    let queuedOperation = service.transcribe(audibleAudio(chunks: 1)) { _ in
      staleResultDelivered = true
    }
    queuedOperation.cancel()
    let queuedTestOperation = queuedOperation as? Qwen3ASRTranscriptionOperation
    check(
      queuedTestOperation?.bufferedSampleCount == 0,
      "cancelling a queued request must erase its retained samples"
    )
    firstOperation.cancel()
    runtime.releaseFirst()
    check(waitForMain { runtime.decodedChunks() == 1 }, "the in-flight chunk may finish")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check(runtime.decodedChunks() == 1, "cancellation must skip later and queued chunks")
    check(!staleResultDelivered, "cancelled work must not deliver a result")

    var shortResult: String?
    _ = service.transcribe(audibleAudio(chunks: 1)) { result in
      if case .success(let text) = result {
        shortResult = text
      }
    }
    check(waitForMain { shortResult != nil }, "a short request must run after cancelled work")
    check(shortResult == "chunk2", "the next request must use the released serial runtime")

    var unloadComplete = false
    service.unload {
      check(runtime.decodedChunks() == 2, "unload waits behind existing runtime use")
      unloadComplete = true
    }
    check(waitForMain { unloadComplete }, "unload completion must follow runtime release")
    print("ASR cancellation harness passed")
  }
}
