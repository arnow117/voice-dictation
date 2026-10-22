import Foundation

/// Bounded-memory chunks for Qwen3-ASR. Adjacent ranges meet exactly: audio samples are never
/// duplicated or skipped, while each recognizer invocation stays below the runtime token limit.
public enum AudioChunking {
  public static let maximumChunkDuration = TimeInterval(20)

  /// Avoids asking the generative recognizer to decode an entirely silent chunk. A zero-valued
  /// test fixture must not become a hallucinated insertion. The threshold is deliberately low so
  /// ordinary quiet speech is still sent to the model.
  public static func hasAudibleSignal(_ samples: [Float], minimumRMS: Float = 0.001) -> Bool {
    guard !samples.isEmpty else {
      return false
    }

    let meanSquare =
      samples.reduce(Float.zero) { partial, sample in
        partial + sample * sample
      } / Float(samples.count)
    return sqrt(meanSquare) >= minimumRMS
  }

  public static func ranges(
    sampleCount: Int,
    sampleRate: Int,
    maximumDuration: TimeInterval = maximumChunkDuration
  ) -> [Range<Int>] {
    guard sampleCount > 0, sampleRate > 0 else {
      return []
    }

    let chunkSize = max(1, Int((Double(sampleRate) * maximumDuration).rounded(.down)))
    var result: [Range<Int>] = []
    var start = 0

    while start < sampleCount {
      let end = min(sampleCount, start + chunkSize)
      result.append(start..<end)
      start = end
    }

    return result
  }

  /// Keeps Chinese continuous while avoiding accidental word concatenation in English chunks.
  public static func join(_ transcripts: [String]) -> String {
    transcripts.reduce("") { partial, transcript in
      let next = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !next.isEmpty else {
        return partial
      }
      guard let last = partial.unicodeScalars.last, let first = next.unicodeScalars.first else {
        return partial + next
      }
      let needsSpace = isASCIIAlphaNumeric(last) && isASCIIAlphaNumeric(first)
      return partial + (needsSpace ? " " : "") + next
    }
  }

  private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48...57, 65...90, 97...122:
      return true
    default:
      return false
    }
  }
}
