import Foundation
import ShanshuoCore

/// Persists only non-sensitive formatting preferences. MiniMax credentials, a passed connection
/// test, informed consent, and enabled state are valid only for the current process.
final class FormattingConfigurationStore {
  private struct StoredState: Codable {
    var snapshot: FormattingConfigurationSnapshot
    var successfulTest: FormattingConnectionTestTicket?
  }

  private enum Key {
    static let state = "formatting.configuration.v1"
  }

  private let defaults: UserDefaults
  private var state: StoredState
  private var observers: [UUID: (FormattingConfigurationSnapshot) -> Void] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Key.state),
      let saved = try? JSONDecoder().decode(StoredState.self, from: data)
    {
      state = StoredState(
        snapshot: FormattingConfigurationSnapshot(
          enabled: false,
          model: saved.snapshot.model,
          endpoint: saved.snapshot.endpoint,
          credential: nil,
          consentVersion: nil,
          revision: saved.snapshot.revision &+ 1,
          testGeneration: saved.snapshot.testGeneration &+ 1
        ),
        successfulTest: nil
      )
      persist()
    } else {
      state = StoredState(
        snapshot: FormattingConfigurationSnapshot(
          enabled: false,
          model: .flash,
          endpoint: .domestic,
          credential: nil,
          consentVersion: nil,
          revision: 0,
          testGeneration: 0
        ),
        successfulTest: nil
      )
    }
  }

  func snapshot() -> FormattingConfigurationSnapshot {
    state.snapshot
  }

  func observe(_ handler: @escaping (FormattingConfigurationSnapshot) -> Void) -> UUID {
    let identifier = UUID()
    observers[identifier] = handler
    handler(state.snapshot)
    return identifier
  }

  func removeObserver(_ identifier: UUID) {
    observers[identifier] = nil
  }

  /// Replacing any credential, model, or endpoint invalidates approval and every prior connection
  /// test. A caller can use the incremented revision to cancel an in-flight formatting operation.
  @discardableResult
  func replaceCredential(
    _ credential: FormattingCredentialDescriptor,
    model: FormattingModel,
    endpoint: FormattingEndpoint
  ) -> FormattingConfigurationSnapshot {
    replace(
      enabled: false,
      model: model,
      endpoint: endpoint,
      credential: credential,
      consentVersion: nil
    )
  }

  @discardableResult
  func select(model: FormattingModel, endpoint: FormattingEndpoint) -> FormattingConfigurationSnapshot {
    replace(
      enabled: false,
      model: model,
      endpoint: endpoint,
      credential: state.snapshot.credential,
      consentVersion: nil
    )
  }

  @discardableResult
  func disable() -> FormattingConfigurationSnapshot {
    replace(
      enabled: false,
      model: state.snapshot.model,
      endpoint: state.snapshot.endpoint,
      credential: state.snapshot.credential,
      consentVersion: nil
    )
  }

  @discardableResult
  func clearCredential() -> FormattingConfigurationSnapshot {
    replace(
      enabled: false,
      model: state.snapshot.model,
      endpoint: state.snapshot.endpoint,
      credential: nil,
      consentVersion: nil
    )
  }

  /// Starts a distinct test generation. A result is usable only if no configuration mutation has
  /// changed its revision, endpoint, model, credential reference, or test generation.
  func beginConnectionTest() -> FormattingConnectionTestTicket? {
    guard let credential = state.snapshot.credential else {
      return nil
    }
    state.snapshot = snapshot(
      enabled: state.snapshot.enabled,
      model: state.snapshot.model,
      endpoint: state.snapshot.endpoint,
      credential: credential,
      consentVersion: state.snapshot.consentVersion,
      revision: state.snapshot.revision,
      testGeneration: state.snapshot.testGeneration &+ 1
    )
    state.successfulTest = nil
    persistAndNotify()
    return ticket(for: state.snapshot)
  }

  /// Closing the settings window makes a prior test result unusable without changing the user's
  /// selected endpoint, model, or credential. A later window must start a fresh test generation.
  func invalidateConnectionTest() {
    state.snapshot = snapshot(
      enabled: state.snapshot.enabled,
      model: state.snapshot.model,
      endpoint: state.snapshot.endpoint,
      credential: state.snapshot.credential,
      consentVersion: state.snapshot.consentVersion,
      revision: state.snapshot.revision,
      testGeneration: state.snapshot.testGeneration &+ 1
    )
    state.successfulTest = nil
    persistAndNotify()
  }

  @discardableResult
  func recordConnectionTestSuccess(_ ticket: FormattingConnectionTestTicket) -> Bool {
    guard matchesCurrentConfiguration(ticket) else {
      return false
    }
    state.successfulTest = ticket
    persistAndNotify()
    return true
  }

  /// Enabling always requires the current, successfully completed test and a separate informed
  /// consent version. An old successful test can never reactivate a changed configuration.
  @discardableResult
  func enable(
    afterSuccessfulTest ticket: FormattingConnectionTestTicket,
    consentVersion: Int
  ) -> Bool {
    guard consentVersion > 0,
      state.successfulTest == ticket,
      matchesCurrentConfiguration(ticket)
    else {
      return false
    }
    state.snapshot = snapshot(
      enabled: true,
      model: state.snapshot.model,
      endpoint: state.snapshot.endpoint,
      credential: state.snapshot.credential,
      consentVersion: consentVersion,
      revision: state.snapshot.revision,
      testGeneration: state.snapshot.testGeneration
    )
    persistAndNotify()
    return true
  }

  private func replace(
    enabled: Bool,
    model: FormattingModel,
    endpoint: FormattingEndpoint,
    credential: FormattingCredentialDescriptor?,
    consentVersion: Int?
  ) -> FormattingConfigurationSnapshot {
    state.snapshot = snapshot(
      enabled: enabled,
      model: model,
      endpoint: endpoint,
      credential: credential,
      consentVersion: consentVersion,
      revision: state.snapshot.revision &+ 1,
      testGeneration: state.snapshot.testGeneration &+ 1
    )
    state.successfulTest = nil
    persistAndNotify()
    return state.snapshot
  }

  private func snapshot(
    enabled: Bool,
    model: FormattingModel,
    endpoint: FormattingEndpoint,
    credential: FormattingCredentialDescriptor?,
    consentVersion: Int?,
    revision: UInt64,
    testGeneration: UInt64
  ) -> FormattingConfigurationSnapshot {
    FormattingConfigurationSnapshot(
      enabled: enabled,
      model: model,
      endpoint: endpoint,
      credential: credential,
      consentVersion: consentVersion,
      revision: revision,
      testGeneration: testGeneration
    )
  }

  private func ticket(
    for snapshot: FormattingConfigurationSnapshot
  ) -> FormattingConnectionTestTicket? {
    guard let credential = snapshot.credential else {
      return nil
    }
    return FormattingConnectionTestTicket(
      revision: snapshot.revision,
      generation: snapshot.testGeneration,
      model: snapshot.model,
      endpoint: snapshot.endpoint,
      credentialReference: credential.reference
    )
  }

  private func matchesCurrentConfiguration(_ ticket: FormattingConnectionTestTicket) -> Bool {
    guard let current = self.ticket(for: state.snapshot) else {
      return false
    }
    return current == ticket
  }

  private func persistAndNotify() {
    persist()
    for observer in observers.values {
      observer(state.snapshot)
    }
  }

  private func persist() {
    let persisted = StoredState(
      snapshot: FormattingConfigurationSnapshot(
        enabled: false,
        model: state.snapshot.model,
        endpoint: state.snapshot.endpoint,
        credential: nil,
        consentVersion: nil,
        revision: state.snapshot.revision,
        testGeneration: state.snapshot.testGeneration
      ),
      successfulTest: nil
    )
    if let data = try? JSONEncoder().encode(persisted) {
      defaults.set(data, forKey: Key.state)
    }
  }
}
