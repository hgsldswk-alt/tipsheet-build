import XCTest

final class LedgerTests: XCTestCase {
    private let job = Job.defaultID
    private func day(_ text: String) -> Day { Day(rawValue: text) }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testOvernightShiftBreakAndEarlyMorningDate() {
        let time = WorkTime(start: 18 * 60, end: 150, breakMinutes: 30)
        XCTAssertTrue(time.wraps)
        XCTAssertTrue(time.isValid)
        XCTAssertEqual(time.minutes, 480)
        let date = day("2026-11-18").date(in: utc)!.addingTimeInterval(4 * 3600 + 59 * 60)
        XCTAssertEqual(Day.shiftDefault(at: date, calendar: utc), day("2026-11-17"))
        XCTAssertEqual(Day.shiftDefault(at: date.addingTimeInterval(60), calendar: utc), day("2026-11-18"))
    }

    func testStackedTipOutAndManualOverride() {
        let rules = [TipRule(name: "Bar", basis: .sales, value: 150),
                     TipRule(name: "Busser", basis: .tips, value: 300),
                     TipRule(name: "Kitchen", basis: .fixed, value: 100)]
        var shift = Shift(day: day("2026-11-18"), jobID: job, card: 28_400, cash: 3600, pool: 1000, sales: 160_000)
        shift.payouts = rules.map { $0.payout(sales: shift.sales, tips: shift.gross) }
        XCTAssertEqual(shift.payouts.map(\.cents), [2400, 990, 100])
        XCTAssertEqual(shift.net, 29_510)
        shift.manualTipOut = 4200
        XCTAssertEqual(shift.net, 28_800)
    }

    func testWeeklyOvertimeAndRateUsesActualHours() {
        let start = day("2026-11-16")
        let shifts = (0..<5).map { index in
            Shift(day: start.adding(index, calendar: utc), jobID: job, time: WorkTime(start: 480, end: 1020),
                  hourly: 2000, overtime: Overtime(weekly: true), card: 8000)
        }
        let rows = Earnings.calculate(shifts, firstWeekday: 2, calendar: utc)
        let totals = Totals(rows)
        XCTAssertEqual(rows.map(\.overtimeMinutes), [0, 0, 0, 0, 300])
        XCTAssertEqual(totals.wages, 95_000)
        XCTAssertEqual(totals.hourly, 3000)
    }

    func testDailyOvertimeDoesNotPyramidAndDoesNotCrossJobs() {
        let start = day("2026-11-16")
        var shifts = (0..<5).map { index in
            Shift(day: start.adding(index, calendar: utc), jobID: job, time: WorkTime(start: 480, end: 1080),
                  hourly: 2000, overtime: Overtime(weekly: true, daily: true))
        }
        shifts.append(Shift(day: start.adding(5, calendar: utc), jobID: UUID(), hourly: 2000, overtime: Overtime(weekly: true)))
        let rows = Earnings.calculate(shifts, firstWeekday: 2, calendar: utc)
        XCTAssertEqual(rows.map(\.overtimeMinutes), [120, 120, 120, 120, 120, 0])
        XCTAssertEqual(rows[4].wages, 22_000)
    }

    func testPayCycleBeforeAnchorAndMonthBoundaries() {
        let anchor = day("2026-11-16")
        let value = PayCycle.biweekly.range(at: day("2026-11-15"), firstWeekday: 2, anchor: anchor, calendar: utc)
        XCTAssertEqual(value, DayRange(start: day("2026-11-02"), end: anchor))
        XCTAssertEqual(PayCycle.semimonthly.range(at: day("2024-02-29"), firstWeekday: 2, anchor: anchor, calendar: utc),
                       DayRange(start: day("2024-02-16"), end: day("2024-03-01")))
        XCTAssertNil(day("2026-02-29").date(in: utc))
    }

    func testDeletionSurvivesBackupMergeAndPurgesAfterThirtyDays() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let shift = Shift(updated: start, created: start, day: day("2026-11-16"), jobID: job)
        var original = Ledger()
        original.put(shift)
        var deleted = original
        let removed = start.addingTimeInterval(5)
        deleted.entries[0].updated = removed
        deleted.entries[0].deleted = true
        let cutoff = removed.addingTimeInterval(30 * 86400)
        deleted.purge(at: cutoff.addingTimeInterval(-1))
        XCTAssertNotNil(deleted.entries[0].shift)
        deleted.purge(at: cutoff)
        XCTAssertNil(original.merged(with: deleted).entries[0].shift)
        XCTAssertTrue(deleted.merged(with: original).shifts.isEmpty)
        let copy = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(deleted))
        XCTAssertTrue(copy.isValid)
        var restored = shift
        restored.updated = cutoff
        original.put(restored)
        XCTAssertEqual(deleted.merged(with: original).shifts, [restored])
    }

    func testCSVQuoteRoundTripAndInvalidRows() throws {
        let cash = 1234
        let shift = Shift(day: day("2026-11-18"), jobID: job,
                          time: WorkTime(start: 1110, end: 120, breakMinutes: 10), cash: cash,
                          manualTipOut: 813, reported: 500, notes: "=value, \"quoted\"\nA new line")
        let rows = Earnings.calculate([shift], firstWeekday: 2, calendar: utc)
        let csv = ShiftCSV.export(rows) { _ in "Bar, \"East\"" }
        XCTAssertTrue(csv.contains("'=value"))
        let result = try XCTUnwrap(ShiftCSV.parse("\u{FEFF}" + csv).first)
        XCTAssertEqual(result.job, "Bar, \"East\"")
        XCTAssertEqual(result.notes, shift.notes)
        XCTAssertEqual(result.time, shift.time)
        XCTAssertEqual(result.cash, cash)
        XCTAssertEqual(result.reported, 500)
        XCTAssertThrowsError(try ShiftCSV.parse("Date,Card Tips\n2026-02-29,77"))
    }

    func testJobSetupCopiesRulesWithoutRecords() throws {
        let job = Job(name: "酒吧 & Bar", hourly: 1800, overtime: Overtime(weekly: true),
                      rules: [TipRule(name: "Runner", basis: .tips, value: 275)])
        let code = JobSetup(job: job).code()
        let imported = try XCTUnwrap(JobSetup.parse(code)?.job())
        XCTAssertEqual(imported.name, job.name)
        XCTAssertEqual(imported.rules, job.rules)
        XCTAssertEqual(imported.overtime, job.overtime)
        XCTAssertNotEqual(imported.id, job.id)
        XCTAssertNil(JobSetup.parse(code + "!"))
    }

    func testTrialExpiresAndClaimCannotExtendIt() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var state = Entitlement(proStartedAt: start, trialClaimedAt: start.addingTimeInterval(10 * 86400))
        XCTAssertTrue(state.hasPro(at: start.addingTimeInterval(30 * 86400 - 1)))
        XCTAssertFalse(state.hasPro(at: start.addingTimeInterval(30 * 86400)))
        XCTAssertTrue(state.hasPro(at: start.addingTimeInterval(31 * 86400), free: true))
        state.proStartedAt = start.addingTimeInterval(35 * 86400)
        XCTAssertFalse(state.hasPro(at: start.addingTimeInterval(40 * 86400)))
        state.purchasedPro = true
        XCTAssertTrue(state.hasPro(at: start.addingTimeInterval(500 * 86400)))
    }

    func testMoneyValidationAcrossDecimalSeparators() {
        XCTAssertEqual(Money.cents("1,25", locale: Locale(identifier: "fr_FR")), 125)
        XCTAssertEqual(Money.cents(".50", locale: Locale(identifier: "en_US")), 50)
        XCTAssertNil(Money.cents("15.123", locale: Locale(identifier: "en_US")))
        XCTAssertNil(Money.cents("10e3", locale: Locale(identifier: "en_US")))
        XCTAssertNil(Money.cents("-1", locale: Locale(identifier: "en_US")))
    }
}
