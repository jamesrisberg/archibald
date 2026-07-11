import Foundation
import Security

/// Minimal generic-password store so API keys live in the user's Keychain
/// instead of plaintext UserDefaults.
enum KeychainStore {
  private static let service = Bundle.main.bundleIdentifier ?? "Archibald"

  static func string(forKey key: String) -> String? {
    var query = baseQuery(key: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func set(_ value: String, forKey key: String) {
    if value.isEmpty {
      SecItemDelete(baseQuery(key: key) as CFDictionary)
      return
    }
    let data = Data(value.utf8)
    let attributes = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery(key: key) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var query = baseQuery(key: key)
      query[kSecValueData as String] = data
      SecItemAdd(query as CFDictionary, nil)
    }
  }

  private static func baseQuery(key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}
