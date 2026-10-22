import Foundation

/// Bounded-memory chunks for Qwen3-ASR. Adjacent ranges meet exactly: audio samples are never
/// duplicated or skipped, while each recognizer invocation stays below the runtime token limit.
public enum AudioChunking {
  public static let maximumChunkDuration = TimeInterval(20)

  /// Avoids invoking the generative recognizer for digital silence while preserving low-level
  /// speech. This is deliberately not voice activity detection: any finite non-zero sample may
  /// be meaningful and must reach the model. Non-finite samples are ignored so corrupt input does
  /// not become a signal or contaminate a later recognizer call.
  public static func hasNonZeroFiniteSignal(_ samples: [Float]) -> Bool {
    samples.contains { sample in
      sample.isFinite && sample != 0
    }
  }

  /// Keeps corrupt numeric values out of the native recognizer without applying amplitude
  /// thresholding to valid quiet speech. Callers first use `hasNonZeroFiniteSignal` so an all-zero
  /// or non-finite chunk still avoids recognizer work altogether.
  public static func sanitizedForRecognition(_ samples: [Float]) -> [Float] {
    samples.map { sample in
      sample.isFinite ? sample : 0
    }
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
