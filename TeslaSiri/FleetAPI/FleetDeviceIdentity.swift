import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

struct FleetDeviceIdentity: Sendable {
    var service: String
    var account: String

    init(service: String = "com.maxweinbach.TeslaSiri.fleet", account: String = "notificationDeviceID") {
        self.service = service
        self.account = account
    }

    func deviceID() throws -> String {
        if let existingID = try loadDeviceID() {
            return existingID
        }

        let newID = "ios:" + UUID().uuidString
        return try saveDeviceID(newID)
    }

    func notificationWebhookCreateRequest(
        url: URL,
        events: [String] = FleetNotificationEvent.defaultEvents,
        vins: [String] = [],
        description: String? = nil,
        enabled: Bool = true,
        platform: String = "ios"
    ) throws -> FleetDeviceNotificationWebhookCreateRequest {
        FleetDeviceNotificationWebhookCreateRequest(
            deviceID: try deviceID(),
            url: url,
            events: events,
            vins: vins,
            description: description,
            deviceName: Self.currentDeviceName,
            enabled: enabled,
            platform: platform
        )
    }

    func notificationWebhookCreateForDeviceRequest(
        url: URL,
        events: [String] = FleetNotificationEvent.defaultEvents,
        vins: [String] = [],
        description: String? = nil,
        enabled: Bool = true,
        platform: String = "ios"
    ) -> FleetDeviceNotificationWebhookCreateForDeviceRequest {
        FleetDeviceNotificationWebhookCreateForDeviceRequest(
            url: url,
            events: events,
            vins: vins,
            description: description,
            deviceName: Self.currentDeviceName,
            enabled: enabled,
            platform: platform
        )
    }

    private func loadDeviceID() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw FleetAPIError.keychain(status: status)
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func saveDeviceID(_ deviceID: String) throws -> String {
        let data = Data(deviceID.utf8)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return deviceID
        case errSecDuplicateItem:
            if let existingID = try loadDeviceID(), !existingID.isEmpty {
                return existingID
            }
            throw FleetAPIError.keychain(status: status)
        default:
            throw FleetAPIError.keychain(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static var currentDeviceName: String? {
        #if canImport(UIKit)
        "TeslaSiri iOS"
        #else
        "TeslaSiri"
        #endif
    }
}
