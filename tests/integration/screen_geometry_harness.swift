import CoreGraphics
import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

private func selectedScreen(
  axPoint: CGPoint,
  primary: CGRect,
  screens: [CGRect]
) -> CGRect? {
  let appKitPoint = RecordingPillGeometry.appKitPoint(
    fromAccessibilityPoint: axPoint,
    primaryScreenFrame: primary
  )
  return RecordingPillGeometry.screenFrame(containing: appKitPoint, screenFrames: screens)
}

@main
enum ScreenGeometryHarnessMain {
  static func main() {
    let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let above = CGRect(x: 0, y: 900, width: 1_440, height: 900)
    let below = CGRect(x: 0, y: -900, width: 1_440, height: 900)
    let left = CGRect(x: -1_280, y: 0, width: 1_280, height: 800)

    check(
      selectedScreen(
        axPoint: CGPoint(x: 400, y: -100), primary: primary, screens: [primary, above])
        == above,
      "a window on a display above primary must use that display"
    )
    check(
      selectedScreen(
        axPoint: CGPoint(x: 400, y: 1_000), primary: primary, screens: [primary, below])
        == below,
      "a window on a display below primary must use that display"
    )
    check(
      selectedScreen(axPoint: CGPoint(x: -400, y: 300), primary: primary, screens: [primary, left])
        == left,
      "a window on a negative-coordinate display must use that display"
    )
    print("screen geometry harness passed")
  }
}
