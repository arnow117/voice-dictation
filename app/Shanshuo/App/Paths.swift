import Foundation

enum Paths {
  static let modelKey = "qwen3-asr-0.6b-int8"

  static var appSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Shanshuo", isDirectory: true)
  }

  /// The only directory that ModelManager may write or delete.
  static var ownedModelDirectory: URL {
    appSupport.appendingPathComponent("Models/\(modelKey)", isDirectory: true)
  }

  static var historyDirectory: URL {
    appSupport.appendingPathComponent("History", isDirectory: true)
  }

  /// Development and test overrides are deliberately read-only seeds. T012 can load a verified
  /// seed for local development, but delete/repair always target `ownedModelDirectory`.
  static var readOnlyModelSeedDirectory: URL? {
    if let env = ProcessInfo.processInfo.environment["SHANSHUO_MODEL_DIR"], !env.isEmpty {
      return URL(fileURLWithPath: env, isDirectory: true)
    }
    if let dev = Bundle.main.object(forInfoDictionaryKey: "ShanshuoDevModelDir") as? String,
      !dev.isEmpty, FileManager.default.fileExists(atPath: dev)
    {
      return URL(fileURLWithPath: dev, isDirectory: true)
    }
    return nil
  }

  /// Explicit developer CLI behavior. The menu-bar app uses ModelManager's canonical owned path
  /// and optional read-only seed instead.
  static var modelDir: URL {
    readOnlyModelSeedDirectory ?? ownedModelDirectory
  }

  static var buildID: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
  }
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
  }
}
