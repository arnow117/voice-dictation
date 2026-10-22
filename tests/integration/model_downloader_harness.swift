import Foundation

private struct FixtureResponse {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
}

private final class FixtureURLProtocol: URLProtocol {
  static var response = FixtureResponse(statusCode: 200, headers: [:], body: Data())

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "model-fixture.invalid"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let fixture = Self.response
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: fixture.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: fixture.headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !fixture.body.isEmpty {
      client?.urlProtocol(self, didLoad: fixture.body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

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

private func temporaryPartURL() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("shanshuo-downloader-harness-\(UUID().uuidString)", isDirectory: true)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("model.part")
}

private func run(
  response: FixtureResponse,
  existing: Data? = nil,
  expectedBytes: Int64 = 6
) -> (result: Result<ModelTransferKind, ModelDownloadError>, part: Data, range: String?) {
  let partURL = temporaryPartURL()
  defer { try? FileManager.default.removeItem(at: partURL.deletingLastPathComponent()) }
  if let existing {
    try! existing.write(to: partURL)
  }
  FixtureURLProtocol.response = response
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [FixtureURLProtocol.self]
  let downloader = URLSessionModelFileDownloader(configuration: configuration)
  var completed: Result<ModelTransferKind, ModelDownloadError>?
  let request = ModelDownloadRequest(
    url: URL(string: "https://model-fixture.invalid/model")!,
    partURL: partURL,
    expectedBytes: expectedBytes,
    resumeOffset: Int64(existing?.count ?? 0)
  )
  downloader.start(
    request,
    progress: { _ in },
    completion: { result in
      completed = result
    }
  )
  guard let result = waitForMain({ completed }) else {
    fputs("FAIL: downloader did not finish\n", stderr)
    exit(1)
  }
  return (result, (try? Data(contentsOf: partURL)) ?? Data(), nil)
}

@main
enum ModelDownloaderHarnessMain {
  static func main() {
    let full = Data("model\n".utf8)
    let resumed = run(
      response: FixtureResponse(
        statusCode: 206,
        headers: ["Content-Range": "bytes 2-5/6", "Content-Length": "4"],
        body: Data("del\n".utf8)
      ),
      existing: Data("mo".utf8)
    )
    check(resumed.result == .success(.resumed), "valid 206 must resume")
    check(resumed.part == full, "resumed response appends exactly the remaining bytes")

    let restarted = run(
      response: FixtureResponse(
        statusCode: 200,
        headers: ["Content-Length": "6"],
        body: full
      ),
      existing: Data("mo".utf8)
    )
    check(restarted.result == .success(.restarted), "200 after Range must restart")
    check(restarted.part == full, "Range-ignoring server truncates the part before writing")

    let invalidRange = run(
      response: FixtureResponse(
        statusCode: 206,
        headers: ["Content-Range": "bytes 1-5/6", "Content-Length": "5"],
        body: Data("del\n".utf8)
      ),
      existing: Data("mo".utf8)
    )
    check(invalidRange.result == .failure(.invalidContentRange), "mismatched 206 is rejected")

    let overlong = run(
      response: FixtureResponse(
        statusCode: 200,
        headers: ["Content-Length": "6"],
        body: Data("model\n!".utf8)
      )
    )
    check(overlong.result == .failure(.bodyTooLong), "overlong response body is rejected")

    let rangeNotSatisfiable = run(
      response: FixtureResponse(statusCode: 416, headers: [:], body: Data()),
      existing: full
    )
    check(
      rangeNotSatisfiable.result == .success(.rangeNotSatisfiable),
      "416 reaches manager verification instead of being treated as complete"
    )
    print("model downloader harness passed")
  }
}
