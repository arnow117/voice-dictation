/// A strong lease captured by audio-engine queue closures. It keeps an operation alive after the
/// coordinator releases its main-thread reference, until queued start/stop cleanup has run.
final class QueuedAudioOperationLease<Operation: AnyObject> {
  let operation: Operation

  init(_ operation: Operation) {
    self.operation = operation
  }
}
