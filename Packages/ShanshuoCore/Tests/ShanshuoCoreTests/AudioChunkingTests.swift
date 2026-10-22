import Testing

@testable import ShanshuoCore

@Suite("Audio chunking")
struct AudioChunkingTests {
  @Test("twenty-second chunks cover every sample once")
  func coversInputWithoutOverlap() {
    let ranges = AudioChunking.ranges(sampleCount: 1_000_003, sampleRate: 16_000)
    #expect(ranges.first == 0..<320_000)
    #expect(ranges.last?.upperBound == 1_000_003)
    #expect(ranges.reduce(0) { $0 + $1.count } == 1_000_003)

    for pair in zip(ranges, ranges.dropFirst()) {
      #expect(pair.0.upperBound == pair.1.lowerBound)
    }
  }

  @Test("empty input creates no recognizer work and English chunks keep a word boundary")
  func emptyAndTextJoining() {
    #expect(AudioChunking.ranges(sampleCount: 0, sampleRate: 16_000).isEmpty)
    #expect(!AudioChunking.hasAudibleSignal(Array(repeating: 0, count: 320_000)))
    #expect(AudioChunking.hasAudibleSignal([0, 0.01, 0]))
    #expect(AudioChunking.join(["ship", "the build"]) == "ship the build")
    #expect(AudioChunking.join(["今天", "开会"]) == "今天开会")
  }
}
