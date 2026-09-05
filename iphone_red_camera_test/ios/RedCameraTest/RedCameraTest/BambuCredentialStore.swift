import Foundation
import Security

enum H2DAccessCodeStore {
    private static let service = "vn.rockettracker.RedCameraTest.h2d"
    private static let legacyAccount = "lan-access-code"
    private static let legacyRecoveryKey = "SE.H2D.lanAccessCode.recovery"

    private static func account(for kind: BambuPrinterKind) -> String {
        "lan-access-code-\(kind.rawValue.lowercased())"
    }

    private static func recoveryKey(for kind: BambuPrinterKind) -> String {
        "SE.Bambu.\(kind.rawValue).lanAccessCode.recovery"
    }

    private static func normalize(_ value: String) -> String {
        value
            .filter { $0.isNumber || ($0.isASCII && $0.isLetter) }
            .lowercased()
    }

    static func load(for kind: BambuPrinterKind = .h2d) -> String {
        let profileAccount = account(for: kind)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            let normalized = normalize(value)
            if !normalized.isEmpty {
                UserDefaults.standard.set(normalized, forKey: recoveryKey(for: kind))
                return normalized
            }
        }

        let recovered = normalize(
            UserDefaults.standard.string(forKey: recoveryKey(for: kind)) ?? ""
        )
        if !recovered.isEmpty { return recovered }

        guard kind == .h2d else { return "" }
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var legacyResult: CFTypeRef?
        var legacy = ""
        if SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult) == errSecSuccess,
           let data = legacyResult as? Data,
           let value = String(data: data, encoding: .utf8) {
            legacy = normalize(value)
        }
        if legacy.isEmpty {
            legacy = normalize(UserDefaults.standard.string(forKey: legacyRecoveryKey) ?? "")
        }
        if !legacy.isEmpty { save(legacy, for: kind) }
        return legacy
    }

    static func save(_ value: String, for kind: BambuPrinterKind = .h2d) {
        let trimmed = normalize(value)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        UserDefaults.standard.set(trimmed, forKey: recoveryKey(for: kind))
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: kind)
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                _ = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
            }
        }
    }
}

enum H2DWiFiPasswordStore {
    private static let service = "vn.rockettracker.RedCameraTest.h2d"
    private static let account = "wifi-password"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func save(_ value: String) {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(identity as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}
