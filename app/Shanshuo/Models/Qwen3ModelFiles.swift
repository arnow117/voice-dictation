import Foundation

/// Files of the pinned `sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25` package (FEAT-001 ED-002, ED-009).
struct Qwen3ModelFiles {
  let dir: URL

  var convFrontend: URL { dir.appendingPathComponent("conv_frontend.onnx") }
  var encoder: URL { dir.appendingPathComponent("encoder.int8.onnx") }
  var decoder: URL { dir.appendingPathComponent("decoder.int8.onnx") }
  var tokenizer: URL { dir.appendingPathComponent("tokenizer") }

  /// Names of required files that are missing; empty when the model is usable.
  var missing: [String] {
    let fileManager = FileManager.default
    var missingFiles: [String] = []
    for url in [convFrontend, encoder, decoder] where !fileManager.fileExists(atPath: url.path) {
      missingFiles.append(url.lastPathComponent)
    }
    for fileName in ["vocab.json", "merges.txt", "tokenizer_config.json"]
    where !fileManager.fileExists(atPath: tokenizer.appendingPathComponent(fileName).path) {
      missingFiles.append("tokenizer/\(fileName)")
    }
    return missingFiles
  }
}
