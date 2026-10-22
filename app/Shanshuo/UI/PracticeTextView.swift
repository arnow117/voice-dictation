import AppKit

final class PracticeTextView: NSTextView {
  var onPaste: (() -> Void)?

  override func paste(_ sender: Any?) {
    onPaste?()
    super.paste(sender)
  }
}
