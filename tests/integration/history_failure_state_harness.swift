import Foundation

private enum TestFailure: Error, Equatable {
  case storage
}

private enum TestOperation: Equatable {
  case query
  case delete
  case clear
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
enum HistoryFailureStateHarness {
  static func main() {
    var state = OperationFailureState<TestFailure, TestOperation>()
    state.record(Result<Void, TestFailure>.failure(.storage), operation: .delete)
    check(state.failure == .storage, "a failed delete or clear is retained in shared state")

    state.record(Result<[String], TestFailure>.success([]), operation: .query)
    check(state.failure == .storage, "a successful periodic query does not hide a mutation failure")

    state.record(Result<[String], TestFailure>.failure(.storage), operation: .query)
    check(
      state.failure(for: .delete) == .storage && state.failure(for: .query) == .storage,
      "a query failure is retained independently of an earlier failed delete"
    )
    state.record(Result<[String], TestFailure>.success([]), operation: .query)
    check(
      state.failure(for: .delete) == .storage && state.failure(for: .query) == nil,
      "query recovery clears only its own failure and retains the delete retry"
    )

    state.record(Result<Void, TestFailure>.success(()), operation: .clear)
    check(
      state.failure == .storage, "an unrelated successful mutation does not hide a failed delete")

    state.record(Result<Void, TestFailure>.success(()), operation: .delete)
    check(state.failure == nil, "a successful retry clears the retained mutation failure")
    print("history failure state harness passed")
  }
}
