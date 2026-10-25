import CryptoKit
import Foundation
import ShanshuoCore

/// Explicit developer and validation entry points. They intentionally accept neither a credential
/// nor arbitrary user dictation. The normal menu-bar application does not invoke this type.
enum FormattingCLI {
  private struct PublicFixture {
    let identifier: String
    let text: String
  }

  private struct PublicEvaluationFixture: Decodable {
    let id: String
    let category: String
    let input: String
  }

  private struct PublicEvaluationRecord: Encodable {
    let schemaVersion: Int
    let fixtureSHA256: String
    let promptSHA256: String
    let caseID: String
    let category: String
    let input: String
    let rawProviderText: String?
    let finalText: String
    let status: String
    let reason: String?
    let elapsedMilliseconds: Int

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case fixtureSHA256 = "fixture_sha256"
      case promptSHA256 = "prompt_sha256"
      case caseID = "case_id"
      case category
      case input
      case rawProviderText = "raw_provider_text"
      case finalText = "final_text"
      case status
      case reason
      case elapsedMilliseconds = "elapsed_ms"
    }
  }

  private final class RawTextCapture {
    private let lock = NSLock()
    private var rawText: String?

    func record(_ text: String) {
      lock.lock()
      rawText = text
      lock.unlock()
    }

    func value() -> String? {
      lock.lock()
      defer { lock.unlock() }
      return rawText
    }
  }

  private static let fixtures = [
    PublicFixture(identifier: "correction", text: "嗯那个我们周三不对周四下午开会"),
    PublicFixture(
      identifier: "list",
      text: "明天下午准备三项第一擦拭白板第二摆好座椅第三打开投影"
    ),
  ]

  static func runPublicSample(_ arguments: [String]) -> Int32 {
    guard arguments.count == 1,
      let fixture = fixtures.first(where: { $0.identifier == arguments[0] })
    else {
      return emit(["status": "invalid_fixture"])
    }

    let session: ImportedSession
    do {
      session = try importedSession()
    } catch let error as CCSwitchMiniMaxImportError {
      return emit(["fixture_id": fixture.identifier, "status": importErrorCode(error)])
    } catch {
      return emit(["fixture_id": fixture.identifier, "status": "credential_unavailable"])
    }

    let startedAt = DispatchTime.now().uptimeNanoseconds
    var result: FormattingResult?
    let formatter = MiniMaxAPIFormatter(credentialStore: session.credentials)
    let operation = formatter.format(
      request: FormattingRequest(originalText: fixture.text, dictionaryTerms: []),
      configuration: session.configuration,
      authorizeSend: { true }
    ) { completion in
      result = completion
    }
    withExtendedLifetime(operation) {
      let deadline = Date().addingTimeInterval(6)
      while result == nil, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
      }
    }

    let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
    guard let result else {
      return emit([
        "fixture_id": fixture.identifier,
        "status": "fallback",
        "reason": FormattingFallbackReason.deadlineExceeded.rawValue,
        "elapsed_ms": elapsedMilliseconds,
        "text": fixture.text,
      ])
    }
    switch result {
    case .formatted(let text):
      return emit([
        "fixture_id": fixture.identifier,
        "status": "formatted",
        "elapsed_ms": elapsedMilliseconds,
        "text": text,
      ])
    case .fallback(let original, let reason):
      return emit([
        "fixture_id": fixture.identifier,
        "status": "fallback",
        "reason": reason.rawValue,
        "elapsed_ms": elapsedMilliseconds,
        "text": original,
      ])
    }
  }

  /// Runs only the checked-in public held-out fixture. This command accepts no credential and no
  /// arbitrary dictation input. It imports the CC Switch setting once into this process's cache so
  /// formal evaluation uses the same formatter, timeout, parsing, and fidelity guard as the app.
  static func runPublicEvaluation(_ arguments: [String]) -> Int32 {
    guard arguments.count == 2, arguments[0] == "--out" else {
      return emit(["status": "invalid_arguments"])
    }

    let outputURL = URL(fileURLWithPath: arguments[1], isDirectory: false)
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
      return emit(["status": "output_exists"])
    }

    let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("bench/formatting/heldout.jsonl", isDirectory: false)
    guard
      let fixtureData = try? Data(contentsOf: fixtureURL),
      let fixtures = decodePublicEvaluationFixtures(fixtureData),
      fixtures.count == 60,
      Set(fixtures.map(\.id)).count == fixtures.count
    else {
      return emit(["status": "fixture_unavailable"])
    }

    let session: ImportedSession
    do {
      session = try importedSession()
    } catch let error as CCSwitchMiniMaxImportError {
      return emit(["status": importErrorCode(error)])
    } catch {
      return emit(["status": "credential_unavailable"])
    }
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
      let outputHandle = FileHandle(forWritingAtPath: outputURL.path)
    else {
      return emit(["status": "output_unavailable"])
    }
    defer { try? outputHandle.close() }

    let fixtureSHA256 = sha256(fixtureData)
    let promptSHA256 = sha256(Data(FormattingRules.systemPrompt.utf8))
    var fallbackCount = 0

    for fixture in fixtures {
      let record = runPublicEvaluationFixture(
        fixture,
        configuration: session.configuration,
        credentials: session.credentials,
        fixtureSHA256: fixtureSHA256,
        promptSHA256: promptSHA256
      )
      if record.status == "fallback" {
        fallbackCount += 1
      }
      guard
        let line = try? JSONEncoder.sorted.encode(record),
        let newline = String(data: line, encoding: .utf8)?.appending("\n").data(using: .utf8)
      else {
        return emit(["status": "output_unavailable"])
      }
      outputHandle.write(newline)
    }

    return emit(
      [
        "status": "completed",
        "case_count": fixtures.count,
        "fallback_count": fallbackCount,
        "fixture_sha256": fixtureSHA256,
        "prompt_sha256": promptSHA256,
      ],
      successfulStatuses: ["completed"]
    )
  }

  private static func decodePublicEvaluationFixtures(_ data: Data) -> [PublicEvaluationFixture]? {
    let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    var fixtures: [PublicEvaluationFixture] = []
    for line in lines {
      guard let fixture = try? JSONDecoder().decode(PublicEvaluationFixture.self, from: Data(line)) else {
        return nil
      }
      fixtures.append(fixture)
    }
    return fixtures
  }

  private static func runPublicEvaluationFixture(
    _ fixture: PublicEvaluationFixture,
    configuration: FormattingConfigurationSnapshot,
    credentials: FormattingCredentialStore,
    fixtureSHA256: String,
    promptSHA256: String
  ) -> PublicEvaluationRecord {
    let capture = RawTextCapture()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var result: FormattingResult?
    let formatter = MiniMaxAPIFormatter(
      credentialStore: credentials,
      publicEvaluationRawTextObserver: capture.record
    )
    let operation = formatter.format(
      request: FormattingRequest(originalText: fixture.input, dictionaryTerms: []),
      configuration: configuration,
      authorizeSend: { true }
    ) { completion in
      result = completion
    }
    withExtendedLifetime(operation) {
      let deadline = Date().addingTimeInterval(6)
      while result == nil, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
      }
    }

    let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
    let rawProviderText = capture.value()
    let finalText: String
    let status: String
    let reason: String?
    switch result {
    case .formatted(let text):
      finalText = text
      status = "formatted"
      reason = nil
    case .fallback(let original, let fallbackReason):
      finalText = original
      status = "fallback"
      reason = fallbackReason.rawValue
    case nil:
      finalText = fixture.input
      status = "fallback"
      reason = FormattingFallbackReason.deadlineExceeded.rawValue
    }
    return PublicEvaluationRecord(
      schemaVersion: 1,
      fixtureSHA256: fixtureSHA256,
      promptSHA256: promptSHA256,
      caseID: fixture.id,
      category: fixture.category,
      input: fixture.input,
      rawProviderText: rawProviderText,
      finalText: finalText,
      status: status,
      reason: reason,
      elapsedMilliseconds: elapsedMilliseconds
    )
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct ImportedSession {
    let credentials: FormattingCredentialStore
    let configuration: FormattingConfigurationSnapshot
  }

  private static func importedSession() throws -> ImportedSession {
    let databaseURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".cc-switch", isDirectory: true)
      .appendingPathComponent("cc-switch.db", isDirectory: false)
    let imported = try CCSwitchMiniMaxImporter().readCredential(from: databaseURL)
    let credentials = FormattingCredentialStore()
    let descriptor = try credentials.save(imported.apiKey)
    let configuration = FormattingConfigurationSnapshot(
      enabled: false,
      model: .flash,
      endpoint: imported.endpoint,
      credential: descriptor,
      consentVersion: nil,
      revision: 0,
      testGeneration: 0
    )
    return ImportedSession(credentials: credentials, configuration: configuration)
  }

  private static func importErrorCode(_ error: CCSwitchMiniMaxImportError) -> String {
    switch error {
    case .databaseUnavailable:
      return "database_unavailable"
    case .transactionFailed:
      return "transaction_failed"
    case .providerMissing:
      return "provider_missing"
    case .multipleProviders:
      return "multiple_providers"
    case .invalidSettings:
      return "invalid_settings"
    case .invalidEndpoint:
      return "invalid_endpoint"
    case .missingCredential:
      return "missing_credential"
    }
  }

  @discardableResult
  private static func emit(
    _ value: [String: Any],
    successfulStatuses: Set<String> = ["formatted"]
  ) -> Int32 {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
      ),
      let line = String(data: data, encoding: .utf8)
    else {
      return 2
    }
    print(line)
    guard let status = value["status"] as? String else {
      return 1
    }
    return successfulStatuses.contains(status) ? 0 : 1
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
