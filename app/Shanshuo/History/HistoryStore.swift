import Foundation
import SQLite3
import ShanshuoCore

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum HistoryDelivery: String, CaseIterable {
  case inserted
  case copied
  case unverified

  init(_ delivery: SessionOutcome.Delivery) {
    switch delivery {
    case .inserted:
      self = .inserted
    case .copied:
      self = .copied
    case .unverified:
      self = .unverified
    }
  }
}

struct HistoryRecord: Equatable, Identifiable {
  let id: Int64
  let sessionID: UUID
  let createdAt: Date
  let targetBundleID: String?
  let targetAppName: String?
  let recognizedText: String
  let finalText: String
  let delivery: HistoryDelivery
}

enum HistoryStoreError: Error, Equatable {
  case unavailable
  case storage
}

/// The only SQLite owner. All database work, including cleanup and invalidation, is serialized on
/// one queue. The caller carries a write generation from the main-thread HistoryController; this
/// prevents an outcome that arrives after clear/disable from recreating a deleted record.
final class HistoryStore {
  private let directory: URL
  private let databaseURL: URL
  private let fileManager: FileManager
  private let permissionApplier: (URL, Int) -> Bool
  private let queue = DispatchQueue(label: "com.arnow117.shanshuo.history", qos: .utility)
  private let now: () -> Date
  private var database: OpaquePointer?
  private var enabled = true
  private var writeGeneration: UInt64 = 0
  private var invalidatedSessionIDs = Set<UUID>()

  init(
    directory: URL,
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init,
    permissionApplier: ((URL, Int) -> Bool)? = nil
  ) {
    self.directory = directory
    databaseURL = directory.appendingPathComponent("history.sqlite", isDirectory: false)
    self.fileManager = fileManager
    self.now = now
    self.permissionApplier =
      permissionApplier ?? { url, permissions in
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
          )
          return true
        } catch {
          return false
        }
      }
  }

  deinit {
    queue.sync {
      if let database {
        sqlite3_close(database)
      }
    }
  }

  func open(completion: @escaping (Result<Void, HistoryStoreError>) -> Void) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let result = self.openOnQueue()
      self.deliver(completion, result)
    }
  }

  func setEnabled(
    _ enabled: Bool,
    writeGeneration: UInt64,
    completion: @escaping (Result<Void, HistoryStoreError>) -> Void = { _ in }
  ) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      self.enabled = enabled
      self.writeGeneration = writeGeneration
      self.deliver(completion, .success(()))
    }
  }

  func append(
    _ outcome: SessionOutcome,
    targetAppName: String?,
    writeGeneration: UInt64,
    completion: @escaping (Result<Bool, HistoryStoreError>) -> Void = { _ in }
  ) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      guard self.enabled,
        writeGeneration == self.writeGeneration,
        !self.invalidatedSessionIDs.contains(outcome.sessionID)
      else {
        self.deliver(completion, .success(false))
        return
      }
      let openResult = self.openOnQueue()
      guard case .success = openResult, let database = self.database else {
        self.deliver(completion, openResult.map { _ in false })
        return
      }

      let statement = """
        INSERT OR IGNORE INTO history
          (session_id, created_at, target_bundle_id, target_app_name, recognized_text, final_text, delivery)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
      guard let insert = self.prepare(statement, database: database) else {
        self.deliver(completion, .failure(.storage))
        return
      }
      defer { sqlite3_finalize(insert) }

      self.bind(outcome.sessionID.uuidString, to: 1, statement: insert)
      sqlite3_bind_double(insert, 2, outcome.createdAt.timeIntervalSince1970)
      self.bind(outcome.target.bundleIdentifier, to: 3, statement: insert)
      self.bind(targetAppName, to: 4, statement: insert)
      self.bind(outcome.recognizedText, to: 5, statement: insert)
      self.bind(outcome.finalText, to: 6, statement: insert)
      self.bind(HistoryDelivery(outcome.delivery).rawValue, to: 7, statement: insert)

      guard sqlite3_step(insert) == SQLITE_DONE else {
        self.deliver(completion, .failure(.storage))
        return
      }
      guard self.applyPrivatePermissionsOnQueue() else {
        self.deliver(completion, .failure(.storage))
        return
      }
      self.deliver(completion, .success(sqlite3_changes(database) > 0))
    }
  }

  func records(completion: @escaping (Result<[HistoryRecord], HistoryStoreError>) -> Void) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let openResult = self.openOnQueue()
      guard case .success = openResult, let database = self.database else {
        self.deliver(completion, openResult.map { _ in [] })
        return
      }
      let cutoff = self.now().addingTimeInterval(-DictationRules.historyRetention)
        .timeIntervalSince1970
      let statement = """
        SELECT id, session_id, created_at, target_bundle_id, target_app_name, recognized_text, final_text, delivery
        FROM history WHERE created_at >= ? ORDER BY created_at DESC;
        """
      guard let query = self.prepare(statement, database: database) else {
        self.deliver(completion, .failure(.storage))
        return
      }
      defer { sqlite3_finalize(query) }
      sqlite3_bind_double(query, 1, cutoff)
      var records: [HistoryRecord] = []
      while true {
        switch sqlite3_step(query) {
        case SQLITE_ROW:
          guard let record = self.makeRecord(query) else {
            self.deliver(completion, .failure(.storage))
            return
          }
          records.append(record)
        case SQLITE_DONE:
          self.deliver(completion, .success(records))
          return
        default:
          self.deliver(completion, .failure(.storage))
          return
        }
      }
    }
  }

  func delete(
    sessionID: UUID,
    writeGeneration: UInt64,
    completion: @escaping (Result<Void, HistoryStoreError>) -> Void = { _ in }
  ) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      self.writeGeneration = writeGeneration
      self.invalidatedSessionIDs.insert(sessionID)
      let openResult = self.openOnQueue()
      guard case .success = openResult, let database = self.database
      else {
        self.deliver(completion, openResult.map { _ in () })
        return
      }
      guard
        let delete = self.prepare("DELETE FROM history WHERE session_id = ?;", database: database)
      else {
        self.deliver(completion, .failure(.storage))
        return
      }
      defer { sqlite3_finalize(delete) }
      self.bind(sessionID.uuidString, to: 1, statement: delete)
      guard sqlite3_step(delete) == SQLITE_DONE else {
        self.deliver(completion, .failure(.storage))
        return
      }
      guard self.applyPrivatePermissionsOnQueue() else {
        self.deliver(completion, .failure(.storage))
        return
      }
      self.deliver(completion, .success(()))
    }
  }

  func clear(
    writeGeneration: UInt64,
    completion: @escaping (Result<Void, HistoryStoreError>) -> Void = { _ in }
  ) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      self.writeGeneration = writeGeneration
      let openResult = self.openOnQueue()
      guard case .success = openResult, let database = self.database else {
        self.deliver(completion, openResult)
        return
      }
      guard self.execute("DELETE FROM history;", database: database) else {
        self.deliver(completion, .failure(.storage))
        return
      }
      guard self.applyPrivatePermissionsOnQueue() else {
        self.deliver(completion, .failure(.storage))
        return
      }
      self.deliver(completion, .success(()))
    }
  }

  func removeExpired(completion: @escaping (Result<Void, HistoryStoreError>) -> Void = { _ in }) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let openResult = self.openOnQueue()
      guard case .success = openResult, let database = self.database else {
        self.deliver(completion, openResult)
        return
      }
      let cutoff = self.now().addingTimeInterval(-DictationRules.historyRetention)
        .timeIntervalSince1970
      guard
        let delete = self.prepare("DELETE FROM history WHERE created_at < ?;", database: database)
      else {
        self.deliver(completion, .failure(.storage))
        return
      }
      defer { sqlite3_finalize(delete) }
      sqlite3_bind_double(delete, 1, cutoff)
      guard sqlite3_step(delete) == SQLITE_DONE else {
        self.deliver(completion, .failure(.storage))
        return
      }
      guard self.applyPrivatePermissionsOnQueue() else {
        self.deliver(completion, .failure(.storage))
        return
      }
      self.deliver(completion, .success(()))
    }
  }

  private func openOnQueue() -> Result<Void, HistoryStoreError> {
    if database != nil {
      return applyPrivatePermissionsOnQueue() ? .success(()) : .failure(.storage)
    }
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return .failure(.unavailable)
    }
    guard applyPrivatePermissionsOnQueue() else {
      return .failure(.storage)
    }

    var opened: OpaquePointer?
    let status = sqlite3_open_v2(
      databaseURL.path,
      &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard status == SQLITE_OK, let opened else {
      if let opened {
        sqlite3_close(opened)
      }
      return .failure(.unavailable)
    }
    database = opened
    guard execute("PRAGMA journal_mode=WAL;", database: opened),
      execute("PRAGMA foreign_keys=ON;", database: opened),
      execute(
        """
        CREATE TABLE IF NOT EXISTS history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL UNIQUE,
          created_at REAL NOT NULL,
          target_bundle_id TEXT,
          target_app_name TEXT,
          recognized_text TEXT NOT NULL,
          final_text TEXT NOT NULL,
          delivery TEXT NOT NULL
        );
        """,
        database: opened
      ),
      execute(
        "CREATE INDEX IF NOT EXISTS history_created_at ON history(created_at);", database: opened)
    else {
      sqlite3_close(opened)
      database = nil
      return .failure(.storage)
    }
    guard applyPrivatePermissionsOnQueue() else {
      sqlite3_close(opened)
      database = nil
      return .failure(.storage)
    }
    return .success(())
  }

  private func execute(_ sql: String, database: OpaquePointer) -> Bool {
    sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
  }

  private func prepare(_ sql: String, database: OpaquePointer) -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      return nil
    }
    return statement
  }

  private func bind(_ value: String?, to index: Int32, statement: OpaquePointer) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
  }

  private func makeRecord(_ statement: OpaquePointer) -> HistoryRecord? {
    guard let sessionIDString = string(at: 1, from: statement),
      let sessionID = UUID(uuidString: sessionIDString),
      let recognizedText = string(at: 5, from: statement),
      let finalText = string(at: 6, from: statement),
      let deliveryString = string(at: 7, from: statement),
      let delivery = HistoryDelivery(rawValue: deliveryString)
    else {
      return nil
    }
    return HistoryRecord(
      id: sqlite3_column_int64(statement, 0),
      sessionID: sessionID,
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      targetBundleID: string(at: 3, from: statement),
      targetAppName: string(at: 4, from: statement),
      recognizedText: recognizedText,
      finalText: finalText,
      delivery: delivery
    )
  }

  private func string(at index: Int32, from statement: OpaquePointer) -> String? {
    guard let text = sqlite3_column_text(statement, index) else {
      return nil
    }
    return String(cString: text)
  }

  private func applyPrivatePermissionsOnQueue() -> Bool {
    let relatedPaths = [
      directory,
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
      URL(fileURLWithPath: databaseURL.path + "-journal"),
    ]
    for url in relatedPaths where fileManager.fileExists(atPath: url.path) {
      let permissions = url == directory ? 0o700 : 0o600
      guard permissionApplier(url, permissions) else {
        return false
      }
    }
    return true
  }

  private func deliver<Value>(
    _ completion: @escaping (Result<Value, HistoryStoreError>) -> Void,
    _ result: Result<Value, HistoryStoreError>
  ) {
    DispatchQueue.main.async {
      completion(result)
    }
  }
}
