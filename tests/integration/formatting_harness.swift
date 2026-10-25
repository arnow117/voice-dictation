import Foundation
import SQLite3
import ShanshuoCore

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func waitForMain<T>(
  timeout: TimeInterval = 1,
  _ value: @escaping () -> T?
) -> T? {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if let result = value() {
      return result
    }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return value()
}

private enum FixtureBehavior {
  case response(status: Int, body: Data)
  case redirect
  case hold
  case oversized
}

private final class FixtureObservation {
  private let lock = NSLock()
  private var requestCount = 0

  func reset() {
    lock.lock()
    requestCount = 0
    lock.unlock()
  }

  func recordRequest() {
    lock.lock()
    requestCount += 1
    lock.unlock()
  }

  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requestCount
  }
}

private let fixtureObservation = FixtureObservation()

private final class FormattingURLProtocol: URLProtocol {
  static var behavior: FixtureBehavior = .hold
  static var heldProtocol: FormattingURLProtocol?

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "api.minimaxi.com"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    fixtureObservation.recordRequest()
    switch Self.behavior {
    case .response(let status, let body):
      send(status: status, body: body)
    case .redirect:
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": "https://evil.example/elsewhere"]
      )!
      let redirect = URLRequest(url: URL(string: "https://evil.example/elsewhere")!)
      client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
    case .hold:
      Self.heldProtocol = self
    case .oversized:
      send(status: 200, body: Data(repeating: 65, count: FormattingRules.maximumResponseBytes + 1))
    }
  }

  override func stopLoading() {}

  func send(status: Int, body: Data) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !body.isEmpty {
      client?.urlProtocol(self, didLoad: body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }
}

private final class TestScheduler: FormattingScheduling {
  private final class Token: FormattingDeadline {
    var isCancelled = false
    func cancel() { isCancelled = true }
  }

  var nowValue: TimeInterval = 0
  private var scheduled: [(Token, () -> Void)] = []

  func now() -> TimeInterval { nowValue }

  func schedule(after: TimeInterval, _ action: @escaping () -> Void) -> FormattingDeadline {
    let token = Token()
    scheduled.append((token, action))
    return token
  }

  func fireDeadlines() {
    let pending = scheduled
    scheduled.removeAll()
    for (token, action) in pending where !token.isCancelled {
      action()
    }
  }
}

private func jsonData(_ object: [String: Any]) -> Data {
  try! JSONSerialization.data(withJSONObject: object)
}

private func successfulResponse(text: String) -> Data {
  jsonData([
    "type": "message",
    "stop_reason": "end_turn",
    "content": [["type": "text", "text": text]],
  ])
}

private func configuration(
  model: FormattingModel = .flash,
  endpoint: FormattingEndpoint = .domestic,
  reference: String = "fixture-reference"
) -> FormattingConfigurationSnapshot {
  FormattingConfigurationSnapshot(
    enabled: false,
    model: model,
    endpoint: endpoint,
    credential: FormattingCredentialDescriptor(reference: reference, hint: "••••test"),
    consentVersion: nil,
    revision: 1,
    testGeneration: 0
  )
}

private func runFormatting(
  formatter: MiniMaxAPIFormatter,
  request: FormattingRequest = FormattingRequest(originalText: "第一买牛奶", dictionaryTerms: []),
  configuration: FormattingConfigurationSnapshot = configuration(),
  authorizeSend: @escaping () -> Bool = { true }
) -> FormattingResult? {
  var result: FormattingResult?
  _ = formatter.format(
    request: request,
    configuration: configuration,
    authorizeSend: authorizeSend
  ) { completion in
    result = completion
  }
  return waitForMain { result }
}

private func writeCCSwitchFixture(rows: [String]) -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "shanshuo-cc-switch-\(UUID().uuidString).sqlite"
  )
  var database: OpaquePointer?
  check(sqlite3_open(url.path, &database) == SQLITE_OK, "fixture database opens")
  defer { sqlite3_close(database) }
  check(
    sqlite3_exec(
      database,
      "CREATE TABLE providers (name TEXT NOT NULL, settings_config TEXT NOT NULL);",
      nil,
      nil,
      nil
    ) == SQLITE_OK,
    "fixture provider table exists"
  )
  for row in rows {
    var statement: OpaquePointer?
    check(
      sqlite3_prepare_v2(database, "INSERT INTO providers VALUES ('MiniMax', ?);", -1, &statement, nil)
        == SQLITE_OK,
      "fixture insert prepares"
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, row, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    check(sqlite3_step(statement) == SQLITE_DONE, "fixture provider row inserts")
  }
  return url
}

@main
enum FormattingHarness {
  static func main() {
    let credentials = FormattingCredentialStore()
    var descriptor: FormattingCredentialDescriptor
    do {
      descriptor = try credentials.save("synthetic-provider-token")
      let storedCredential = try credentials.read(reference: descriptor.reference)
      check(storedCredential == "synthetic-provider-token", "a process-memory credential reads")
      credentials.remove(reference: descriptor.reference)
      check(
        (try? credentials.read(reference: descriptor.reference)) == nil,
        "clearing a process-memory credential makes it unavailable"
      )
      descriptor = try credentials.save("synthetic-provider-token")
    } catch {
      check(false, "the process-memory credential cache supports save, read, and clear")
      return
    }

    let defaults = UserDefaults(suiteName: "shanshuo-formatting-\(UUID().uuidString)")!
    let store = FormattingConfigurationStore(defaults: defaults)
    check(!store.snapshot().enabled, "formatting defaults to disabled")
    let initial = store.replaceCredential(
      descriptor,
      model: .flash,
      endpoint: .domestic
    )
    let test = store.beginConnectionTest()
    check(test != nil, "configured credentials can begin a connection test")
    _ = store.replaceCredential(descriptor, model: .m3, endpoint: .domestic)
    check(!store.recordConnectionTestSuccess(test!), "a stale test cannot succeed after model change")
    check(!store.enable(afterSuccessfulTest: test!, consentVersion: 1), "a stale test cannot enable")
    let currentTest = store.beginConnectionTest()!
    check(store.recordConnectionTestSuccess(currentTest), "current connection test can be recorded")
    check(store.enable(afterSuccessfulTest: currentTest, consentVersion: 1), "current test plus consent enables")
    let disabled = store.disable()
    check(!disabled.enabled && disabled.revision > initial.revision, "disable invalidates existing snapshots")
    let reloaded = FormattingConfigurationStore(defaults: defaults)
    check(!reloaded.snapshot().enabled, "a new process starts with formatting disabled")
    check(reloaded.snapshot().credential == nil, "a new process discards an old credential reference")
    check(reloaded.beginConnectionTest() == nil, "a new process discards a prior connection test")

    let settings = """
      {"env":{"ANTHROPIC_BASE_URL":"https://api.minimaxi.com/anthropic","ANTHROPIC_MODEL":"MiniMax-M3","ANTHROPIC_AUTH_TOKEN":"fixture-token"}}
      """
    let fixtureDB = writeCCSwitchFixture(rows: [settings])
    defer { try? FileManager.default.removeItem(at: fixtureDB) }
    let before = try! Data(contentsOf: fixtureDB)
    let imported = try! CCSwitchMiniMaxImporter().readCredential(from: fixtureDB)
    let after = try! Data(contentsOf: fixtureDB)
    check(imported.endpoint == .domestic, "importer keeps the configured domestic endpoint")
    check(imported.sourceModel == .m3, "importer reads the configured MiniMax M3 model")
    check(before == after, "importer leaves the SQLite fixture unchanged")
    let duplicateDB = writeCCSwitchFixture(rows: [settings, settings])
    defer { try? FileManager.default.removeItem(at: duplicateDB) }
    check(
      (try? CCSwitchMiniMaxImporter().readCredential(from: duplicateDB)) == nil,
      "multiple MiniMax providers fail explicitly"
    )

    let scheduler = TestScheduler()
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [FormattingURLProtocol.self]
    fixtureObservation.reset()
    FormattingURLProtocol.behavior = .response(status: 200, body: successfulResponse(text: "1. 买牛奶"))
    let formatter = MiniMaxAPIFormatter(
      credentialStore: credentials,
      sessionConfiguration: sessionConfiguration,
      scheduler: scheduler
    )
    let success = runFormatting(
      formatter: formatter,
      configuration: configuration(reference: descriptor.reference)
    )
    check(
      success == .formatted("1. 买牛奶"),
      "valid text block completes formatting (received \(String(describing: success)))"
    )
    check(fixtureObservation.count() > 0, "URLProtocol observes the production request")

    var publicEvaluationRawTexts: [String] = []
    let publicEvaluationFormatter = MiniMaxAPIFormatter(
      credentialStore: credentials,
      sessionConfiguration: sessionConfiguration,
      scheduler: scheduler,
      publicEvaluationRawTextObserver: { publicEvaluationRawTexts.append($0) }
    )
    FormattingURLProtocol.behavior = .response(
      status: 200,
      body: successfulResponse(text: "1. 买牛奶")
    )
    check(
      runFormatting(
        formatter: publicEvaluationFormatter,
        configuration: configuration(reference: descriptor.reference)
      ) == .formatted("1. 买牛奶"),
      "the evaluation seam still uses the production formatter result"
    )
    check(
      publicEvaluationRawTexts == ["1. 买牛奶"],
      "the explicit public evaluation seam receives visible text without exposing thinking or headers"
    )

    FormattingURLProtocol.behavior = .response(status: 200, body: successfulResponse(text: "第一，买牛奶。"))
    let m3 = runFormatting(
      formatter: formatter,
      configuration: configuration(model: .m3, reference: descriptor.reference)
    )
    check(m3 == .formatted("第一，买牛奶。"), "M3 formats a complete response")

    let expectedFailures: [(Int, FormattingFallbackReason)] = [
      (401, .authorizationFailed),
      (402, .paymentRequired),
      (429, .rateLimited),
    ]
    for (status, reason) in expectedFailures {
      FormattingURLProtocol.behavior = .response(status: status, body: Data())
      check(
        runFormatting(formatter: formatter, configuration: configuration(reference: descriptor.reference))
          == .fallback(original: "第一买牛奶", reason: reason),
        "HTTP \(status) has a fixed fallback"
      )
    }

    FormattingURLProtocol.behavior = .response(
      status: 200,
      body: jsonData(["type": "error", "error": ["type": "rate_limit_error"]])
    )
    check(
      runFormatting(formatter: formatter, configuration: configuration(reference: descriptor.reference))
        == .fallback(original: "第一买牛奶", reason: .providerRejected),
      "HTTP 200 provider error payload does not format"
    )

    let invalidResponseBodies: [(Data, String)] = [
      (
        jsonData([
          "type": "message",
          "stop_reason": "end_turn",
          "content": [["type": "tool_use", "name": "send_email"]],
        ]),
        "tool responses"
      ),
      (
        jsonData([
          "type": "message",
          "stop_reason": "max_tokens",
          "content": [["type": "text", "text": "未完成"]],
        ]),
        "truncated responses"
      ),
      (
        jsonData([
          "type": "message",
          "stop_reason": "end_turn",
          "content": [["type": "text", "text": "   "]],
        ]),
        "empty text responses"
      ),
    ]
    for (body, description) in invalidResponseBodies {
      FormattingURLProtocol.behavior = .response(status: 200, body: body)
      check(
        runFormatting(formatter: formatter, configuration: configuration(reference: descriptor.reference))
          == .fallback(original: "第一买牛奶", reason: .invalidResponse),
        "\(description) have a fixed invalid-response fallback"
      )
    }

    FormattingURLProtocol.behavior = .response(
      status: 200,
      body: successfulResponse(text: "主题：请假申请")
    )
    let instruction = FormattingRequest(originalText: "帮我写一封请假邮件", dictionaryTerms: [])
    check(
      runFormatting(
        formatter: formatter,
        request: instruction,
        configuration: configuration(reference: descriptor.reference)
      ) == .fallback(original: instruction.originalText, reason: .fidelityRejected),
      "answer-like output falls back to original text"
    )

    FormattingURLProtocol.behavior = .redirect
    check(
      runFormatting(formatter: formatter, configuration: configuration(reference: descriptor.reference))
        == .fallback(original: "第一买牛奶", reason: .redirected),
      "redirects are rejected"
    )

    FormattingURLProtocol.behavior = .oversized
    check(
      runFormatting(formatter: formatter, configuration: configuration(reference: descriptor.reference))
        == .fallback(original: "第一买牛奶", reason: .responseTooLarge),
      "responses above one MiB are cancelled"
    )

    FormattingURLProtocol.behavior = .hold
    FormattingURLProtocol.heldProtocol = nil
    var deadlineResult: FormattingResult?
    _ = formatter.format(
      request: FormattingRequest(originalText: "第一买牛奶", dictionaryTerms: []),
      configuration: configuration(reference: descriptor.reference),
      authorizeSend: { true }
    ) { result in
      deadlineResult = result
    }
    _ = waitForMain { FormattingURLProtocol.heldProtocol }
    scheduler.fireDeadlines()
    check(waitForMain { deadlineResult } == .fallback(original: "第一买牛奶", reason: .deadlineExceeded), "five-second deadline falls back")
    FormattingURLProtocol.heldProtocol?.send(status: 200, body: successfulResponse(text: "1. 买牛奶"))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(deadlineResult == .fallback(original: "第一买牛奶", reason: .deadlineExceeded), "late callbacks cannot replace deadline fallback")

    FormattingURLProtocol.behavior = .hold
    FormattingURLProtocol.heldProtocol = nil
    var expiredSuccessResult: FormattingResult?
    _ = formatter.format(
      request: FormattingRequest(originalText: "第一买牛奶", dictionaryTerms: []),
      configuration: configuration(reference: descriptor.reference),
      authorizeSend: { true }
    ) { result in
      expiredSuccessResult = result
    }
    _ = waitForMain { FormattingURLProtocol.heldProtocol }
    scheduler.nowValue = 5.001
    FormattingURLProtocol.heldProtocol?.send(status: 200, body: successfulResponse(text: "1. 买牛奶"))
    check(
      waitForMain { expiredSuccessResult }
        == .fallback(original: "第一买牛奶", reason: .deadlineExceeded),
      "a response completed after the deadline cannot win before the deadline callback runs"
    )
    scheduler.nowValue = 0

    fixtureObservation.reset()
    FormattingURLProtocol.behavior = .hold
    let denied = runFormatting(
      formatter: formatter,
      configuration: configuration(reference: descriptor.reference),
      authorizeSend: { false }
    )
    check(denied == .fallback(original: "第一买牛奶", reason: .authorizationDenied), "authorization is checked before resume")
    check(fixtureObservation.count() == 0, "denied authorization sends no request")

    FormattingURLProtocol.behavior = .hold
    FormattingURLProtocol.heldProtocol = nil
    var cancellationCount = 0
    let operation = formatter.format(
      request: FormattingRequest(originalText: "第一买牛奶", dictionaryTerms: []),
      configuration: configuration(reference: descriptor.reference),
      authorizeSend: { true }
    ) { _ in
      cancellationCount += 1
    }
    _ = waitForMain { FormattingURLProtocol.heldProtocol }
    operation.cancel()
    FormattingURLProtocol.heldProtocol?.send(status: 200, body: successfulResponse(text: "1. 买牛奶"))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(cancellationCount == 0, "cancel suppresses late completion")

    credentials.remove(reference: descriptor.reference)
    fixtureObservation.reset()
    check(
      runFormatting(formatter: formatter, configuration: configuration(reference: descriptor.reference))
        == .fallback(original: "第一买牛奶", reason: .credentialUnavailable),
      "a cleared process-memory credential falls back safely"
    )
    check(fixtureObservation.count() == 0, "a missing process-memory credential sends no request")

    print("formatting harness passed")
  }
}
