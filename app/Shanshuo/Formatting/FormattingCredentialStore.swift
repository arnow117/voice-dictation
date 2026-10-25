import Foundation
import ShanshuoCore

enum FormattingCredentialError: Error, Equatable {
  case emptyCredential
  case missing
}

/// Holds MiniMax credentials for this process only. It deliberately has no system-Keychain
/// implementation: importing, saving, reading, or forgetting a formatting key must never open a
/// password prompt. Configuration persists only the selected non-sensitive model and endpoint.
final class FormattingCredentialStore {
  private let lock = NSLock()
  private var credentials: [String: String] = [:]

  func save(_ credential: String) throws -> FormattingCredentialDescriptor {
    let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw FormattingCredentialError.emptyCredential
    }

    let reference = UUID().uuidString.lowercased()
    lock.lock()
    credentials[reference] = trimmed
    lock.unlock()
    return FormattingCredentialDescriptor(reference: reference, hint: maskedHint(for: trimmed))
  }

  func read(reference: String) throws -> String {
    lock.lock()
    let credential = credentials[reference]
    lock.unlock()
    guard let credential else {
      throw FormattingCredentialError.missing
    }
    return credential
  }

  func remove(reference: String) {
    lock.lock()
    credentials[reference] = nil
    lock.unlock()
  }

  private func maskedHint(for credential: String) -> String {
    let suffix = String(credential.suffix(4))
    return "••••\(suffix)"
  }
}
