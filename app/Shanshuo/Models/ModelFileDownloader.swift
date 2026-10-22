import Foundation

struct ModelDownloadRequest {
  let url: URL
  let partURL: URL
  let expectedBytes: Int64
  let resumeOffset: Int64
}

enum ModelTransferKind: Equatable {
  case fresh
  case resumed
  case restarted
  case rangeNotSatisfiable
}

enum ModelDownloadError: Error, Equatable {
  case requestAlreadyActive
  case invalidResponse
  case unexpectedHTTPStatus(Int)
  case invalidContentRange
  case invalidContentLength
  case bodyTooLong
  case incompleteBody
  case fileWrite
  case transport
}

protocol ModelFileDownloading: AnyObject {
  func start(
    _ request: ModelDownloadRequest,
    progress: @escaping (Int64) -> Void,
    completion: @escaping (Result<ModelTransferKind, ModelDownloadError>) -> Void
  )
  func cancel()
}

/// Streams one response directly into a `.part` file. It never materializes model bytes as a
/// `Data` value larger than a URLSession callback chunk. The manager does not begin another
/// transfer until this object has closed the active file handle and invoked completion.
final class URLSessionModelFileDownloader: NSObject, ModelFileDownloading {
  private final class Transfer {
    let request: ModelDownloadRequest
    let progress: (Int64) -> Void
    let completion: (Result<ModelTransferKind, ModelDownloadError>) -> Void
    var task: URLSessionDataTask?
    var fileHandle: FileHandle?
    var kind: ModelTransferKind?
    var responseAccepted = false
    var receivedBytes: Int64 = 0
    var responseOffset: Int64
    var terminalResult: Result<ModelTransferKind, ModelDownloadError>?

    init(
      request: ModelDownloadRequest,
      progress: @escaping (Int64) -> Void,
      completion: @escaping (Result<ModelTransferKind, ModelDownloadError>) -> Void
    ) {
      self.request = request
      self.progress = progress
      self.completion = completion
      responseOffset = request.resumeOffset
    }
  }

  private let lock = NSLock()
  private let delegateQueue: OperationQueue
  private let configuration: URLSessionConfiguration
  private lazy var session = URLSession(
    configuration: configuration,
    delegate: self,
    delegateQueue: delegateQueue
  )
  private var activeTransfer: Transfer?

  init(configuration: URLSessionConfiguration = .ephemeral) {
    delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    self.configuration = configuration
    super.init()
  }

  func start(
    _ request: ModelDownloadRequest,
    progress: @escaping (Int64) -> Void,
    completion: @escaping (Result<ModelTransferKind, ModelDownloadError>) -> Void
  ) {
    lock.lock()
    guard activeTransfer == nil else {
      lock.unlock()
      DispatchQueue.main.async {
        completion(.failure(.requestAlreadyActive))
      }
      return
    }
    let transfer = Transfer(request: request, progress: progress, completion: completion)
    activeTransfer = transfer
    lock.unlock()

    var urlRequest = URLRequest(url: request.url)
    urlRequest.timeoutInterval = 60
    urlRequest.setValue("Shanshuo/0.1", forHTTPHeaderField: "User-Agent")
    if request.resumeOffset > 0 {
      urlRequest.setValue("bytes=\(request.resumeOffset)-", forHTTPHeaderField: "Range")
    }
    let task = session.dataTask(with: urlRequest)
    transfer.task = task
    task.resume()
  }

  func cancel() {
    lock.lock()
    let task = activeTransfer?.task
    lock.unlock()
    task?.cancel()
  }

  private func transfer(for task: URLSessionTask) -> Transfer? {
    lock.lock()
    defer { lock.unlock() }
    guard let activeTransfer, activeTransfer.task?.taskIdentifier == task.taskIdentifier else {
      return nil
    }
    return activeTransfer
  }

  private func accept(
    _ response: HTTPURLResponse,
    transfer: Transfer
  ) -> Result<Void, ModelDownloadError> {
    let request = transfer.request
    let offset = request.resumeOffset
    let status = response.statusCode

    if status == 416, offset > 0 {
      transfer.terminalResult = .success(.rangeNotSatisfiable)
      return .success(())
    }

    let contentLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    let expectedRemaining = request.expectedBytes - offset
    if offset > 0, status == 206 {
      guard
        let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
        let range = parseContentRange(contentRange),
        range.start == offset,
        range.end - range.start + 1 == expectedRemaining,
        range.total == request.expectedBytes,
        contentLength == expectedRemaining
      else {
        return .failure(.invalidContentRange)
      }
      transfer.kind = .resumed
    } else if offset > 0, status == 200 {
      guard contentLength.map({ $0 <= request.expectedBytes }) ?? true else {
        return .failure(.invalidContentLength)
      }
      transfer.kind = .restarted
      transfer.responseOffset = 0
    } else if offset == 0, status == 200 {
      guard contentLength.map({ $0 <= request.expectedBytes }) ?? true else {
        return .failure(.invalidContentLength)
      }
      transfer.kind = .fresh
    } else if offset == 0, status == 206 {
      guard
        let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
        let range = parseContentRange(contentRange),
        range.start == 0,
        range.end + 1 == request.expectedBytes,
        range.total == request.expectedBytes,
        contentLength == request.expectedBytes
      else {
        return .failure(.invalidContentRange)
      }
      transfer.kind = .fresh
    } else {
      return .failure(.unexpectedHTTPStatus(status))
    }

    let shouldAppend = transfer.kind == .resumed
    do {
      if shouldAppend {
        transfer.fileHandle = try FileHandle(forWritingTo: request.partURL)
        try transfer.fileHandle?.seekToEnd()
      } else {
        FileManager.default.createFile(atPath: request.partURL.path, contents: nil)
        transfer.fileHandle = try FileHandle(forWritingTo: request.partURL)
      }
      transfer.responseAccepted = true
      return .success(())
    } catch {
      return .failure(.fileWrite)
    }
  }

  private func finish(_ transfer: Transfer, result: Result<ModelTransferKind, ModelDownloadError>) {
    try? transfer.fileHandle?.close()
    transfer.fileHandle = nil

    lock.lock()
    if activeTransfer === transfer {
      activeTransfer = nil
    }
    lock.unlock()

    DispatchQueue.main.async {
      transfer.completion(result)
    }
  }
}

extension URLSessionModelFileDownloader: URLSessionDataDelegate {
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

    switch accept(response, transfer: transfer) {
    case .success:
      if transfer.terminalResult != nil {
        completionHandler(.cancel)
      } else {
        completionHandler(.allow)
      }
    case .failure(let error):
      transfer.terminalResult = .failure(error)
      completionHandler(.cancel)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let transfer = transfer(for: dataTask), transfer.terminalResult == nil else {
      return
    }
    let receivedAfterChunk =
      transfer.responseOffset + transfer.receivedBytes + Int64(data.count)
    guard receivedAfterChunk <= transfer.request.expectedBytes else {
      transfer.terminalResult = .failure(.bodyTooLong)
      dataTask.cancel()
      return
    }
    do {
      try transfer.fileHandle?.write(contentsOf: data)
      transfer.receivedBytes += Int64(data.count)
      transfer.progress(transfer.responseOffset + transfer.receivedBytes)
    } catch {
      transfer.terminalResult = .failure(.fileWrite)
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let transfer = transfer(for: task) else {
      return
    }

    if let terminalResult = transfer.terminalResult {
      finish(transfer, result: terminalResult)
      return
    }
    if let error {
      let nsError = error as NSError
      let result: Result<ModelTransferKind, ModelDownloadError> =
        nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        ? .failure(.transport) : .failure(.transport)
      finish(transfer, result: result)
      return
    }
    guard transfer.responseAccepted, let kind = transfer.kind else {
      finish(transfer, result: .failure(.invalidResponse))
      return
    }
    let totalWritten = transfer.responseOffset + transfer.receivedBytes
    guard totalWritten == transfer.request.expectedBytes else {
      finish(transfer, result: .failure(.incompleteBody))
      return
    }
    finish(transfer, result: .success(kind))
  }
}

private func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
  guard value.hasPrefix("bytes ") else {
    return nil
  }
  let rangeAndTotal = value.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1)
  guard rangeAndTotal.count == 2 else {
    return nil
  }
  let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
  guard
    bounds.count == 2,
    let start = Int64(bounds[0]),
    let end = Int64(bounds[1]),
    let total = Int64(rangeAndTotal[1]),
    start <= end,
    end < total
  else {
    return nil
  }
  return (start, end, total)
}
