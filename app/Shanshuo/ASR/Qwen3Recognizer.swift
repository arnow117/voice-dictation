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
    let fm = FileManager.default
    var out: [String] = []
    for u in [convFrontend, encoder, decoder] where !fm.fileExists(atPath: u.path) {
      out.append(u.lastPathComponent)
    }
    for f in ["vocab.json", "merges.txt", "tokenizer_config.json"]
    where !fm.fileExists(atPath: tokenizer.appendingPathComponent(f).path) {
      out.append("tokenizer/\(f)")
    }
    return out
  }
}

enum ASRError: Error, CustomStringConvertible {
  case modelMissing([String])
  case createFailed

  var description: String {
    switch self {
    case .modelMissing(let f): return "语音模型文件缺失：\(f.joined(separator: "、"))"
    case .createFailed: return "语音模型加载失败"
    }
  }
}

/// In-process Qwen3-ASR recogniser over the sherpa-onnx C API. Not thread-safe: the caller serialises
/// all calls on one queue (ED-014: a userInitiated serial queue so decoding is not parked on E-cores).
final class Qwen3Recognizer {
  static let sampleRate = 16_000
  private let handle: OpaquePointer

  /// - Parameters:
  ///   - maxTotalLen: prompt + one bounded audio chunk + output token budget. The app splits a
  ///     three-minute recording into contiguous 20-second chunks before calling this method, so
  ///     1,024 tokens caps the runtime allocation without truncating or overlapping audio.
  init(files: Qwen3ModelFiles, threads: Int = 4, maxTotalLen: Int = 1_024, maxNewTokens: Int = 512)
    throws
  {
    let missing = files.missing
    guard missing.isEmpty else { throw ASRError.modelMissing(missing) }

    var owned: [UnsafeMutablePointer<CChar>] = []
    func c(_ s: String) -> UnsafePointer<CChar> {
      let p = strdup(s)!
      owned.append(p)
      return UnsafePointer(p)
    }
    defer {
      for pointer in owned {
        free(pointer)
      }
    }

    var config = SherpaOnnxOfflineRecognizerConfig()
    config.feat_config.sample_rate = Int32(Self.sampleRate)
    config.feat_config.feature_dim = 128
    config.decoding_method = c("greedy_search")
    config.model_config.num_threads = Int32(threads)
    config.model_config.provider = c("cpu")
    config.model_config.debug = 0
    config.model_config.qwen3_asr.conv_frontend = c(files.convFrontend.path)
    config.model_config.qwen3_asr.encoder = c(files.encoder.path)
    config.model_config.qwen3_asr.decoder = c(files.decoder.path)
    config.model_config.qwen3_asr.tokenizer = c(files.tokenizer.path)
    config.model_config.qwen3_asr.max_total_len = Int32(maxTotalLen)
    config.model_config.qwen3_asr.max_new_tokens = Int32(maxNewTokens)
    config.model_config.qwen3_asr.temperature = 1e-6
    config.model_config.qwen3_asr.top_p = 0.8
    config.model_config.qwen3_asr.seed = 42
    config.model_config.qwen3_asr.hotwords = c("")

    guard let h = SherpaOnnxCreateOfflineRecognizer(&config) else { throw ASRError.createFailed }
    handle = h
  }

  deinit { SherpaOnnxDestroyOfflineRecognizer(handle) }

  /// Recognise one utterance. `samples` are mono Float32 in [-1, 1].
  /// `hotwords` are passed per call through the stream option (Qwen3-ASR reads it; no rebuild).
  func transcribe(
    _ samples: [Float], sampleRate: Int = Qwen3Recognizer.sampleRate, hotwords: [String] = []
  ) -> String {
    guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(handle) else { return "" }
    defer { SherpaOnnxDestroyOfflineStream(stream) }
    if !hotwords.isEmpty {
      SherpaOnnxOfflineStreamSetOption(stream, "hotwords", hotwords.joined(separator: ","))
    }
    samples.withUnsafeBufferPointer { buf in
      SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), buf.baseAddress, Int32(buf.count))
    }
    SherpaOnnxDecodeOfflineStream(handle, stream)
    guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
    defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
    return result.pointee.text.map { String(cString: $0) } ?? ""
  }
}

/// Reads a WAV file through sherpa-onnx (used by the CLI mode and the WAV-driven test build).
func readWave(_ path: String) -> (samples: [Float], sampleRate: Int)? {
  guard let w = SherpaOnnxReadWave(path) else { return nil }
  defer { SherpaOnnxFreeWave(w) }
  let n = Int(w.pointee.num_samples)
  let samples = Array(UnsafeBufferPointer(start: w.pointee.samples, count: n))
  return (samples, Int(w.pointee.sample_rate))
}
