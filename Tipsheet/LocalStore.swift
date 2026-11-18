import Foundation
import Security

struct Preferences: Codable {
    var lastJob: UUID?
    var firstWeekday = 2
    var payCycle = PayCycle.weekly
    var payAnchor = Day(Date())
    var hideAmounts = false
    var biometrics = false
    var reminders = false
    var cloudEnabled = true
    var dismissedCloudHint = false
    var cloudAccount: String?
    var lastSync: Date?
    var savedShifts = 0
    var reviewRequested = false
    var loggedFirstShift = false
}

struct AppData: Codable {
    var ledger = Ledger()
    var preferences = Preferences()
    var entitlement = Entitlement()
}

enum LocalStore {
    private static func url() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Tipsheet", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.json")
    }

    static func load() throws -> AppData {
        let file = try url()
        guard FileManager.default.fileExists(atPath: file.path) else { return AppData() }
        let data = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: file))
        guard data.ledger.isValid, (1...7).contains(data.preferences.firstWeekday) else { throw ExchangeError.invalidFile }
        return data
    }

    static func save(_ data: AppData) throws {
        try JSONEncoder().encode(data).write(to: url(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum TrialClock {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.hgsldswk.tipsheet",
        kSecAttrAccount as String: "paid-era-trial-start"
    ]

    static func read() -> Date? {
        var options = query
        options[kSecReturnData as String] = true
        options[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(options as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let date = try? JSONDecoder().decode(Date.self, from: data) else { return nil }
        return date
    }

    static func keep(_ date: Date) {
        if let prior = read(), prior <= date { return }
        guard let data = try? JSONEncoder().encode(date) else { return }
        let value = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
