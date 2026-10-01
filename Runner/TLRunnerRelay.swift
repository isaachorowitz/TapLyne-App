import Foundation
import Security

/// Starts inside WebDriverAgentRunner.xctest, in the same XCTest process as WDA.
@objc(TLRunnerRelay)
public final class TLRunnerRelay: NSObject {
    @MainActor private static var peer: RelayPeer?
    private static let service = "agency.ziplyne.taplyne.runner-relay"
    private static let account = "runner-configuration-v1"
    private static let bootstrapName = "taplyne-relay.json"

    @objc public static func start() {
        Task { @MainActor in
            do {
                let configuration = try configuration()
                guard configuration.role == .device, configuration.scope == .runner else {
                    throw RelayFailure("Runner pairing has the wrong role or scope.")
                }
                peer?.stop()
                let connection = try RelayPeer(configuration: configuration)
                connection.requestHandler = RelayWDAProxy.handle
                peer = connection
                connection.start()
            } catch {
                // WDA remains available locally for diagnosis; pairing secrets
                // and network errors never enter XCTest's public test log.
                if let failure = error as? RelayFailure {
                    NSLog("Taplyne runner relay unavailable: %@", failure.message)
                } else {
                    NSLog("Taplyne runner relay unavailable (%@:%ld).",
                          String(reflecting: type(of: error)), (error as NSError).code)
                }
            }
        }
    }

    @MainActor private static func configuration() throws -> RelayConfiguration {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bootstrap = documents.appendingPathComponent(bootstrapName, isDirectory: false)
        if FileManager.default.fileExists(atPath: bootstrap.path) {
            let values = try bootstrap.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1...4096).contains(size) else {
                throw RelayFailure("Invalid runner pairing file.")
            }
            let data = try Data(contentsOf: bootstrap)
            let config = try JSONDecoder().decode(RelayConfiguration.self, from: data).validated()
            guard config.role == .device, config.scope == .runner,
                  config.peerTokenHash == nil, config.enrollmentToken == nil else {
                throw RelayFailure("Runner pairing has the wrong role or scope.")
            }
            try store(data)
            try FileManager.default.removeItem(at: bootstrap)
            return config
        }
        guard let stored = try load() else { throw RelayFailure("Runner pairing is absent.") }
        let config = try JSONDecoder().decode(RelayConfiguration.self, from: stored).validated()
        guard config.role == .device, config.scope == .runner,
              config.peerTokenHash == nil, config.enrollmentToken == nil else {
            throw RelayFailure("Runner pairing has the wrong role or scope.")
        }
        return config
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func store(_ data: Data) throws {
        var item = query()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        if result == errSecDuplicateItem {
            let update = SecItemUpdate(query() as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw RelayFailure("Runner Keychain update failed (\(update)).") }
        } else if result != errSecSuccess {
            throw RelayFailure("Runner Keychain add failed (\(result)).")
        }
    }

    private static func load() throws -> Data? {
        var item = query()
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RelayFailure("Runner Keychain read failed (\(status)).")
        }
        return data
    }
}
