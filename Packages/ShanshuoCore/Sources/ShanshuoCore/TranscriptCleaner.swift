import Foundation

/// Cleans raw recogniser output before it reaches insertion.
///
/// Returns `nil` when the output carries no speech: empty, punctuation only, or a bare chat-role
/// token. Qwen3-ASR is an LLM decoder and can emit "system" on its own (FEAT-001 T001 hotword run);
/// that must never be typed into the user's field.
public enum TranscriptCleaner {
  static let roleTokens: Set<String> = ["system", "user", "assistant"]

  public static func clean(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    if letters.isEmpty { return nil }
    let bare = String(String.UnicodeScalarView(letters)).lowercased()
    if roleTokens.contains(bare) && text.split(whereSeparator: \.isWhitespace).count == 1 {
      return nil
    }
    return text
  }
}
