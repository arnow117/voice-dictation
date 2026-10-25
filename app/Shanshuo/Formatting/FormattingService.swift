import ShanshuoCore

/// The coordinator depends on this narrow seam so its session and cancellation rules can be
/// exercised without network or real credential access. Production uses `MiniMaxAPIFormatter`.
protocol FormattingOperation: AnyObject {
  func cancel()
}

protocol FormattingServicing: AnyObject {
  @discardableResult
  func format(
    request: FormattingRequest,
    configuration: FormattingConfigurationSnapshot,
    authorizeSend: @escaping () -> Bool,
    completion: @escaping (FormattingResult) -> Void
  ) -> FormattingOperation
}

final class DisabledFormattingService: FormattingServicing {
  private final class Operation: FormattingOperation {
    func cancel() {}
  }

  @discardableResult
  func format(
    request: FormattingRequest,
    configuration: FormattingConfigurationSnapshot,
    authorizeSend: @escaping () -> Bool,
    completion: @escaping (FormattingResult) -> Void
  ) -> FormattingOperation {
    Operation()
  }
}
