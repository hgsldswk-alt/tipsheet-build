import Foundation

enum Launch {
    static let freePeriod = false
}

struct Entitlement: Codable, Equatable {
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date? {
        [proStartedAt, trialClaimedAt].compactMap { $0 }.min()
    }

    var trialEnd: Date? { trialStart?.addingTimeInterval(30 * 86400) }

    func hasPro(at date: Date, free: Bool = Launch.freePeriod) -> Bool {
        if free || purchasedPro { return true }
        guard let start = trialStart, let end = trialEnd else { return false }
        return date >= start.addingTimeInterval(-600) && date < end
    }

    func remainingDays(at date: Date) -> Int {
        guard let end = trialEnd else { return 0 }
        return Int(ceil(max(0, min(30, end.timeIntervalSince(date) / 86400))))
    }
}
