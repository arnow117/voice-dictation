import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func waitForMain<T>(_ value: @escaping () -> T?) -> T? {
  let deadline = Date().addingTimeInterval(2)
  while Date() < deadline {
    if let result = value() {
      return result
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return value()
}

private func run(path: String, existing: Data? = nil) -> (
  Result<ModelTransferKind, ModelDownloadError>, Data
) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("shanshuo-downloader-http-\(UUID().uuidString)", isDirectory: true)
  let partURL = directory.appendingPathComponent("model.part")
  defer { try? FileManager.default.removeItem(at: directory) }
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  if let existing {
    try! existing.write(to: partURL)
  }
  let base = URL(string: ProcessInfo.processInfo.environment["SHANSHUO_MODEL_FIXTURE_BASE_URL"]!)!
  let request = ModelDownloadRequest(
    url: base.appendingPathComponent(path),
    partURL: partURL,
    expectedBytes: 6,
    resumeOffset: Int64(existing?.count ?? 0)
  )
  let downloader = URLSessionModelFileDownloader()
  var completed: Result<ModelTransferKind, ModelDownloadError>?
  downloader.start(
    request,
    progress: { _ in },
    completion: { result in
      completed = result
    }
  )
  guard let result = waitForMain({ completed }) else {
    fputs("FAIL: local HTTP downloader did not finish\n", stderr)
    exit(1)
  }
  return (result, (try? Data(contentsOf: partURL)) ?? Data())
}

@main
enum ModelDownloaderHTTPHarnessMain {
  static func main() {
    let full = Data("model\n".utf8)
    let resume = run(path: "resume", existing: Data("mo".utf8))
    check(resume.0 == .success(.resumed), "local HTTP 206 resumes")
    check(resume.1 == full, "local HTTP 206 appends only the remainder")

    let restart = run(path: "restart", existing: Data("mo".utf8))
    check(restart.0 == .success(.restarted), "local HTTP 200 restarts a Range request")
    check(restart.1 == full, "local HTTP 200 truncates stale partial data")

    let invalidRange = run(path: "bad-range", existing: Data("mo".utf8)).0
    if invalidRange != .failure(.invalidContentRange) {
      fputs("unexpected malformed-range result: \(String(describing: invalidRange))\n", stderr)
    }
    check(invalidRange == .failure(.invalidContentRange), "local HTTP malformed 206 is rejected")
    check(
      run(path: "overlong").0 == .failure(.bodyTooLong),
      "local HTTP overlong body is rejected"
    )
    check(
      run(path: "range-416", existing: full).0 == .success(.rangeNotSatisfiable),
      "local HTTP 416 defers completion to model verification"
    )
    print("model downloader local HTTP harness passed")
  }
}
