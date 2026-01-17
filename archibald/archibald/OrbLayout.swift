import CoreGraphics

enum OrbLayout {
  static let maxScale: CGFloat = 1.4
  static let glowPadding: CGFloat = 22

  static func outerSize(orbSize: CGFloat) -> CGFloat {
    (orbSize * maxScale) + (glowPadding * 2)
  }

  static func contentPadding(orbSize: CGFloat) -> CGFloat {
    ((orbSize * maxScale) - orbSize) / 2 + glowPadding
  }
}
