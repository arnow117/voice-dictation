import Foundation

enum Paths {
  static let modelKey = "qwen3-asr-0.6b-int8"

  static var appSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Shanshuo", isDirectory: true)
  }

  /// Where the recogniser looks for model files, in order: `SHANSHUO_MODEL_DIR` (tests),
  /// `ShanshuoDevModelDir` baked into dev builds by scripts/build.sh, then Application Support (T012 downloads here).
  static var modelDir: URL {
    if let env = ProcessInfo.processInfo.environment["SHANSHUO_MODEL_DIR"], !env.isEmpty {
      return URL(fileURLWithPath: env, isDirectory: true)
    }
    if let dev = Bundle.main.object(forInfoDictionaryKey: "ShanshuoDevModelDir") as? String,
      !dev.isEmpty, FileManager.default.fileExists(atPath: dev)
    {
      return URL(fileURLWithPath: dev, isDirectory: true)
    }
    return appSupport.appendingPathComponent("Models/\(modelKey)", isDirectory: true)
  }

  static var buildID: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
  }
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
  }
}
