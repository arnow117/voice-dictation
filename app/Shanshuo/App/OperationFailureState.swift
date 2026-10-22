/// Keeps independent operation failures visible until a retry of that same operation succeeds.
/// A background refresh, a successful read, or an unrelated write must not erase failed
/// delete/clear feedback.
struct OperationFailureState<Failure, Operation: Hashable> {
  private var failures: [Operation: Failure] = [:]
  private var failureOrder: [Operation] = []

  var failure: Failure? {
    guard let operation = failureOrder.last else {
      return nil
    }
    return failures[operation]
  }

  func failure(for operation: Operation) -> Failure? {
    failures[operation]
  }

  mutating func record<Value>(
    _ result: Result<Value, Failure>,
    operation: Operation
  ) {
    switch result {
    case .failure(let error):
      failures[operation] = error
      failureOrder.removeAll { $0 == operation }
      failureOrder.append(operation)
    case .success:
      failures.removeValue(forKey: operation)
      failureOrder.removeAll { $0 == operation }
    }
  }
}
