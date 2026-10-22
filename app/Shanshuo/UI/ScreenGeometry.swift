import CoreGraphics

/// Accessibility reports a global Quartz position with its origin at the primary screen's upper
/// left. AppKit's desktop space has its origin at the lower left, so the primary screen's top edge
/// is the only stable reference when displays are arranged above, below, or left of it.
enum RecordingPillGeometry {
  static func appKitPoint(fromAccessibilityPoint point: CGPoint, primaryScreenFrame: CGRect)
    -> CGPoint
  {
    CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
  }

  static func screenFrame(containing point: CGPoint, screenFrames: [CGRect]) -> CGRect? {
    screenFrames.first { $0.contains(point) }
  }
}
