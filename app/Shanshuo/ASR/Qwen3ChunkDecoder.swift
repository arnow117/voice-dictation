import Foundation
import ShanshuoCore

struct Qwen3ChunkDecodingResult {
  let text: String
  let chunkCount: Int
  let decodedChunkCount: Int
}

/// Uses the exact same bounded, contiguous decode path for live microphone audio and the explicit
/// developer CLI. A chunk is copied only for the duration of its synchronous recognizer call.
enum Qwen3ChunkDecoder {
  static func decode(
    samples: [Float],
    sampleRate: Int,
    hotwords: [String] = [],
    shouldContinue: () -> Bool = { true },
    decodeChunk: ([Float], Int, [String]) -> String
  ) -> Qwen3ChunkDecodingResult {
    let ranges = AudioChunking.ranges(sampleCount: samples.count, sampleRate: sampleRate)
    var transcripts: [String] = []
    var decodedChunkCount = 0

    for range in ranges {
      guard shouldContinue() else {
        break
      }
      let rawChunk = Array(samples[range])
      guard AudioChunking.hasNonZeroFiniteSignal(rawChunk) else {
        continue
      }
      let chunk = AudioChunking.sanitizedForRecognition(rawChunk)
      decodedChunkCount += 1
      let rawText = decodeChunk(chunk, sampleRate, hotwords)
      if let transcript = TranscriptCleaner.clean(rawText) {
        transcripts.append(transcript)
      }
    }

    return Qwen3ChunkDecodingResult(
      text: AudioChunking.join(transcripts),
      chunkCount: ranges.count,
      decodedChunkCount: decodedChunkCount
    )
  }

  static func decode(
    samples: [Float],
    sampleRate: Int,
    recognizer: Qwen3Recognizer,
    hotwords: [String] = []
  ) -> Qwen3ChunkDecodingResult {
    decode(
      samples: samples,
      sampleRate: sampleRate,
      hotwords: hotwords,
      decodeChunk: { chunk, chunkSampleRate, chunkHotwords in
        recognizer.transcribe(chunk, sampleRate: chunkSampleRate, hotwords: chunkHotwords)
      }
    )
  }
}
