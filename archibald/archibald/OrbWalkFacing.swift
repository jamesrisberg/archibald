import CoreGraphics
import Foundation

/// Y-axis rotation (radians) so the orb can face toward the screen edge or center during slide in/out.
/// Updated on the main thread by `OrbWindowController`; read every frame from SceneKit.
final class OrbWalkFacing {
  var yawRadians: CGFloat = 0
}
