import Foundation
import ShanshuoCore

protocol FormattingDeadline: AnyObject {
  func cancel()
}

protocol FormattingScheduling: AnyObject {
  func now() -> TimeInterval
  func schedule(after: TimeInterval, _ action: @escaping () -> Void) -> FormattingDeadline
}

private final class DispatchFormattingDeadline: FormattingDeadline {
  private let workItem: DispatchWorkItem

  init(workItem: DispatchWorkItem) {
    self.workItem = workItem
  }

  func cancel() {
    workItem.cancel()
  }
}

private final class DispatchFormattingScheduler: FormattingScheduling {
  func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  func schedule(after: TimeInterval, _ action: @escaping () -> Void) -> FormattingDeadline {
    let workItem = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: workItem)
    return DispatchFormattingDeadline(workItem: workItem)
  }
}

private final class MiniMaxFormattingOperation: FormattingOperation {
  private let lock = NSLock()
  private var isCancelled = false
  private var completionClaimed = false
  private var cancellation: (() -> Void)?

  func setCancellation(_ cancellation: @escaping () -> Void) {
    lock.lock()
    let shouldCancel = isCancelled
    if !shouldCancel {
      self.cancellation = cancellation
    }
    lock.unlock()
    if shouldCancel {
      cancellation()
    }
  }

  func cancel() {
    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      return
    }
    isCancelled = true
    let cancellation = cancellation
    self.cancellation = nil
    lock.unlock()
    cancellation?()
  }

  func clearCancellation() {
    lock.lock()
    cancellation = nil
    lock.unlock()
  }

  func claimCompletion() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isCancelled, !completionClaimed else {
      return false
    }
    completionClaimed = true
    return true
  }
}

/// A single-request, non-streaming MiniMax client. It owns no retry policy and each operation has
/// an independent five-second deadline from `format` invocation through response parsing.
final class MiniMaxAPIFormatter: NSObject, FormattingServicing {
  private final class Transfer {
    let operation: MiniMaxFormattingOperation
    let request: FormattingRequest
    let configuration: FormattingConfigurationSnapshot
    let authorizeSend: () -> Bool
    let completion: (FormattingResult) -> Void
    let startedAt: TimeInterval
    private let lock = NSLock()
    private var completed = false
    private var cancelled = false
    private var body = Data()
    private var task: URLSessionDataTask?
    var deadline: FormattingDeadline?

    init(
      operation: MiniMaxFormattingOperation,
      request: FormattingRequest,
      configuration: FormattingConfigurationSnapshot,
      authorizeSend: @escaping () -> Bool,
      completion: @escaping (FormattingResult) -> Void,
      startedAt: TimeInterval
    ) {
      self.operation = operation
      self.request = request
      self.configuration = configuration
      self.authorizeSend = authorizeSend
      self.completion = completion
      self.startedAt = startedAt
    }

    func claimCompletion() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !completed, !cancelled else {
        return false
      }
      completed = true
      return true
    }

    var isActive: Bool {
      lock.lock()
      defer { lock.unlock() }
      return !completed && !cancelled
    }

    func assign(task: URLSessionDataTask) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !completed, !cancelled else {
        return false
      }
      self.task = task
      return true
    }

    /// Starting the URLSession task under the same lock as cancellation closes the small window
    /// between registration and `resume()`. A cancellation that wins this race never starts I/O.
    func resumeIfActive(_ task: URLSessionDataTask) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !completed, !cancelled, self.task === task else {
        return false
      }
      task.resume()
      return true
    }

    func activeTask() -> URLSessionDataTask? {
      lock.lock()
      defer { lock.unlock() }
      return task
    }

    func cancel() -> URLSessionDataTask? {
      lock.lock()
      cancelled = true
      let task = task
      lock.unlock()
      return task
    }

    func append(_ data: Data) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !completed, !cancelled, body.count <= FormattingRules.maximumResponseBytes - data.count else {
        return false
      }
      body.append(data)
      return true
    }

    func responseBody() -> Data {
      lock.lock()
      defer { lock.unlock() }
      return body
    }
  }

  private let credentialStore: FormattingCredentialStore
  /// Only the explicit public evaluation CLI supplies this closure. Normal dictation has no text
  /// observer, so provider text is never written to application diagnostics.
  private let publicEvaluationRawTextObserver: ((String) -> Void)?
  private let credentialQueue = DispatchQueue(
    label: "com.arnow117.shanshuo.formatting.credentials",
    qos: .userInitiated
  )
  private let scheduler: FormattingScheduling
  private let delegateQueue: OperationQueue
  private var session: URLSession!
  private let transfersLock = NSLock()
  private var activeTransfers: [ObjectIdentifier: Transfer] = [:]
  private var taskTransfers: [Int: Transfer] = [:]

  init(
    credentialStore: FormattingCredentialStore = FormattingCredentialStore(),
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    scheduler: FormattingScheduling = DispatchFormattingScheduler(),
    publicEvaluationRawTextObserver: ((String) -> Void)? = nil
  ) {
    self.credentialStore = credentialStore
    self.scheduler = scheduler
    self.publicEvaluationRawTextObserver = publicEvaluationRawTextObserver
    delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1

    super.init()
    sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
    sessionConfiguration.urlCache = nil
    sessionConfiguration.httpCookieStorage = nil
    sessionConfiguration.httpCookieAcceptPolicy = .never
    session = URLSession(
      configuration: sessionConfiguration,
      delegate: self,
      delegateQueue: delegateQueue
    )
  }

  func format(
    request: FormattingRequest,
    configuration: FormattingConfigurationSnapshot,
    authorizeSend: @escaping () -> Bool,
    completion: @escaping (FormattingResult) -> Void
  ) -> FormattingOperation {
    let operation = MiniMaxFormattingOperation()
    let transfer = Transfer(
      operation: operation,
      request: request,
      configuration: configuration,
      authorizeSend: authorizeSend,
      completion: completion,
      startedAt: scheduler.now()
    )
    retain(transfer)
    operation.setCancellation { [weak self, weak transfer] in
      guard let self, let transfer else {
        return
      }
      self.cancel(transfer)
    }
    transfer.deadline = scheduler.schedule(after: 5) { [weak self, weak transfer] in
      guard let self, let transfer else {
        return
      }
      self.finish(
        transfer,
        with: .fallback(original: transfer.request.originalText, reason: .deadlineExceeded)
      )
    }

    guard FormattingRules.requestValidation(request) == .accepted else {
      finish(transfer, with: .fallback(original: request.originalText, reason: .invalidRequest))
      return operation
    }
    guard let credential = configuration.credential else {
      finish(transfer, with: .fallback(original: request.originalText, reason: .credentialUnavailable))
      return operation
    }
    guard FormattingEndpoint.messagesURL(from: configuration.endpoint.baseURL) != nil else {
      finish(transfer, with: .fallback(original: request.originalText, reason: .invalidRequest))
      return operation
    }
    guard scheduler.now() - transfer.startedAt < 5 else {
      finish(transfer, with: .fallback(original: request.originalText, reason: .deadlineExceeded))
      return operation
    }

    guard let body = FormattingRules.requestBody(for: request, model: configuration.model) else {
      finish(transfer, with: .fallback(original: request.originalText, reason: .invalidRequest))
      return operation
    }
    credentialQueue.async { [weak self, weak transfer] in
      guard let self, let transfer, transfer.isActive else {
        return
      }
      let apiKey: String
      do {
        apiKey = try self.credentialStore.read(reference: credential.reference)
      } catch {
        self.finish(
          transfer,
          with: .fallback(original: request.originalText, reason: .credentialUnavailable)
        )
        return
      }
      guard transfer.isActive else {
        return
      }
      let resume = { [weak self, weak transfer] in
        guard let self, let transfer else {
          return
        }
        self.start(transfer, apiKey: apiKey, body: body)
      }
      if Thread.isMainThread {
        resume()
      } else {
        DispatchQueue.main.async(execute: resume)
      }
    }
    return operation
  }

  private func start(_ transfer: Transfer, apiKey: String, body: Data) {
    guard scheduler.now() - transfer.startedAt < 5 else {
      finish(
        transfer,
        with: .fallback(original: transfer.request.originalText, reason: .deadlineExceeded)
      )
      return
    }
    guard transfer.authorizeSend() else {
      finish(
        transfer,
        with: .fallback(original: transfer.request.originalText, reason: .authorizationDenied)
      )
      return
    }

    var request = URLRequest(url: transfer.configuration.endpoint.messagesURL)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 5
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let task = session.dataTask(with: request)
    guard transfer.assign(task: task) else {
      return
    }
    guard register(task: task, for: transfer) else {
      task.cancel()
      return
    }
    guard transfer.resumeIfActive(task) else {
      remove(transfer)
      task.cancel()
      return
    }
  }

  private func transfer(for task: URLSessionTask) -> Transfer? {
    transfersLock.lock()
    defer { transfersLock.unlock() }
    return taskTransfers[task.taskIdentifier]
  }

  private func retain(_ transfer: Transfer) {
    transfersLock.lock()
    activeTransfers[ObjectIdentifier(transfer)] = transfer
    transfersLock.unlock()
  }

  private func register(task: URLSessionTask, for transfer: Transfer) -> Bool {
    transfersLock.lock()
    defer { transfersLock.unlock() }
    guard activeTransfers[ObjectIdentifier(transfer)] === transfer else {
      return false
    }
    taskTransfers[task.taskIdentifier] = transfer
    return true
  }

  private func remove(_ transfer: Transfer) {
    let taskIdentifier = transfer.activeTask()?.taskIdentifier
    transfersLock.lock()
    activeTransfers[ObjectIdentifier(transfer)] = nil
    if let taskIdentifier {
      taskTransfers[taskIdentifier] = nil
    }
    transfersLock.unlock()
  }

  private func cancel(_ transfer: Transfer) {
    transfer.deadline?.cancel()
    let task = transfer.cancel()
    remove(transfer)
    task?.cancel()
  }

  private func finish(_ transfer: Transfer, with result: FormattingResult) {
    guard transfer.claimCompletion() else {
      return
    }
    let terminalResult: FormattingResult
    if scheduler.now() - transfer.startedAt >= 5 {
      terminalResult = .fallback(original: transfer.request.originalText, reason: .deadlineExceeded)
    } else {
      terminalResult = result
    }
    transfer.deadline?.cancel()
    remove(transfer)
    transfer.operation.clearCancellation()
    transfer.activeTask()?.cancel()

    DispatchQueue.main.async {
      guard transfer.operation.claimCompletion() else {
        return
      }
      transfer.completion(terminalResult)
    }
  }

  private func result(for statusCode: Int, original: String) -> FormattingResult {
    let reason: FormattingFallbackReason
    switch statusCode {
    case 200:
      reason = .invalidResponse
    case 401:
      reason = .authorizationFailed
    case 402:
      reason = .paymentRequired
    case 429:
      reason = .rateLimited
    default:
      reason = .providerRejected
    }
    return .fallback(original: original, reason: reason)
  }
}

extension MiniMaxAPIFormatter: URLSessionDataDelegate, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let transfer = transfer(for: dataTask), let response = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }
    guard response.statusCode == 200 else {
      finish(transfer, with: result(for: response.statusCode, original: transfer.request.originalText))
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let transfer = transfer(for: dataTask) else {
      return
    }
    guard transfer.append(data) else {
      finish(
        transfer,
        with: .fallback(original: transfer.request.originalText, reason: .responseTooLarge)
      )
      dataTask.cancel()
      return
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if let transfer = transfer(for: task) {
      finish(transfer, with: .fallback(original: transfer.request.originalText, reason: .redirected))
    }
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let transfer = transfer(for: task) else {
      return
    }
    if error != nil {
      finish(
        transfer,
        with: .fallback(original: transfer.request.originalText, reason: .transportFailure)
      )
      return
    }

    switch FormattingRules.parseResponse(transfer.responseBody()) {
    case .text(let text):
      publicEvaluationRawTextObserver?(text)
      switch FormattingRules.fidelityValidation(original: transfer.request.originalText, candidate: text) {
      case .accepted:
        finish(transfer, with: .formatted(text))
      case .emptyOutput, .answerLikeResponse, .excessiveExpansion, .missingFactAnchor, .addedFactAnchor,
        .staleCorrection:
        finish(
          transfer,
          with: .fallback(original: transfer.request.originalText, reason: .fidelityRejected)
        )
      }
    case .rejected(.providerError):
      finish(
        transfer,
        with: .fallback(original: transfer.request.originalText, reason: .providerRejected)
      )
    case .rejected:
      finish(
        transfer,
        with: .fallback(original: transfer.request.originalText, reason: .invalidResponse)
      )
    }
  }
}
