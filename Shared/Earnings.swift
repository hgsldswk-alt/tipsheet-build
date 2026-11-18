import Foundation

struct EarnedShift: Identifiable {
    var shift: Shift
    var wages: Int
    var overtimeMinutes: Int
    var id: UUID { shift.id }
    var total: Int { wages + shift.net }
    var hourly: Int? { Totals.hourly(total: total, minutes: shift.time.minutes) }
}

struct Totals {
    var card = 0, cash = 0, pool = 0, tipOut = 0, wages = 0, minutes = 0, reported = 0
    var gross: Int { card + cash + pool }
    var net: Int { gross - tipOut }
    var total: Int { net + wages }
    var hourly: Int? { Self.hourly(total: total, minutes: minutes) }

    init(_ rows: [EarnedShift] = []) {
        for row in rows {
            card += row.shift.card
            cash += row.shift.cash
            pool += row.shift.pool
            tipOut += row.shift.tipOut
            wages += row.wages
            minutes += row.shift.time.minutes
            reported += row.shift.reported ?? 0
        }
    }

    static func hourly(total: Int, minutes: Int) -> Int? {
        guard minutes > 0 else { return nil }
        return rounded(total * 60, dividedBy: minutes)
    }

    static func rounded(_ numerator: Int, dividedBy denominator: Int) -> Int {
        (numerator + (numerator < 0 ? -denominator / 2 : denominator / 2)) / denominator
    }
}

enum Earnings {
    private struct Bucket: Hashable {
        var job: UUID
        var start: Day
    }

    static func calculate(_ shifts: [Shift], firstWeekday: Int, calendar: Calendar = .tipsheet) -> [EarnedShift] {
        var days: [Bucket: Int] = [:]
        var weeks: [Bucket: Int] = [:]
        let sorted = shifts.sorted {
            ($0.day, $0.time.start, $0.created, $0.id.uuidString) < ($1.day, $1.time.start, $1.created, $1.id.uuidString)
        }
        return sorted.map { shift in
            let day = Bucket(job: shift.jobID, start: shift.day)
            let week = Bucket(job: shift.jobID, start: shift.day.week(firstWeekday: firstWeekday, calendar: calendar).start)
            let minutes = shift.time.minutes
            let daily = shift.overtime.daily ? max(0, minutes - max(0, 480 - days[day, default: 0])) : 0
            let eligible = minutes - daily
            let weekly = shift.overtime.weekly ? max(0, eligible - max(0, 2400 - weeks[week, default: 0])) : 0
            days[day, default: 0] += minutes
            weeks[week, default: 0] += eligible
            let overtime = daily + weekly
            let wages = Totals.rounded(shift.hourly * (minutes * 2 + overtime), dividedBy: 120)
            return EarnedShift(shift: shift, wages: wages, overtimeMinutes: overtime)
        }
    }
}
