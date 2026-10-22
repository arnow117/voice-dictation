import Darwin
import Foundation

/// A timestamp derived from mach absolute time. It remains valid while wall-clock time changes.
struct MonotonicTimestamp: Codable, Equatable, Comparable, Sendable {
  let nanoseconds: UInt64

  static func now() -> MonotonicTimestamp {
    fromMachAbsoluteTime(mach_absolute_time())
  }

  static func fromMachAbsoluteTime(_ value: UInt64) -> MonotonicTimestamp {
    let timebase = MachTimebase.shared
    let wholeTicks = value / timebase.denominator
    let remainderTicks = value % timebase.denominator
    let wholeNanoseconds = wholeTicks.multipliedReportingOverflow(by: timebase.numerator)
    let remainderNanoseconds = remainderTicks * timebase.numerator / timebase.denominator
    let combinedNanoseconds = wholeNanoseconds.partialValue.addingReportingOverflow(
      remainderNanoseconds
    )
    let nanoseconds =
      wholeNanoseconds.overflow || combinedNanoseconds.overflow
      ? UInt64.max
      : combinedNanoseconds.partialValue
    return MonotonicTimestamp(nanoseconds: nanoseconds)
  }

  static func < (lhs: MonotonicTimestamp, rhs: MonotonicTimestamp) -> Bool {
    lhs.nanoseconds < rhs.nanoseconds
  }
}

private enum MachTimebase {
  static let shared: (numerator: UInt64, denominator: UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
  }()
}

/// The event names are intentionally closed. Diagnostic records never accept text, app/window
/// identity, clipboard content, URLs, paths, or system error descriptions.
enum PerformanceEventKind: String, Codable, CaseIterable, Sendable {
  case processStarted = "process_started"
  case coldStartReady = "cold_start_ready"
  case hotkeyPressed = "hotkey_pressed"
  case hotkeyReleased = "hotkey_released"
  case recordingDisplayCommitted = "recording_display_committed"
  case audioEngineStarted = "audio_engine_started"
  case audioFirstBuffer = "audio_first_buffer"
  case audioStopped = "audio_stopped"
  case recognitionDelivered = "recognition_delivered"
  case axReadbackVerified = "ax_readback_verified"
  case copyCompleted = "copy_completed"
  case pasteRequested = "paste_requested"
  case unicodeRequested = "unicode_requested"
  case sessionFinished = "session_finished"
}

enum PerformanceEventResult: String, Codable, CaseIterable, Sendable {
  case observed
  case ready
  case succeeded
  case failed
  case cancelled
  case delivered
  case verifiedInsertion = "verified_insertion"
  case copied
  case unverified
  case requested
}

/// The complete diagnostic payload. The type intentionally has no extensible metadata field.
struct PerformanceDiagnosticEvent: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let kind: PerformanceEventKind
  let result: PerformanceEventResult
  let processID: UUID
  let sessionID: UUID
  let monotonicNanoseconds: UInt64
  let audioDurationNanoseconds: UInt64?

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case kind
    case result
    case processID = "process_id"
    case sessionID = "session_id"
    case monotonicNanoseconds = "monotonic_ns"
    case audioDurationNanoseconds = "audio_duration_ns"
  }

  init(
    kind: PerformanceEventKind,
    result: PerformanceEventResult,
    processID: UUID,
    sessionID: UUID,
    timestamp: MonotonicTimestamp,
    audioDuration: TimeInterval? = nil
  ) {
    schemaVersion = Self.schemaVersion
    self.kind = kind
    self.result = result
    self.processID = processID
    self.sessionID = sessionID
    monotonicNanoseconds = timestamp.nanoseconds
    audioDurationNanoseconds = audioDuration.map(Self.nanoseconds(from:))
  }

  private static func nanoseconds(from duration: TimeInterval) -> UInt64 {
    guard duration.isFinite, duration > 0 else {
      return 0
    }
    let nanoseconds = duration * 1_000_000_000
    guard nanoseconds < Double(UInt64.max) else {
      return UInt64.max
    }
    return UInt64(nanoseconds.rounded())
  }
}

/// Production components use this constrained interface. Its method has no textual or arbitrary
/// metadata parameter, which keeps the privacy boundary visible at each call site.
protocol PerformanceEventRecording: AnyObject {
  var processID: UUID { get }

  func now() -> MonotonicTimestamp
  func record(
    kind: PerformanceEventKind,
    result: PerformanceEventResult,
    sessionID: UUID,
    timestamp: MonotonicTimestamp,
    audioDuration: TimeInterval?
  )
}

/// Components that run after a coordinator-created session capture its random session identifier
/// before scheduling work. The identifier is never derived from user data or a system object.
protocol PerformanceSessionConfiguring: AnyObject {
  func setPerformanceSessionID(_ sessionID: UUID?)
}

extension PerformanceEventRecording {
  func record(
    kind: PerformanceEventKind,
    result: PerformanceEventResult,
    sessionID: UUID,
    audioDuration: TimeInterval? = nil
  ) {
    record(
      kind: kind,
      result: result,
      sessionID: sessionID,
      timestamp: now(),
      audioDuration: audioDuration
    )
  }
}

final class NoopPerformanceEventRecorder: PerformanceEventRecording {
  let processID = UUID()

  func now() -> MonotonicTimestamp {
    .now()
  }

  func record(
    kind: PerformanceEventKind,
    result: PerformanceEventResult,
    sessionID: UUID,
    timestamp: MonotonicTimestamp,
    audioDuration: TimeInterval?
  ) {}
}

/// Appends records to one bounded, owner-only JSONL file per process. File I/O runs on a private
/// queue so an audio tap only enqueues its first-buffer observation.
final class LocalPerformanceDiagnostics: PerformanceEventRecording {
  let processID: UUID

  private let queue = DispatchQueue(label: "com.arnow117.shanshuo.performance-diagnostics")
  private let log: BoundedPerformanceEventLog

  init(
    directory: URL = Paths.performanceDiagnosticsDirectory,
    processID: UUID = UUID(),
    retainedFileLimit: Int = 8,
    maximumFileSizeBytes: Int = 512 * 1_024
  ) {
    self.processID = processID
    log = BoundedPerformanceEventLog(
      directory: directory,
      processID: processID,
      retainedFileLimit: retainedFileLimit,
      maximumFileSizeBytes: maximumFileSizeBytes
    )
  }

  func now() -> MonotonicTimestamp {
    .now()
  }

  func record(
    kind: PerformanceEventKind,
    result: PerformanceEventResult,
    sessionID: UUID,
    timestamp: MonotonicTimestamp,
    audioDuration: TimeInterval?
  ) {
    let event = PerformanceDiagnosticEvent(
      kind: kind,
      result: result,
      processID: processID,
      sessionID: sessionID,
      timestamp: timestamp,
      audioDuration: audioDuration
    )
    queue.async { [log] in
      _ = log.append(event)
    }
  }

  func flush() {
    queue.sync {}
  }
}

protocol PerformanceFilePermissionsApplying {
  func apply(_ permissions: Int, to path: String) throws
}

private struct SystemPerformanceFilePermissions: PerformanceFilePermissionsApplying {
  func apply(_ permissions: Int, to path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
  }
}

/// A synchronous file primitive kept separate from the production queue for deterministic tests.
final class BoundedPerformanceEventLog {
  private let directory: URL
  private let fileURL: URL
  private let retainedFileLimit: Int
  private let maximumFileSizeBytes: Int
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let permissions: PerformanceFilePermissionsApplying
  private(set) var isReady: Bool

  init(
    directory: URL,
    processID: UUID,
    retainedFileLimit: Int,
    maximumFileSizeBytes: Int,
    permissions: PerformanceFilePermissionsApplying = SystemPerformanceFilePermissions()
  ) {
    self.directory = directory
    self.retainedFileLimit = max(retainedFileLimit, 1)
    self.maximumFileSizeBytes = max(maximumFileSizeBytes, 1)
    fileURL = directory.appendingPathComponent(
      "performance-\(processID.uuidString.lowercased()).jsonl",
      isDirectory: false
    )
    self.permissions = permissions
    isReady = false
    isReady = prepareStorage()
  }

  var url: URL {
    fileURL
  }

  @discardableResult
  func append(_ event: PerformanceDiagnosticEvent) -> Bool {
    guard isReady else {
      return false
    }
    guard let encoded = try? encoder.encode(event) else {
      return false
    }
    var line = encoded
    line.append(0x0A)

    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
      let currentSize = attributes[.size] as? NSNumber
    else {
      return false
    }
    guard line.count <= maximumFileSizeBytes,
      currentSize.intValue <= maximumFileSizeBytes - line.count
    else {
      return false
    }

    guard let handle = try? FileHandle(forWritingTo: fileURL) else {
      return false
    }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
      return true
    } catch {
      return false
    }
  }

  func events() -> [PerformanceDiagnosticEvent] {
    guard isReady else {
      return []
    }
    guard let data = try? Data(contentsOf: fileURL) else {
      return []
    }
    return data.split(separator: 0x0A).compactMap { line in
      try? decoder.decode(PerformanceDiagnosticEvent.self, from: Data(line))
    }
  }

  private func prepareStorage() -> Bool {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try permissions.apply(0o700, to: directory.path)
      guard hasPermissions(0o700, at: directory) else {
        return false
      }

      if !manager.fileExists(atPath: fileURL.path) {
        guard
          manager.createFile(
            atPath: fileURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
          )
        else {
          return false
        }
      }
      try permissions.apply(0o600, to: fileURL.path)
      guard hasPermissions(0o600, at: fileURL) else {
        return false
      }
      return pruneRetainedFiles()
    } catch {
      return false
    }
  }

  private func hasPermissions(_ expected: Int, at url: URL) -> Bool {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let permissions = attributes[.posixPermissions] as? NSNumber
    else {
      return false
    }
    return permissions.intValue == expected
  }

  private func pruneRetainedFiles() -> Bool {
    let manager = FileManager.default
    guard
      let files = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }

    let performanceFiles = files.filter { url in
      url.lastPathComponent.hasPrefix("performance-") && url.pathExtension == "jsonl"
    }
    let oldestFirst = performanceFiles.sorted { lhs, rhs in
      let lhsDate =
        (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      let rhsDate =
        (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      return lhsDate < rhsDate
    }
    let expiredCount = max(0, oldestFirst.count - retainedFileLimit)
    do {
      for expired in oldestFirst.prefix(expiredCount) where expired != fileURL {
        try manager.removeItem(at: expired)
      }
      return true
    } catch {
      return false
    }
  }
}

enum ProcessStartTimestamp {
  /// `ri_proc_start_abstime` and `mach_absolute_time` use the same monotonic clock domain.
  static func currentProcess() -> MonotonicTimestamp? {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      let opaquePointer = UnsafeMutableRawPointer(pointer)
      let rusagePointer = opaquePointer.assumingMemoryBound(to: rusage_info_t?.self)
      return proc_pid_rusage(getpid(), RUSAGE_INFO_V2, rusagePointer)
    }
    guard result == 0, info.ri_proc_start_abstime > 0 else {
      return nil
    }
    return .fromMachAbsoluteTime(info.ri_proc_start_abstime)
  }
}
