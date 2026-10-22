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
    recognizer: Qwen3Recognizer,
    hotwords: [String] = []
  ) -> Qwen3ChunkDecodingResult {
    let ranges = AudioChunking.ranges(sampleCount: samples.count, sampleRate: sampleRate)
    var transcripts: [String] = []
    var decodedChunkCount = 0

    for range in ranges {
      let chunk = Array(samples[range])
      guard AudioChunking.hasAudibleSignal(chunk) else {
        continue
      }
      decodedChunkCount += 1
      let rawText = recognizer.transcribe(chunk, sampleRate: sampleRate, hotwords: hotwords)
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
}
