import Foundation

enum DebugLog {
    static var isEnabled = true

    static func log(_ message: String) {
        guard isEnabled else { return }
        NSLog("%@", message)
    }
}
