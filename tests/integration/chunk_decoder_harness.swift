import Foundation
import ShanshuoCore

// The exercised overload injects decodeChunk. This stand-in only satisfies the production file's
// runtime overload without linking the sherpa C bridge into this focused harness.
final class Qwen3Recognizer {
  func transcribe(_ samples: [Float], sampleRate: Int, hotwords: [String]) -> String {
    "unused"
  }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
enum ChunkDecoderHarness {
  static func main() {
    var zeroDecodeCalls = 0
    let zero = Qwen3ChunkDecoder.decode(
      samples: Array(repeating: 0, count: 16_000),
      sampleRate: 16_000,
      decodeChunk: { _, _, _ in
        zeroDecodeCalls += 1
        return "must not run"
      }
    )
    check(zeroDecodeCalls == 0, "digital silence must not invoke the model")
    check(zero.decodedChunkCount == 0 && zero.text.isEmpty, "digital silence has no transcript")

    var quietDecodeCalls = 0
    let quietSpeech = Qwen3ChunkDecoder.decode(
      samples: [0, 0.000_47, -0.000_88, 0],
      sampleRate: 16_000,
      decodeChunk: { _, _, _ in
        quietDecodeCalls += 1
        return "quiet speech"
      }
    )
    check(quietDecodeCalls == 1, "low-amplitude finite speech reaches the decoder")
    check(quietSpeech.text == "quiet speech", "low-amplitude text survives the shared decode path")

    var longAudioDecodeCalls = 0
    var longAudio = Array(repeating: Float.zero, count: 20 * 16_000)
    longAudio.append(contentsOf: [0, 0.000_2, 0])
    let longResult = Qwen3ChunkDecoder.decode(
      samples: longAudio,
      sampleRate: 16_000,
      decodeChunk: { _, _, _ in
        longAudioDecodeCalls += 1
        return "tail"
      }
    )
    check(longResult.chunkCount == 2, "long input still uses bounded twenty-second chunks")
    check(longAudioDecodeCalls == 1, "silent leading chunk is skipped without dropping quiet tail")
    check(longResult.text == "tail", "tail text is retained without duplication")

    var nonFiniteDecodeCalls = 0
    let nonFinite = Qwen3ChunkDecoder.decode(
      samples: [.nan, .infinity, -.infinity],
      sampleRate: 16_000,
      decodeChunk: { _, _, _ in
        nonFiniteDecodeCalls += 1
        return "must not run"
      }
    )
    check(nonFiniteDecodeCalls == 0, "non-finite samples are not decoded")
    check(nonFinite.text.isEmpty, "non-finite-only input has no transcript")

    var mixedDecodeChunk: [Float] = []
    let mixedFinite = Qwen3ChunkDecoder.decode(
      samples: [.nan, 0.000_47, .infinity, -0.000_88],
      sampleRate: 16_000,
      decodeChunk: { samples, _, _ in
        mixedDecodeChunk = samples
        return "quiet speech"
      }
    )
    check(
      mixedFinite.decodedChunkCount == 1, "finite quiet speech still decodes beside corrupt values")
    check(
      mixedDecodeChunk.allSatisfy(\.isFinite),
      "the production decoder replaces non-finite samples before native recognition"
    )

    print("chunk decoder harness passed")
  }
}
