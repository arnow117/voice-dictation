import Foundation

enum ModelManagerStatus: Equatable {
  case checking
  case repairRequired(String)
  case downloading(completedBytes: Int64, totalBytes: Int64, sourceName: String)
  case paused
  case loading
  case ready(location: URL, isReadOnly: Bool)
  case deleting
  case failed(String)

  var summary: String {
    switch self {
    case .checking:
      return "正在检查"
    case .repairRequired:
      return "需要下载或修复"
    case .downloading:
      return "正在下载"
    case .paused:
      return "下载已暂停"
    case .loading:
      return "正在加载"
    case .ready:
      return "就绪"
    case .deleting:
      return "正在删除"
    case .failed:
      return "需要重试"
    }
  }
}

protocol ModelManaging: AnyObject {
  var manifest: Qwen3ModelManifest { get }
  var status: ModelManagerStatus { get }
  var selectedSource: ModelDownloadSource { get }
  var onWillMutate: (() -> Void)? { get set }
  func observe(_ handler: @escaping (ModelManagerStatus) -> Void) -> UUID
  func removeObserver(_ identifier: UUID)
  func bootstrap()
  func download(preferredSource: ModelDownloadSource?)
  func pause()
  func repair()
  func deleteOwnedModel()
}

/// The single owner of the model directory. It serializes filesystem validation and promotion on a
/// private queue, publishes all state on the main thread, and invalidates a generation before
/// cancelling a transfer or unloading the runtime. The only mutable model path is `ownedDirectory`.
final class ModelManager: ModelManaging {
  let manifest: Qwen3ModelManifest
  let ownedDirectory: URL
  let readOnlySeedDirectory: URL?
  private let runtime: ModelRuntime
  private let downloader: ModelFileDownloading
  private let fileManager: FileManager
  private let queue = DispatchQueue(label: "com.arnow117.shanshuo.model-manager", qos: .utility)
  private var generation: UInt64 = 0
  private var transferInFlight = false
  private var pendingAfterTransfer: (() -> Void)?
  private var observers: [UUID: (ModelManagerStatus) -> Void] = [:]
  private var currentDownloadedBytes: Int64 = 0

  private(set) var status: ModelManagerStatus = .checking
  private(set) var selectedSource: ModelDownloadSource
  var onWillMutate: (() -> Void)?

  init(
    manifest: Qwen3ModelManifest,
    ownedDirectory: URL,
    readOnlySeedDirectory: URL?,
    runtime: ModelRuntime,
    downloader: ModelFileDownloading = URLSessionModelFileDownloader(),
    fileManager: FileManager = .default
  ) {
    self.manifest = manifest
    self.ownedDirectory = ownedDirectory
    self.readOnlySeedDirectory = readOnlySeedDirectory
    self.runtime = runtime
    self.downloader = downloader
    self.fileManager = fileManager
    selectedSource = manifest.sources[0]
  }

  func observe(_ handler: @escaping (ModelManagerStatus) -> Void) -> UUID {
    requireMainThread()
    let identifier = UUID()
    observers[identifier] = handler
    handler(status)
    return identifier
  }

  func removeObserver(_ identifier: UUID) {
    requireMainThread()
    observers[identifier] = nil
  }

  func bootstrap() {
    requireMainThread()
    let operation = beginOperation()
    publish(.checking)
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let ownedValidation = ModelFileVerifier.validateDirectory(
        self.ownedDirectory,
        manifest: self.manifest,
        fileManager: self.fileManager
      )
      DispatchQueue.main.async {
        guard self.isCurrent(operation) else {
          return
        }
        switch ownedValidation.state {
        case .valid:
          self.loadValidatedModel(
            directory: self.ownedDirectory,
            isReadOnly: false,
            generation: operation
          )
        case .invalid:
          self.publish(.repairRequired("模型文件不完整或校验失败"))
        case .missing:
          self.loadReadOnlySeedOrRequireRepair(generation: operation)
        }
      }
    }
  }

  func download(preferredSource: ModelDownloadSource? = nil) {
    requireMainThread()
    let operation = beginOperation()
    if let preferredSource {
      selectedSource = preferredSource
    }
    publish(
      .downloading(
        completedBytes: 0,
        totalBytes: manifest.totalBytes,
        sourceName: selectedSource.name
      )
    )
    waitForTransferToFinish { [weak self] in
      self?.unloadThenDownload(generation: operation)
    }
  }

  func pause() {
    requireMainThread()
    guard case .downloading = status else {
      return
    }
    _ = beginOperation()
    publish(.paused)
    downloader.cancel()
  }

  func repair() {
    requireMainThread()
    let operation = beginOperation()
    publish(.checking)
    waitForTransferToFinish { [weak self] in
      guard let self else {
        return
      }
      self.unloadThen(generation: operation) {
        self.queue.async { [weak self] in
          guard let self else {
            return
          }
          let removalResult = Result {
            if self.fileManager.fileExists(atPath: self.ownedDirectory.path) {
              try self.fileManager.removeItem(at: self.ownedDirectory)
            }
          }
          DispatchQueue.main.async {
            guard self.isCurrent(operation) else {
              return
            }
            guard case .success = removalResult else {
              self.publish(.failed("无法清理旧模型，请检查磁盘权限"))
              return
            }
            self.publish(
              .downloading(
                completedBytes: 0,
                totalBytes: self.manifest.totalBytes,
                sourceName: self.selectedSource.name
              )
            )
            self.startDownload(generation: operation)
          }
        }
      }
    }
  }

  func deleteOwnedModel() {
    requireMainThread()
    let operation = beginOperation()
    publish(.deleting)
    waitForTransferToFinish { [weak self] in
      guard let self else {
        return
      }
      self.unloadThen(generation: operation) {
        self.queue.async { [weak self] in
          guard let self else {
            return
          }
          let removalResult = Result {
            if self.fileManager.fileExists(atPath: self.ownedDirectory.path) {
              try self.fileManager.removeItem(at: self.ownedDirectory)
            }
          }
          DispatchQueue.main.async {
            guard self.isCurrent(operation) else {
              return
            }
            guard case .success = removalResult else {
              self.publish(.failed("无法删除模型，请检查磁盘权限"))
              return
            }
            self.loadReadOnlySeedOrRequireRepair(generation: operation)
          }
        }
      }
    }
  }

  private func unloadThenDownload(generation: UInt64) {
    unloadThen(generation: generation) { [weak self] in
      guard let self, self.isCurrent(generation) else {
        return
      }
      self.startDownload(generation: generation)
    }
  }

  private func unloadThen(generation: UInt64, _ work: @escaping () -> Void) {
    runtime.unload { [weak self] in
      guard let self, self.isCurrent(generation) else {
        return
      }
      work()
    }
  }

  private func startDownload(generation: UInt64) {
    requireMainThread()
    guard isCurrent(generation) else {
      return
    }
    queue.async { [weak self] in
      guard let self else {
        return
      }
      do {
        try self.fileManager.createDirectory(
          at: self.ownedDirectory,
          withIntermediateDirectories: true
        )
      } catch {
        DispatchQueue.main.async {
          guard self.isCurrent(generation) else {
            return
          }
          self.publish(.failed("无法创建模型目录，请检查磁盘空间"))
        }
        return
      }
      DispatchQueue.main.async {
        guard self.isCurrent(generation) else {
          return
        }
        self.currentDownloadedBytes = 0
        self.downloadFile(at: 0, checksumAttempt: 0, sourceIndex: 0, generation: generation)
      }
    }
  }

  private func downloadFile(
    at fileIndex: Int,
    checksumAttempt: Int,
    sourceIndex: Int,
    generation: UInt64
  ) {
    requireMainThread()
    guard isCurrent(generation) else {
      return
    }
    guard fileIndex < manifest.files.count else {
      verifyAndLoadDownloadedModel(generation: generation)
      return
    }

    let file = manifest.files[fileIndex]
    queue.async { [weak self] in
      guard let self,
        let destination = ModelFileVerifier.fileURL(
          directory: self.ownedDirectory,
          path: file.path
        )
      else {
        return
      }
      do {
        try self.fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      } catch {
        DispatchQueue.main.async {
          guard self.isCurrent(generation) else {
            return
          }
          self.publish(.failed("无法创建模型文件目录，请检查磁盘空间"))
        }
        return
      }
      if ModelFileVerifier.validateFile(destination, expected: file) {
        DispatchQueue.main.async {
          guard self.isCurrent(generation) else {
            return
          }
          self.currentDownloadedBytes = self.verifiedBytes(before: fileIndex) + file.size
          self.downloadFile(
            at: fileIndex + 1,
            checksumAttempt: 0,
            sourceIndex: 0,
            generation: generation
          )
        }
        return
      }

      try? self.fileManager.removeItem(at: destination)
      let partURL = destination.appendingPathExtension("part")
      let offset = self.safePartialOffset(partURL, expectedBytes: file.size)
      DispatchQueue.main.async {
        guard self.isCurrent(generation) else {
          return
        }
        self.beginTransfer(
          file: file,
          destination: destination,
          partURL: partURL,
          offset: offset,
          fileIndex: fileIndex,
          checksumAttempt: checksumAttempt,
          sourceIndex: sourceIndex,
          generation: generation
        )
      }
    }
  }

  private func beginTransfer(
    file: Qwen3ModelManifest.File,
    destination: URL,
    partURL: URL,
    offset: Int64,
    fileIndex: Int,
    checksumAttempt: Int,
    sourceIndex: Int,
    generation: UInt64
  ) {
    requireMainThread()
    guard isCurrent(generation), manifest.sources.indices.contains(sourceIndex) else {
      return
    }
    let source = orderedSources().dropFirst(sourceIndex).first ?? selectedSource
    let request = ModelDownloadRequest(
      url: source.fileURL(for: manifest, file: file),
      partURL: partURL,
      expectedBytes: file.size,
      resumeOffset: offset
    )
    transferInFlight = true
    currentDownloadedBytes = verifiedBytes(before: fileIndex) + offset
    publish(
      .downloading(
        completedBytes: currentDownloadedBytes,
        totalBytes: manifest.totalBytes,
        sourceName: source.name
      )
    )
    downloader.start(
      request,
      progress: { [weak self] bytesForFile in
        guard let self else {
          return
        }
        DispatchQueue.main.async {
          guard self.isCurrent(generation) else {
            return
          }
          self.currentDownloadedBytes = self.verifiedBytes(before: fileIndex) + bytesForFile
          self.publish(
            .downloading(
              completedBytes: self.currentDownloadedBytes,
              totalBytes: self.manifest.totalBytes,
              sourceName: source.name
            )
          )
        }
      },
      completion: { [weak self] result in
        self?.handleTransferCompletion(
          result,
          file: file,
          destination: destination,
          partURL: partURL,
          fileIndex: fileIndex,
          checksumAttempt: checksumAttempt,
          sourceIndex: sourceIndex,
          generation: generation
        )
      }
    )
  }

  private func handleTransferCompletion(
    _ result: Result<ModelTransferKind, ModelDownloadError>,
    file: Qwen3ModelManifest.File,
    destination: URL,
    partURL: URL,
    fileIndex: Int,
    checksumAttempt: Int,
    sourceIndex: Int,
    generation: UInt64
  ) {
    requireMainThread()
    transferInFlight = false
    if let pendingAfterTransfer {
      self.pendingAfterTransfer = nil
      pendingAfterTransfer()
      return
    }
    guard isCurrent(generation) else {
      return
    }

    switch result {
    case .failure:
      let nextSource = sourceIndex + 1
      guard nextSource < orderedSources().count else {
        publish(.failed("下载中断，请重试或切换下载源"))
        return
      }
      downloadFile(
        at: fileIndex,
        checksumAttempt: checksumAttempt,
        sourceIndex: nextSource,
        generation: generation
      )
    case .success(.rangeNotSatisfiable):
      verifyPartialAfterRangeNotSatisfiable(
        file: file,
        destination: destination,
        partURL: partURL,
        fileIndex: fileIndex,
        checksumAttempt: checksumAttempt,
        sourceIndex: sourceIndex,
        generation: generation
      )
    case .success:
      verifyDownloadedPart(
        file: file,
        destination: destination,
        partURL: partURL,
        fileIndex: fileIndex,
        checksumAttempt: checksumAttempt,
        sourceIndex: sourceIndex,
        generation: generation
      )
    }
  }

  private func verifyPartialAfterRangeNotSatisfiable(
    file: Qwen3ModelManifest.File,
    destination: URL,
    partURL: URL,
    fileIndex: Int,
    checksumAttempt: Int,
    sourceIndex: Int,
    generation: UInt64
  ) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let partIsComplete = ModelFileVerifier.validateFile(partURL, expected: file)
      if partIsComplete {
        try? self.fileManager.removeItem(at: destination)
        try? self.fileManager.moveItem(at: partURL, to: destination)
      } else {
        try? self.fileManager.removeItem(at: partURL)
      }
      DispatchQueue.main.async {
        guard self.isCurrent(generation) else {
          return
        }
        if partIsComplete {
          self.currentDownloadedBytes = self.verifiedBytes(before: fileIndex) + file.size
          self.downloadFile(
            at: fileIndex + 1,
            checksumAttempt: 0,
            sourceIndex: 0,
            generation: generation
          )
        } else {
          self.downloadFile(
            at: fileIndex,
            checksumAttempt: checksumAttempt,
            sourceIndex: sourceIndex,
            generation: generation
          )
        }
      }
    }
  }

  private func verifyDownloadedPart(
    file: Qwen3ModelManifest.File,
    destination: URL,
    partURL: URL,
    fileIndex: Int,
    checksumAttempt: Int,
    sourceIndex: Int,
    generation: UInt64
  ) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let isValid = ModelFileVerifier.validateFile(partURL, expected: file)
      if isValid {
        try? self.fileManager.removeItem(at: destination)
        do {
          try self.fileManager.moveItem(at: partURL, to: destination)
        } catch {
          DispatchQueue.main.async {
            guard self.isCurrent(generation) else {
              return
            }
            self.publish(.failed("无法保存模型文件，请检查磁盘空间"))
          }
          return
        }
      } else {
        try? self.fileManager.removeItem(at: partURL)
      }
      DispatchQueue.main.async {
        guard self.isCurrent(generation) else {
          return
        }
        if isValid {
          self.currentDownloadedBytes = self.verifiedBytes(before: fileIndex) + file.size
          self.downloadFile(
            at: fileIndex + 1,
            checksumAttempt: 0,
            sourceIndex: 0,
            generation: generation
          )
        } else if checksumAttempt == 0 {
          self.downloadFile(
            at: fileIndex,
            checksumAttempt: 1,
            sourceIndex: 0,
            generation: generation
          )
        } else {
          self.publish(.failed("模型校验失败，请重新下载"))
        }
      }
    }
  }

  private func verifyAndLoadDownloadedModel(generation: UInt64) {
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let validation = ModelFileVerifier.validateDirectory(
        self.ownedDirectory,
        manifest: self.manifest,
        fileManager: self.fileManager
      )
      DispatchQueue.main.async {
        guard self.isCurrent(generation) else {
          return
        }
        guard validation.state == .valid else {
          self.publish(.failed("模型校验失败，请重新下载"))
          return
        }
        self.loadValidatedModel(
          directory: self.ownedDirectory,
          isReadOnly: false,
          generation: generation
        )
      }
    }
  }

  private func loadReadOnlySeedOrRequireRepair(generation: UInt64) {
    requireMainThread()
    guard isCurrent(generation) else {
      return
    }
    guard let readOnlySeedDirectory else {
      publish(.repairRequired("语音模型尚未下载"))
      return
    }
    queue.async { [weak self] in
      guard let self else {
        return
      }
      let validation = ModelFileVerifier.validateDirectory(
        readOnlySeedDirectory,
        manifest: self.manifest,
        fileManager: self.fileManager
      )
      DispatchQueue.main.async {
        guard self.isCurrent(generation) else {
          return
        }
        guard validation.state == .valid else {
          self.publish(.repairRequired("语音模型尚未下载"))
          return
        }
        self.loadValidatedModel(
          directory: readOnlySeedDirectory,
          isReadOnly: true,
          generation: generation
        )
      }
    }
  }

  private func loadValidatedModel(directory: URL, isReadOnly: Bool, generation: UInt64) {
    requireMainThread()
    guard isCurrent(generation) else {
      return
    }
    publish(.loading)
    runtime.load(files: Qwen3ModelFiles(dir: directory)) { [weak self] result in
      guard let self, self.isCurrent(generation) else {
        return
      }
      switch result {
      case .success:
        self.publish(.ready(location: directory, isReadOnly: isReadOnly))
      case .failure:
        self.publish(.failed("模型加载失败，请修复后重试"))
      }
    }
  }

  private func waitForTransferToFinish(_ work: @escaping () -> Void) {
    requireMainThread()
    if transferInFlight {
      pendingAfterTransfer = work
      downloader.cancel()
      return
    }
    work()
  }

  @discardableResult
  private func beginOperation() -> UInt64 {
    requireMainThread()
    generation &+= 1
    onWillMutate?()
    return generation
  }

  private func isCurrent(_ candidate: UInt64) -> Bool {
    requireMainThread()
    return candidate == generation
  }

  private func publish(_ newStatus: ModelManagerStatus) {
    requireMainThread()
    status = newStatus
    for handler in observers.values {
      handler(newStatus)
    }
  }

  private func orderedSources() -> [ModelDownloadSource] {
    [selectedSource] + manifest.sources.filter { $0.id != selectedSource.id }
  }

  private func safePartialOffset(_ partURL: URL, expectedBytes: Int64) -> Int64 {
    guard
      let values = try? partURL.resourceValues(forKeys: [.fileSizeKey]),
      let size = values.fileSize
    else {
      return 0
    }
    let offset = Int64(size)
    guard offset <= expectedBytes else {
      try? fileManager.removeItem(at: partURL)
      return 0
    }
    return offset
  }

  private func verifiedBytes(before fileIndex: Int) -> Int64 {
    manifest.files.prefix(fileIndex).reduce(Int64.zero) { partial, file in
      partial + file.size
    }
  }
}

private func requireMainThread() {
  dispatchPrecondition(condition: .onQueue(.main))
}
