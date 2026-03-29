import Foundation

#if os(macOS)
import Security
#endif

/// Generates a stable, private UUID for this installation.
/// On macOS: stored in the system Keychain.
/// On Linux: stored in a plain text file at ~/.vvx/.device-id.
/// Used for anonymous telemetry (opt-in only).
public enum DeviceFingerprint {

    /// Returns a stable UUID string for this machine installation.
    /// Generates and stores one on first call, then returns the cached value.
    public static func deviceHash() -> String {
#if os(macOS)
        return deviceHashKeychain()
#else
        return deviceHashFile()
#endif
    }

    // MARK: - macOS: Keychain-backed fingerprint

#if os(macOS)
    private static let keychainService = "com.happymooseapps.VideoVortex"
    private static let keychainAccount = "deviceHash"

    private static func deviceHashKeychain() -> String {
        if let stored = readFromKeychain() {
            return stored
        }
        let newHash = UUID().uuidString
        writeToKeychain(newHash)
        return newHash
    }

    private static func readFromKeychain() -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func writeToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let attributes: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    keychainService,
            kSecAttrAccount:    keychainAccount,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(attributes as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }
#endif

    // MARK: - Linux / cross-platform: file-backed fingerprint

    private static var deviceIDFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vvx/.device-id")
    }

    private static func deviceHashFile() -> String {
        let fileURL = deviceIDFileURL

        if let existing = try? String(contentsOf: fileURL, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let newHash = UUID().uuidString
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try newHash.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Non-fatal: return the hash even if it couldn't be persisted.
        }
        return newHash
    }
}
