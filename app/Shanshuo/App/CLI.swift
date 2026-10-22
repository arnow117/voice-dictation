import Foundation
import ShanshuoCore

/// `Shanshuo --transcribe a.wav [b.wav ...] [--model-dir D] [--threads N] [--hotwords a,b] [--out f.jsonl]`
/// Prints one JSON line per file (or appends them to `--out`, used when launched through `open` so the
/// process runs under launchd with normal core scheduling). Developer/test entry only; the menu-bar app never prints text.
enum CLI {
  private static var outHandle: FileHandle?

  static func transcribe(_ args: [String]) -> Int32 {
    var files: [String] = []
    var modelDir = Paths.modelDir
    var threads = 4
    var hotwords: [String] = []
    var i = 0
    while i < args.count {
      switch args[i] {
      case "--model-dir":
        i += 1
        modelDir = URL(fileURLWithPath: args[i], isDirectory: true)
      case "--threads":
        i += 1
        threads = Int(args[i]) ?? threads
      case "--hotwords":
        i += 1
        hotwords = args[i].split(separator: ",").map(String.init)
      case "--out":
        i += 1
        FileManager.default.createFile(atPath: args[i], contents: nil)
        outHandle = FileHandle(forWritingAtPath: args[i])
      default: files.append(args[i])
      }
      i += 1
    }
    let queue = DispatchQueue(label: "com.arnow117.shanshuo.asr", qos: .userInitiated)
    var code: Int32 = 0
    queue.sync {
      let t0 = Date()
      let recognizer: Qwen3Recognizer
      do {
        recognizer = try Qwen3Recognizer(files: Qwen3ModelFiles(dir: modelDir), threads: threads)
      } catch {
        emit(["error": "\(error)", "model_dir": modelDir.path])
        code = 2
        return
      }
      let load = Date().timeIntervalSince(t0)
      emit(["event": "loaded", "load_s": round3(load), "threads": threads, "rss_mb": residentMB()])
      for f in files {
        guard let wav = readWave(f) else {
          emit(["file": f, "error": "cannot read wav"])
          code = 1
          continue
        }
        let t1 = Date()
        let decoding = Qwen3ChunkDecoder.decode(
          samples: wav.samples,
          sampleRate: wav.sampleRate,
          recognizer: recognizer,
          hotwords: hotwords
        )
        let dt = Date().timeIntervalSince(t1)
        let audio = Double(wav.samples.count) / Double(wav.sampleRate)
        emit([
          "file": (f as NSString).lastPathComponent,
          "text": decoding.text,
          "chunk_count": decoding.chunkCount,
          "decoded_chunk_count": decoding.decodedChunkCount,
          "audio_s": round3(audio),
          "decode_s": round3(dt),
          "rtf": round3(dt / max(audio, 0.001)),
        ])
      }
      emit(["event": "done", "rss_mb": residentMB()])
    }
    return code
  }

  private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

  private static func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(
      withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
      let s = String(data: d, encoding: .utf8)
    {
      if let h = outHandle {
        h.write((s + "\n").data(using: .utf8)!)
      } else {
        print(s)
        fflush(stdout)
      }
    }
  }
}

/// Resident set size of this process in MB (task_info), for the NFR memory checks.
func residentMB() -> Int {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
}
