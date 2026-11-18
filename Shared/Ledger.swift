import Foundation

enum Money {
    static let limit = 50_000_000

    static func cents(_ text: String, locale: Locale = .current) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let separator = locale.decimalSeparator ?? "."
        let parts = trimmed.components(separatedBy: separator)
        guard parts.count <= 2, trimmed != separator,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              (parts.last?.count ?? 0) <= (parts.count == 2 ? 2 : 9),
              let number = Decimal(string: trimmed, locale: locale),
              number >= 0, number <= Decimal(limit) / 100 else { return nil }
        return NSDecimalNumber(decimal: number * 100).intValue
    }

    static func text(_ cents: Int, locale: Locale = .current) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: locale.currency?.identifier ?? "USD").locale(locale))
    }

    static func entry(_ cents: Int, locale: Locale = .current) -> String {
        (Decimal(cents) / 100).formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(locale))
    }

    static func decimal(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.number.grouping(.never).precision(.fractionLength(2)).locale(Locale(identifier: "en_US_POSIX")))
    }
}

struct Day: RawRepresentable, Codable, Hashable, Comparable {
    var rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(_ date: Date, calendar: Calendar = .tipsheet) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        rawValue = String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }

    static func < (lhs: Day, rhs: Day) -> Bool { lhs.rawValue < rhs.rawValue }

    func date(in calendar: Calendar = .tipsheet) -> Date? {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Day(date, calendar: calendar) == self else { return nil }
        return date
    }

    func adding(_ days: Int, calendar: Calendar = .tipsheet) -> Day {
        guard let start = date(in: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: start) else { return self }
        return Day(moved, calendar: calendar)
    }

    static func shiftDefault(at date: Date, calendar: Calendar = .tipsheet) -> Day {
        let day = Day(date, calendar: calendar)
        return calendar.component(.hour, from: date) < 5 ? day.adding(-1, calendar: calendar) : day
    }

    func week(firstWeekday: Int, calendar: Calendar = .tipsheet) -> DayRange {
        let weekday = date(in: calendar).map { calendar.component(.weekday, from: $0) } ?? firstWeekday
        let start = adding(-((weekday - firstWeekday + 7) % 7), calendar: calendar)
        return DayRange(start: start, end: start.adding(7, calendar: calendar))
    }
}

extension Calendar {
    static var tipsheet: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }
}

struct DayRange: Equatable {
    var start: Day
    var end: Day
    func contains(_ day: Day) -> Bool { start <= day && day < end }
}

enum PayCycle: String, CaseIterable, Codable, Identifiable {
    case weekly, biweekly, semimonthly, monthly
    var id: Self { self }
    var title: String {
        switch self {
        case .weekly: L.t("Weekly")
        case .biweekly: L.t("Every two weeks")
        case .semimonthly: L.t("Twice a month")
        case .monthly: L.t("Monthly")
        }
    }

    func range(at day: Day, firstWeekday: Int, anchor: Day, calendar: Calendar = .tipsheet) -> DayRange {
        guard let date = day.date(in: calendar) else { return day.week(firstWeekday: firstWeekday, calendar: calendar) }
        switch self {
        case .weekly:
            return day.week(firstWeekday: firstWeekday, calendar: calendar)
        case .biweekly:
            guard let start = anchor.date(in: calendar) else { return day.week(firstWeekday: firstWeekday, calendar: calendar) }
            let difference = calendar.dateComponents([.day], from: start, to: date).day ?? 0
            let startDay = day.adding(-((difference % 14 + 14) % 14), calendar: calendar)
            return DayRange(start: startDay, end: startDay.adding(14, calendar: calendar))
        case .semimonthly, .monthly:
            guard let month = calendar.dateInterval(of: .month, for: date) else {
                return day.week(firstWeekday: firstWeekday, calendar: calendar)
            }
            let first = Day(month.start, calendar: calendar)
            let next = Day(month.end, calendar: calendar)
            let middle = first.adding(15, calendar: calendar)
            guard self == .semimonthly else { return DayRange(start: first, end: next) }
            return day < middle ? DayRange(start: first, end: middle) : DayRange(start: middle, end: next)
        }
    }
}

struct TipRule: Codable, Equatable, Identifiable {
    enum Basis: String, Codable, CaseIterable, Identifiable {
        case sales, tips, fixed
        var id: Self { self }
        var title: String {
            switch self {
            case .sales: L.t("% of sales")
            case .tips: L.t("% of tips")
            case .fixed: L.t("Fixed amount")
            }
        }
    }

    var id = UUID()
    var name = ""
    var basis: Basis = .tips
    var value = 0

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60
            && (0...(basis == .fixed ? Money.limit : 10_000)).contains(value)
    }

    func payout(sales: Int, tips: Int) -> Payout {
        let cents: Int
        switch basis {
        case .fixed: cents = value
        case .sales: cents = (sales * value + 5_000) / 10_000
        case .tips: cents = (max(0, tips) * value + 5_000) / 10_000
        }
        return Payout(name: name, cents: cents)
    }
}

struct Payout: Codable, Equatable {
    var name: String
    var cents: Int
}

struct WorkTime: Codable, Equatable {
    var start = 17 * 60
    var end = 23 * 60
    var breakMinutes = 0

    var minutes: Int { max(0, (end - start + 1440) % 1440 - breakMinutes) }
    var wraps: Bool { end < start }
    var isValid: Bool {
        (0..<1440).contains(start) && (0..<1440).contains(end) && (0...1439).contains(breakMinutes)
            && breakMinutes <= (end - start + 1440) % 1440
    }
}

struct Overtime: Codable, Equatable {
    var weekly = false
    var daily = false
}

struct Job: Codable, Equatable, Identifiable {
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id = UUID()
    var updated = Date()
    var name = ""
    var color = 0
    var hourly = 0
    var time = WorkTime()
    var overtime = Overtime()
    var rules: [TipRule] = []

    var title: String { name.isEmpty ? L.t("My job") : name }
    var isDelivery: Bool {
        ["delivery", "doordash", "uber", "送餐", "外卖", "外送"].contains(where: name.localizedCaseInsensitiveContains)
    }
    var isValid: Bool {
        name.count <= 80 && (0..<5).contains(color) && (0...Money.limit).contains(hourly) && time.isValid
            && rules.count <= 20 && Set(rules.map(\.id)).count == rules.count && rules.allSatisfy(\.isValid)
    }
}

struct Shift: Codable, Equatable, Identifiable {
    var id = UUID()
    var updated = Date()
    var created = Date()
    var day: Day
    var jobID: UUID
    var time = WorkTime()
    var hourly = 0
    var overtime = Overtime()
    var card = 0
    var cash = 0
    var pool = 0
    var sales = 0
    var covers = 0
    var appliedRules: [TipRule]?
    var payouts: [Payout] = []
    var manualTipOut: Int?
    var recipientNames = ""
    var reported: Int?
    var notes = ""
    var tags: [String] = []

    var gross: Int { card + cash + pool }
    var tipOut: Int { manualTipOut ?? payouts.reduce(0) { $0 + $1.cents } }
    var net: Int { gross - tipOut }
    var isValid: Bool {
        day.date() != nil && time.isValid && (0...100_000).contains(covers) && notes.count <= 2000
            && tags.count <= 20 && tags.allSatisfy { !$0.isEmpty && $0.count <= 40 }
            && recipientNames.count <= 500 && payouts.count <= 20
            && (appliedRules.map { $0.count <= 20 && $0.allSatisfy { $0.isValid } } ?? true)
            && payouts.allSatisfy { $0.name.count <= 60 && (0...(3 * Money.limit)).contains($0.cents) }
            && [hourly, card, cash, pool, sales, manualTipOut ?? 0, reported ?? 0].allSatisfy { (0...Money.limit).contains($0) }
    }
}

struct ShiftEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var shift: Shift?
    var updated: Date
    var deleted: Bool

    init(_ shift: Shift) {
        id = shift.id
        self.shift = shift
        updated = shift.updated
        deleted = false
    }
}

struct Ledger: Codable, Equatable {
    var version = 1
    var jobs: [Job] = [Job(id: Job.defaultID, updated: .distantPast)]
    var entries: [ShiftEntry] = []
    var shifts: [Shift] { entries.filter { !$0.deleted }.compactMap(\.shift) }

    var isValid: Bool {
        let jobIDs = Set(jobs.map(\.id))
        return version == 1 && !jobs.isEmpty && jobIDs.count == jobs.count
            && Set(entries.map(\.id)).count == entries.count && jobs.allSatisfy(\.isValid)
            && entries.allSatisfy { entry in
                if let shift = entry.shift { return shift.id == entry.id && jobIDs.contains(shift.jobID) && shift.isValid }
                return entry.deleted
            }
    }

    mutating func put(_ shift: Shift) {
        if let index = entries.firstIndex(where: { $0.id == shift.id }) {
            entries[index] = ShiftEntry(shift)
        } else {
            entries.append(ShiftEntry(shift))
        }
    }

    mutating func put(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
        else { jobs.append(job) }
    }

    mutating func purge(at date: Date) {
        for index in entries.indices where entries[index].deleted && date.timeIntervalSince(entries[index].updated) >= 30 * 86400 {
            entries[index].shift = nil
        }
    }

    func merged(with other: Ledger) -> Ledger {
        var result = self
        var jobIndex = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        for job in other.jobs {
            if let known = jobIndex[job.id], known.updated >= job.updated { continue }
            jobIndex[job.id] = job
        }
        var entryIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for entry in other.entries {
            if let known = entryIndex[entry.id] {
                if known.updated > entry.updated { continue }
                if known.updated == entry.updated && (known.deleted || !entry.deleted) {
                    if !(known.deleted && entry.deleted && entry.shift == nil && known.shift != nil) { continue }
                }
            }
            entryIndex[entry.id] = entry
        }
        result.jobs = jobIndex.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.entries = entryIndex.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return result
    }
}
