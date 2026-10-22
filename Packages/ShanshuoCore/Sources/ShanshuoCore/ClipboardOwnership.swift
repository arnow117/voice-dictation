/// Keeps clipboard restoration policy independent from AppKit. A pasteboard may be restored only
/// if its change count still belongs to the dictation operation; otherwise the user changed it.
public enum ClipboardOwnership {
  public static func mayRestore(ownedChangeCount: Int, currentChangeCount: Int) -> Bool {
    ownedChangeCount == currentChangeCount
  }
}
