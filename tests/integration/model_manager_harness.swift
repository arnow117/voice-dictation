import CryptoKit
import Foundation

private let modelData = Data("model\n".utf8)
private let badData = Data("broken".utf8)

private enum TransferScript {
  case write(Data, ModelTransferKind)
  case writeAndHold(Data)
  case rangeNotSatisfiable
  case failure
}

private final class FakeDownloader: ModelFileDownloading {
  private struct ActiveTransfer {
    let request: ModelDownloadRequest
    let completion: (Result<ModelTransferKind, ModelDownloadError>) -> Void
  }

  var scripts: [TransferScript] = []
  private(set) var requests: [ModelDownloadRequest] = []
  private var activeTransfer: ActiveTransfer?

  func start(
    _ request: ModelDownloadRequest,
    progress: @escaping (Int64) -> Void,
    completion: @escaping (Result<ModelTransferKind, ModelDownloadError>) -> Void
  ) {
    requests.append(request)
    guard !scripts.isEmpty else {
      fputs("FAIL: unexpected transfer \(request.url)\n", stderr)
      exit(1)
    }
    let script = scripts.removeFirst()
    switch script {
    case .write(let data, let kind):
      write(data, to: request.partURL, append: kind == .resumed)
      progress(request.resumeOffset + Int64(data.count))
      DispatchQueue.main.async {
        completion(.success(kind))
      }
    case .writeAndHold(let data):
      write(data, to: request.partURL, append: request.resumeOffset > 0)
      progress(request.resumeOffset + Int64(data.count))
      activeTransfer = ActiveTransfer(request: request, completion: completion)
    case .rangeNotSatisfiable:
      DispatchQueue.main.async {
        completion(.success(.rangeNotSatisfiable))
      }
    case .failure:
      DispatchQueue.main.async {
        completion(.failure(.transport))
      }
    }
  }

  func cancel() {
    guard let activeTransfer else {
      return
    }
    self.activeTransfer = nil
    DispatchQueue.main.async {
      activeTransfer.completion(.failure(.transport))
    }
  }

  private func write(_ data: Data, to url: URL, append: Bool) {
    try! FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if append, let handle = FileHandle(forWritingAtPath: url.path) {
      try! handle.seekToEnd()
      try! handle.write(contentsOf: data)
      try! handle.close()
    } else {
      try! data.write(to: url)
    }
  }
}

private final class FakeRuntime: ModelRuntime {
  var holdLoad = false
  private(set) var loadCount = 0
  private(set) var unloadCount = 0
  private var heldLoadCompletion: ((Result<Void, Error>) -> Void)?

  func load(files: Qwen3ModelFiles, completion: @escaping (Result<Void, Error>) -> Void) {
    loadCount += 1
    if holdLoad {
      heldLoadCompletion = completion
    } else {
      DispatchQueue.main.async {
        completion(.success(()))
      }
    }
  }

  func unload(completion: @escaping () -> Void) {
    unloadCount += 1
    DispatchQueue.main.async(execute: completion)
  }

  func completeHeldLoad() {
    let completion = heldLoadCompletion
    heldLoadCompletion = nil
    completion?(.success(()))
  }
}

private func makeManifest() -> Qwen3ModelManifest {
  Qwen3ModelManifest(
    modelKey: "test-model",
    displayName: "Test model",
    repository: "owner/repo",
    revision: "fixed-revision",
    license: "Apache-2.0",
    totalBytes: Int64(modelData.count),
    sources: [
      ModelDownloadSource(
        id: "primary", name: "Primary", baseURL: URL(string: "https://test.invalid")!),
      ModelDownloadSource(
        id: "mirror", name: "Mirror", baseURL: URL(string: "https://mirror.invalid")!),
    ],
    files: [
      Qwen3ModelManifest.File(
        path: "tokenizer/model.bin",
        size: Int64(modelData.count),
        sha256: SHA256.hash(data: modelData).map { String(format: "%02x", $0) }.joined()
      )
    ]
  )
}

private func waitForMain(_ condition: @escaping () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(2)
  while !condition(), Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return condition()
}

private func statusIsRepairable(_ status: ModelManagerStatus) -> Bool {
  if case .repairRequired = status {
    return true
  }
  return false
}

private func statusIsReady(_ status: ModelManagerStatus, readOnly: Bool? = nil) -> Bool {
  guard case .ready(_, let isReadOnly) = status else {
    return false
  }
  return readOnly.map { $0 == isReadOnly } ?? true
}

private func statusIsFailed(_ status: ModelManagerStatus) -> Bool {
  if case .failed = status {
    return true
  }
  return false
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func temporaryDirectory(_ name: String) -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(
      "shanshuo-model-harness-\(name)-\(UUID().uuidString)", isDirectory: true)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func makeManager(
  root: URL,
  downloader: FakeDownloader,
  runtime: FakeRuntime,
  seed: URL? = nil
) -> ModelManager {
  ModelManager(
    manifest: makeManifest(),
    ownedDirectory: root.appendingPathComponent("owned", isDirectory: true),
    readOnlySeedDirectory: seed,
    runtime: runtime,
    downloader: downloader
  )
}

private func writeCompleteModel(to directory: URL) {
  let modelURL = directory.appendingPathComponent("tokenizer/model.bin")
  try! FileManager.default.createDirectory(
    at: modelURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try! modelData.write(to: modelURL)
}

private func modelURL(in directory: URL, isPart: Bool = false) -> URL {
  let url = directory.appendingPathComponent("tokenizer/model.bin")
  return isPart ? url.appendingPathExtension("part") : url
}

private func testFreshDownloadAndReadOnlySeedProtection() {
  let root = temporaryDirectory("fresh")
  defer { try? FileManager.default.removeItem(at: root) }
  let downloader = FakeDownloader()
  downloader.scripts = [.write(modelData, .fresh)]
  let runtime = FakeRuntime()
  let manager = makeManager(root: root, downloader: downloader, runtime: runtime)
  manager.bootstrap()
  check(waitForMain { statusIsRepairable(manager.status) }, "missing canonical model needs repair")
  manager.download(preferredSource: nil)
  check(waitForMain { statusIsReady(manager.status) }, "all verified files must load before ready")
  check(runtime.loadCount == 1, "runtime loads after verification")
  check(
    ModelFileVerifier.validateFile(
      modelURL(in: root.appendingPathComponent("owned", isDirectory: true)),
      expected: makeManifest().files[0]
    ),
    "downloaded model is atomically promoted only after verification"
  )

  let seed = root.appendingPathComponent("seed", isDirectory: true)
  writeCompleteModel(to: seed)
  let seedDownloader = FakeDownloader()
  let seedRuntime = FakeRuntime()
  let seedManager = makeManager(
    root: root.appendingPathComponent("seed-manager"), downloader: seedDownloader,
    runtime: seedRuntime, seed: seed)
  seedManager.bootstrap()
  check(
    waitForMain { statusIsReady(seedManager.status, readOnly: true) },
    "valid developer seed is read-only")
  seedManager.deleteOwnedModel()
  check(
    waitForMain { statusIsReady(seedManager.status, readOnly: true) },
    "delete returns to valid seed")
  check(
    FileManager.default.fileExists(atPath: modelURL(in: seed).path),
    "delete never removes a developer seed")
}

private func testPauseResumeAnd416() {
  let root = temporaryDirectory("resume")
  defer { try? FileManager.default.removeItem(at: root) }
  let downloader = FakeDownloader()
  downloader.scripts = [.writeAndHold(Data("mo".utf8)), .write(Data("del\n".utf8), .resumed)]
  let runtime = FakeRuntime()
  let manager = makeManager(root: root, downloader: downloader, runtime: runtime)
  manager.bootstrap()
  check(waitForMain { statusIsRepairable(manager.status) }, "fresh root is repairable")
  manager.download(preferredSource: nil)
  check(waitForMain { downloader.requests.count == 1 }, "first transfer begins")
  manager.pause()
  check(waitForMain { manager.status == .paused }, "pause waits for active transfer cancellation")
  manager.download(preferredSource: manager.manifest.sources[1])
  check(waitForMain { statusIsReady(manager.status) }, "resume produces a verified ready model")
  check(downloader.requests[1].resumeOffset == 2, "resume uses the retained partial length")
  check(
    downloader.requests[1].url.host == "mirror.invalid", "source switch resumes the same revision")

  let fallbackRoot = temporaryDirectory("fallback")
  defer { try? FileManager.default.removeItem(at: fallbackRoot) }
  let fallbackDownloader = FakeDownloader()
  fallbackDownloader.scripts = [.failure, .write(modelData, .fresh)]
  let fallbackRuntime = FakeRuntime()
  let fallbackManager = makeManager(
    root: fallbackRoot,
    downloader: fallbackDownloader,
    runtime: fallbackRuntime
  )
  fallbackManager.bootstrap()
  check(waitForMain { statusIsRepairable(fallbackManager.status) }, "fallback root is repairable")
  fallbackManager.download(preferredSource: nil)
  check(waitForMain { statusIsReady(fallbackManager.status) }, "failed primary switches to mirror")
  check(
    fallbackDownloader.requests[1].url.host == "mirror.invalid", "fallback uses configured mirror")

  let rangeRoot = temporaryDirectory("range")
  defer { try? FileManager.default.removeItem(at: rangeRoot) }
  let rangeDownloader = FakeDownloader()
  rangeDownloader.scripts = [.rangeNotSatisfiable]
  let rangeRuntime = FakeRuntime()
  let rangeManager = makeManager(
    root: rangeRoot, downloader: rangeDownloader, runtime: rangeRuntime)
  let completePart = modelURL(
    in: rangeRoot.appendingPathComponent("owned", isDirectory: true),
    isPart: true
  )
  try! FileManager.default.createDirectory(
    at: completePart.deletingLastPathComponent(), withIntermediateDirectories: true)
  try! modelData.write(to: completePart)
  rangeManager.bootstrap()
  check(
    waitForMain { statusIsRepairable(rangeManager.status) }, "partial file alone is never ready")
  rangeManager.download(preferredSource: nil)
  check(
    waitForMain { statusIsReady(rangeManager.status) },
    "416 accepts only a complete verified partial")

  let incompleteRoot = temporaryDirectory("incomplete-range")
  defer { try? FileManager.default.removeItem(at: incompleteRoot) }
  let incompleteDownloader = FakeDownloader()
  incompleteDownloader.scripts = [.rangeNotSatisfiable, .write(modelData, .fresh)]
  let incompleteRuntime = FakeRuntime()
  let incompleteManager = makeManager(
    root: incompleteRoot,
    downloader: incompleteDownloader,
    runtime: incompleteRuntime
  )
  let incompletePart = modelURL(
    in: incompleteRoot.appendingPathComponent("owned", isDirectory: true),
    isPart: true
  )
  try! FileManager.default.createDirectory(
    at: incompletePart.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try! Data("mo".utf8).write(to: incompletePart)
  incompleteManager.bootstrap()
  check(
    waitForMain { statusIsRepairable(incompleteManager.status) }, "incomplete part is repairable")
  incompleteManager.download(preferredSource: nil)
  check(
    waitForMain { statusIsReady(incompleteManager.status) }, "incomplete 416 must restart download")
  check(
    incompleteDownloader.requests.map(\.resumeOffset) == [2, 0],
    "incomplete 416 removes the part and restarts from zero"
  )
}

private func testChecksumFailureAndStaleCallbacks() {
  let root = temporaryDirectory("stale")
  defer { try? FileManager.default.removeItem(at: root) }
  let downloader = FakeDownloader()
  downloader.scripts = [.write(badData, .fresh), .write(badData, .fresh)]
  let runtime = FakeRuntime()
  let manager = makeManager(root: root, downloader: downloader, runtime: runtime)
  manager.bootstrap()
  check(waitForMain { statusIsRepairable(manager.status) }, "missing root requires download")
  manager.download(preferredSource: nil)
  check(
    waitForMain { statusIsFailed(manager.status) },
    "two checksum failures must not advertise readiness")
  check(runtime.loadCount == 0, "corrupt data never reaches runtime load")

  let staleRoot = temporaryDirectory("stale-load")
  defer { try? FileManager.default.removeItem(at: staleRoot) }
  let owned = staleRoot.appendingPathComponent("owned", isDirectory: true)
  writeCompleteModel(to: owned)
  let staleDownloader = FakeDownloader()
  let staleRuntime = FakeRuntime()
  staleRuntime.holdLoad = true
  let staleManager = makeManager(
    root: staleRoot, downloader: staleDownloader, runtime: staleRuntime)
  staleManager.bootstrap()
  check(
    waitForMain { staleRuntime.loadCount == 1 }, "valid installed model attempts a runtime load")
  staleManager.deleteOwnedModel()
  staleRuntime.completeHeldLoad()
  check(
    waitForMain { statusIsRepairable(staleManager.status) },
    "late load callback cannot revive deleted model")
  check(
    !FileManager.default.fileExists(atPath: owned.path),
    "deletion waits for unload then removes only owned files")
}

@main
enum ModelManagerHarnessMain {
  static func main() {
    testFreshDownloadAndReadOnlySeedProtection()
    testPauseResumeAnd416()
    testChecksumFailureAndStaleCallbacks()
    print("model manager harness passed")
  }
}
