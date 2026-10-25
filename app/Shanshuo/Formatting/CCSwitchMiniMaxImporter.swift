import Foundation
import SQLite3
import ShanshuoCore

enum CCSwitchMiniMaxImportError: Error, Equatable {
  case databaseUnavailable
  case transactionFailed
  case providerMissing
  case multipleProviders
  case invalidSettings
  case invalidEndpoint
  case missingCredential
}

struct ImportedMiniMaxCredential {
  let endpoint: FormattingEndpoint
  let sourceModel: FormattingModel
  let apiKey: String
}

/// Reads exactly one CC Switch MiniMax configuration through a read-only SQLite connection. The
/// caller explicitly chooses when to invoke it; no database path or database content is persisted.
final class CCSwitchMiniMaxImporter {
  func readCredential(from databaseURL: URL) throws -> ImportedMiniMaxCredential {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
      if let database {
        sqlite3_close(database)
      }
      throw CCSwitchMiniMaxImportError.databaseUnavailable
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "BEGIN;", nil, nil, nil) == SQLITE_OK else {
      throw CCSwitchMiniMaxImportError.transactionFailed
    }
    defer { _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) }

    let query = "SELECT settings_config FROM providers WHERE name = ?;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw CCSwitchMiniMaxImportError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, "MiniMax", -1, sqliteTransient)

    var configurations: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let value = sqlite3_column_text(statement, 0) else {
        throw CCSwitchMiniMaxImportError.invalidSettings
      }
      configurations.append(String(cString: value))
    }
    guard sqlite3_errcode(database) == SQLITE_DONE else {
      throw CCSwitchMiniMaxImportError.databaseUnavailable
    }
    guard configurations.count == 1 else {
      throw configurations.isEmpty
        ? CCSwitchMiniMaxImportError.providerMissing
        : CCSwitchMiniMaxImportError.multipleProviders
    }
    return try decode(configuration: configurations[0])
  }

  private func decode(configuration: String) throws -> ImportedMiniMaxCredential {
    guard
      let data = configuration.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let environment = root["env"] as? [String: Any],
      let base = environment["ANTHROPIC_BASE_URL"] as? String,
      let endpoint = FormattingEndpoint(rawValue: base),
      let modelName = environment["ANTHROPIC_MODEL"] as? String,
      let sourceModel = FormattingModel(rawValue: modelName)
    else {
      throw CCSwitchMiniMaxImportError.invalidSettings
    }
    guard FormattingEndpoint.messagesURL(from: endpoint.baseURL) != nil else {
      throw CCSwitchMiniMaxImportError.invalidEndpoint
    }
    let token = environment["ANTHROPIC_AUTH_TOKEN"] as? String
      ?? environment["ANTHROPIC_API_KEY"] as? String
    guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CCSwitchMiniMaxImportError.missingCredential
    }
    return ImportedMiniMaxCredential(
      endpoint: endpoint,
      sourceModel: sourceModel,
      apiKey: token
    )
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
