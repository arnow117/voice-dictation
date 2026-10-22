import Foundation
import SQLite3
import ShanshuoCore

struct SessionOutcome {
  enum Delivery {
    case inserted
    case copied
    case unverified
  }

  let sessionID: UUID
  let recognizedText: String
  let finalText: String
  let delivery: Delivery
  let target: TargetSnapshot
  let createdAt: Date
}

private final class TestClock {
  var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func wait<Value>(
  _ operation: (@escaping (Result<Value, HistoryStoreError>) -> Void) -> Void
) -> Result<Value, HistoryStoreError> {
  var outcome: Result<Value, HistoryStoreError>?
  operation { result in
    outcome = result
  }
  let deadline = Date().addingTimeInterval(2)
  while outcome == nil, Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  guard let outcome else {
    fputs("FAIL: timed out waiting for history store\n", stderr)
    exit(1)
  }
  return outcome
}

private func outcome(
  sessionID: UUID = UUID(),
  text: String,
  delivery: SessionOutcome.Delivery = .inserted,
  createdAt: Date
) -> SessionOutcome {
  SessionOutcome(
    sessionID: sessionID,
    recognizedText: text,
    finalText: text,
    delivery: delivery,
    target: TargetSnapshot(
      bundleIdentifier: "com.example.Target",
      processIdentifier: 42,
      elementIdentifier: "field",
      isEditable: true,
      isSecure: false
    ),
    createdAt: createdAt
  )
}

private func permissions(of url: URL) -> Int? {
  (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
    .intValue
}

private func dropHistoryTable(at databaseURL: URL) -> Bool {
  var database: OpaquePointer?
  guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
    let database
  else {
    return false
  }
  defer { sqlite3_close(database) }
  return sqlite3_exec(database, "DROP TABLE history;", nil, nil, nil) == SQLITE_OK
}

@main
enum HistoryStoreHarness {
  static func main() {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "shanshuo-history-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: directory) }
    let clock = TestClock()
    let store = HistoryStore(directory: directory, now: { clock.date })
    let originalText = "quote ' ; DROP TABLE history; --"

    check(wait(store.open).isSuccess, "history database opens")
    let first = outcome(text: originalText, createdAt: clock.date)
    let inserted = wait { completion in
      store.append(first, targetAppName: "Target", writeGeneration: 0, completion: completion)
    }
    check(inserted == .success(true), "first session outcome is stored")
    let duplicate = wait { completion in
      store.append(first, targetAppName: "Target", writeGeneration: 0, completion: completion)
    }
    check(duplicate == .success(false), "session IDs are unique")

    let copied = outcome(text: "copied", delivery: .copied, createdAt: clock.date)
    let unverified = outcome(text: "unverified", delivery: .unverified, createdAt: clock.date)
    _ = wait { completion in
      store.append(copied, targetAppName: nil, writeGeneration: 0, completion: completion)
    }
    _ = wait { completion in
      store.append(unverified, targetAppName: nil, writeGeneration: 0, completion: completion)
    }
    let initialRecords = wait(store.records)
    guard case .success(let records) = initialRecords else {
      fputs("FAIL: history records must load\n", stderr)
      exit(1)
    }
    check(records.count == 3, "parameter-bound text and delivery states are retained")
    check(records.contains { $0.finalText == originalText }, "quoted text cannot alter the query")
    check(records.contains { $0.delivery == .copied }, "copied outcomes are marked")
    check(records.contains { $0.delivery == .unverified }, "unverified outcomes are marked")

    let old = outcome(
      text: "expired",
      createdAt: clock.date.addingTimeInterval(-DictationRules.historyRetention - 1)
    )
    _ = wait { completion in
      store.append(old, targetAppName: nil, writeGeneration: 0, completion: completion)
    }
    let beforeCleanup = wait(store.records)
    if case .success(let records) = beforeCleanup {
      check(!records.contains { $0.sessionID == old.sessionID }, "queries exclude expired history")
    } else {
      check(false, "records query succeeds before cleanup")
    }
    check(wait(store.removeExpired).isSuccess, "hourly cleanup can delete expired history")

    check(
      wait { completion in
        store.setEnabled(false, writeGeneration: 1, completion: completion)
      }.isSuccess, "history can be disabled without deleting existing records")
    let disabled = wait { completion in
      store.append(
        outcome(text: "disabled", createdAt: clock.date), targetAppName: nil, writeGeneration: 1,
        completion: completion)
    }
    check(disabled == .success(false), "disabled history rejects later outcomes")

    check(
      wait { completion in
        store.setEnabled(true, writeGeneration: 2, completion: completion)
      }.isSuccess, "history can be re-enabled")
    let late = outcome(text: "late write", createdAt: clock.date)
    check(
      wait { completion in
        store.clear(writeGeneration: 3, completion: completion)
      }.isSuccess, "clear completes")
    let staleAfterClear = wait { completion in
      store.append(late, targetAppName: nil, writeGeneration: 2, completion: completion)
    }
    check(staleAfterClear == .success(false), "late pre-clear outcomes cannot revive history")

    let current = outcome(text: "current", createdAt: clock.date)
    _ = wait { completion in
      store.append(current, targetAppName: nil, writeGeneration: 3, completion: completion)
    }
    check(
      wait { completion in
        store.delete(sessionID: current.sessionID, writeGeneration: 4, completion: completion)
      }.isSuccess, "single record deletion completes")
    let staleAfterDelete = wait { completion in
      store.append(current, targetAppName: nil, writeGeneration: 3, completion: completion)
    }
    check(staleAfterDelete == .success(false), "late deleted session cannot reappear")

    let databaseURL = directory.appendingPathComponent("history.sqlite")
    check(permissions(of: directory) == 0o700, "history directory is owner-only")
    check(permissions(of: databaseURL) == 0o600, "history database is owner-only")
    for suffix in ["-wal", "-shm", "-journal"] {
      let file = URL(fileURLWithPath: databaseURL.path + suffix)
      if fileManager.fileExists(atPath: file.path) {
        check(permissions(of: file) == 0o600, "history auxiliary database file is owner-only")
      }
    }

    let deniedDirectory = fileManager.temporaryDirectory.appendingPathComponent(
      "shanshuo-history-permissions-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: deniedDirectory) }
    let deniedStore = HistoryStore(
      directory: deniedDirectory,
      now: { clock.date },
      permissionApplier: { _, _ in false }
    )
    let deniedOpen = wait(deniedStore.open)
    guard case .failure(.storage) = deniedOpen else {
      check(false, "a failed owner-only permission application prevents database readiness")
      return
    }
    check(
      wait { completion in
        deniedStore.append(
          outcome(text: "must-not-report-success", createdAt: clock.date),
          targetAppName: nil,
          writeGeneration: 0,
          completion: completion
        )
      } == .failure(.storage),
      "a store with unsafe permissions never reports a history write as successful"
    )

    check(dropHistoryTable(at: databaseURL), "the harness can trigger a real SQLite schema failure")
    let missingTableRecords = wait(store.records)
    check(
      missingTableRecords == .failure(.storage),
      "a failed SQLite records query is surfaced instead of returning partial success"
    )
    let missingTableDelete = wait { completion in
      store.delete(sessionID: UUID(), writeGeneration: 5, completion: completion)
    }
    guard case .failure(.storage) = missingTableDelete else {
      check(false, "a failed SQLite delete preparation is surfaced instead of reporting success")
      return
    }

    print("history store harness passed")
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
