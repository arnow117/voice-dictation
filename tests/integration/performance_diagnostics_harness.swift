import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func permissions(for url: URL) -> Int? {
  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

private struct FailingPerformancePermissions: PerformanceFilePermissionsApplying {
  struct Failure: Error {}

  func apply(_ permissions: Int, to path: String) throws {
    throw Failure()
  }
}

@main
enum PerformanceDiagnosticsHarness {
  static func main() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shanshuo-performance-diagnostics-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let processID = UUID()
    let sessionID = UUID()
    let log = BoundedPerformanceEventLog(
      directory: directory,
      processID: processID,
      retainedFileLimit: 2,
      maximumFileSizeBytes: 4_096
    )
    let event = PerformanceDiagnosticEvent(
      kind: .audioStopped,
      result: .succeeded,
      processID: processID,
      sessionID: sessionID,
      timestamp: MonotonicTimestamp(nanoseconds: 42),
      audioDuration: 15
    )
    check(log.append(event), "a typed event is written to the bounded local log")
    check(log.events() == [event], "the log round-trips the closed event schema")
    check(permissions(for: directory) == 0o700, "the diagnostics directory is owner-only")
    check(permissions(for: log.url) == 0o600, "the diagnostics log file is owner-only")

    let rawLine = String(data: try! Data(contentsOf: log.url), encoding: .utf8)!
    check(rawLine.contains("\"kind\":\"audio_stopped\""), "stored events use fixed event names")
    check(
      !rawLine.contains("text") && !rawLine.contains("clipboard"),
      "stored events have no content fields")
    let verifiedEvent = PerformanceDiagnosticEvent(
      kind: .axReadbackVerified,
      result: .verifiedInsertion,
      processID: processID,
      sessionID: sessionID,
      timestamp: MonotonicTimestamp(nanoseconds: 43)
    )
    let verifiedJSON = String(data: try! JSONEncoder().encode(verifiedEvent), encoding: .utf8)!
    check(
      verifiedJSON.contains("\"verified_insertion\""),
      "closed result names use the report's stable snake-case schema"
    )

    let capped = BoundedPerformanceEventLog(
      directory: directory,
      processID: UUID(),
      retainedFileLimit: 2,
      maximumFileSizeBytes: 1
    )
    check(!capped.append(event), "a full diagnostics file rejects another event")

    let third = BoundedPerformanceEventLog(
      directory: directory,
      processID: UUID(),
      retainedFileLimit: 2,
      maximumFileSizeBytes: 4_096
    )
    let retainedFiles = try! FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix("performance-") && $0.pathExtension == "jsonl" }
    check(retainedFiles.count == 2, "old diagnostic files are pruned to the retention limit")
    check(
      FileManager.default.fileExists(atPath: third.url.path), "the current process log is retained")

    let unsafeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shanshuo-performance-diagnostics-permission-failure-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: unsafeDirectory) }
    let permissionFailureLog = BoundedPerformanceEventLog(
      directory: unsafeDirectory,
      processID: UUID(),
      retainedFileLimit: 2,
      maximumFileSizeBytes: 4_096,
      permissions: FailingPerformancePermissions()
    )
    check(
      !permissionFailureLog.isReady,
      "a diagnostics log remains unavailable when owner-only permissions cannot be applied"
    )
    check(
      !permissionFailureLog.append(event),
      "a diagnostics log never writes after owner-only permission setup fails"
    )
    check(
      permissionFailureLog.events().isEmpty,
      "a failed permission setup exposes no readable diagnostics events"
    )

    check(ProcessStartTimestamp.currentProcess() != nil, "process start comes from proc_pid_rusage")
    print("performance diagnostics harness passed")
  }
}
