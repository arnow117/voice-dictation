import CryptoKit
import Foundation

enum ModelManifestError: Error {
  case missingBundledManifest
  case invalidBundledManifest
  case unsafeFilePath
}

struct ModelDownloadSource: Codable, Equatable {
  let id: String
  let name: String
  let baseURL: URL

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case baseURL = "base_url"
  }

  func fileURL(for manifest: Qwen3ModelManifest, file: Qwen3ModelManifest.File) -> URL {
    let repositoryParts = manifest.repository.split(separator: "/").map(String.init)
    let fileParts = file.path.split(separator: "/").map(String.init)
    return (repositoryParts + ["resolve", manifest.revision] + fileParts)
      .reduce(baseURL) { partial, component in
        partial.appendingPathComponent(component, isDirectory: false)
      }
  }
}

struct Qwen3ModelManifest: Codable, Equatable {
  struct File: Codable, Equatable {
    let path: String
    let size: Int64
    let sha256: String
  }

  let modelKey: String
  let displayName: String
  let repository: String
  let revision: String
  let license: String
  let totalBytes: Int64
  let sources: [ModelDownloadSource]
  let files: [File]

  enum CodingKeys: String, CodingKey {
    case modelKey = "model_key"
    case displayName = "display_name"
    case repository
    case revision
    case license
    case totalBytes = "total_bytes"
    case sources
    case files
  }

  static func loadBundled(bundle: Bundle = .main) throws -> Qwen3ModelManifest {
    guard let url = bundle.url(forResource: "Qwen3ModelManifest", withExtension: "json") else {
      throw ModelManifestError.missingBundledManifest
    }
    guard
      let manifest = try? JSONDecoder().decode(
        Qwen3ModelManifest.self,
        from: Data(contentsOf: url)
      )
    else {
      throw ModelManifestError.invalidBundledManifest
    }
    try manifest.validate()
    return manifest
  }

  func validate() throws {
    guard
      modelKey == "qwen3-asr-0.6b-int8",
      repository == "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
      revision == "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a",
      files.count == 6,
      files.reduce(Int64.zero, { $0 + $1.size }) == totalBytes,
      sources.allSatisfy({ $0.baseURL.scheme == "https" })
    else {
      throw ModelManifestError.invalidBundledManifest
    }
    for file in files {
      guard
        file.size > 0,
        file.sha256.count == 64,
        file.sha256.allSatisfy({ $0.isHexDigit }),
        safePathComponents(file.path) != nil
      else {
        throw ModelManifestError.unsafeFilePath
      }
    }
  }
}

struct ModelFileVerification: Equatable {
  enum State: Equatable {
    case valid
    case missing
    case invalid
  }

  let state: State
  let verifiedBytes: Int64
}

enum ModelFileVerifier {
  static func validateDirectory(
    _ directory: URL,
    manifest: Qwen3ModelManifest,
    fileManager: FileManager = .default
  ) -> ModelFileVerification {
    var verifiedBytes: Int64 = 0
    let directoryHasContents =
      (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty == false) ?? false

    for file in manifest.files {
      guard let url = fileURL(directory: directory, path: file.path) else {
        return ModelFileVerification(state: .invalid, verifiedBytes: verifiedBytes)
      }
      let partURL = url.appendingPathExtension("part")
      guard fileManager.fileExists(atPath: url.path) else {
        return ModelFileVerification(
          state: directoryHasContents || fileManager.fileExists(atPath: partURL.path)
            ? .invalid : .missing,
          verifiedBytes: verifiedBytes
        )
      }
      guard validateFile(url, expected: file) else {
        return ModelFileVerification(state: .invalid, verifiedBytes: verifiedBytes)
      }
      verifiedBytes += file.size
    }

    return ModelFileVerification(state: .valid, verifiedBytes: verifiedBytes)
  }

  static func validateFile(_ url: URL, expected: Qwen3ModelManifest.File) -> Bool {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber,
      size.int64Value == expected.size,
      let digest = sha256(url),
      digest.caseInsensitiveCompare(expected.sha256) == .orderedSame
    else {
      return false
    }
    return true
  }

  static func sha256(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer { try? handle.close() }

    do {
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: 1 << 20) {
        guard !chunk.isEmpty else {
          break
        }
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      return nil
    }
  }

  static func fileURL(directory: URL, path: String) -> URL? {
    guard let components = safePathComponents(path) else {
      return nil
    }
    return components.reduce(directory) { partial, component in
      partial.appendingPathComponent(component, isDirectory: false)
    }
  }
}

private func safePathComponents(_ path: String) -> [String]? {
  let components = path.split(separator: "/").map(String.init)
  guard
    !components.isEmpty,
    components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
  else {
    return nil
  }
  return components
}

protocol ModelRuntime: AnyObject {
  func load(files: Qwen3ModelFiles, completion: @escaping (Result<Void, Error>) -> Void)
  func unload(completion: @escaping () -> Void)
}
