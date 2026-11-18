import Combine
import Foundation
import LocalAuthentication
import StoreKit
import UIKit
import UserNotifications
import WidgetKit

enum AppTab: String, CaseIterable {
    case home, calendar, insights

    var title: String {
        switch self {
        case .home: L.t("Home")
        case .calendar: L.t("Calendar")
        case .insights: L.t("Insights")
        }
    }

    var icon: String {
        switch self {
        case .home: "chart.bar.xaxis"
        case .calendar: "calendar"
        case .insights: "chart.line.uptrend.xyaxis"
        }
    }
}

enum Sheet: Identifiable {
    case shift(Day, Shift?, focus: Bool)
    case day(Day)
    case settings, paywall, weekShare, milestones, coworker, tax
    case receipt(Shift)

    var id: String {
        switch self {
        case .shift(let day, let shift, _): "shift-" + (shift?.id.uuidString ?? day.rawValue)
        case .day(let day): "day-" + day.rawValue
        case .settings: "settings"
        case .paywall: "paywall"
        case .weekShare: "week-share"
        case .milestones: "milestones"
        case .coworker: "coworker"
        case .tax: "tax"
        case .receipt(let shift): "receipt-" + shift.id.uuidString
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var data = AppData()
    @Published private(set) var earned: [EarnedShift] = []
    @Published private(set) var now = Date()
    @Published private(set) var cloudState = CloudState.checking
    @Published private(set) var locked = false
    @Published private(set) var authenticating = false
    @Published private(set) var busy = false
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var purchaseMessage: String?
    @Published private(set) var storageBlocked = false
    @Published var notice: String?
    @Published var sheet: Sheet?
    @Published var tab = AppTab.home
    @Published var jobFilter: UUID?
    @Published var undoID: UUID?
    @Published var pendingReview = false
    @Published var importCode = ""
    @Published var importRows: [CSVShift] = []
    @Published var pendingFiles: [URL] = []

    static let trialID = "com.hgsldswk.tipsheet.trial"
    static let proID = "com.hgsldswk.tipsheet.pro"
    private let cloud = PrivateCloud()
    private var syncing: Task<Void, Never>?
    private var cloudNeedsRun = false
    private var storeUpdates: Task<Void, Never>?
    private var undoTimer: Task<Void, Never>?
    private var pendingURL: URL?
    private var pendingLog = false
    private var started = false
    private let isolated: Bool
    private let forcePro: Bool

    var today: Day { Day(now) }
    var hasPro: Bool { forcePro || data.entitlement.hasPro(at: now) }
    var hidden: Bool { data.preferences.hideAmounts }
    var jobs: [Job] {
        data.ledger.jobs.sorted {
            if $0.id == Job.defaultID { return $1.id != Job.defaultID }
            if $1.id == Job.defaultID { return false }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    var defaultJob: Job { job(data.preferences.lastJob ?? Job.defaultID) }
    var week: DayRange { today.week(firstWeekday: data.preferences.firstWeekday) }
    var weekRows: [EarnedShift] { rows(in: week, jobID: jobFilter) }
    var displayRows: [EarnedShift] { earned.filter { jobFilter == nil || $0.shift.jobID == jobFilter } }
    var canShare: Bool { !weekRows.isEmpty }
    var deleted: [ShiftEntry] {
        data.ledger.entries.filter { $0.deleted && $0.shift != nil && now.timeIntervalSince($0.updated) < 30 * 86400 }
            .sorted { $0.updated > $1.updated }
    }

    init() {
        #if DEBUG
        let args = Set(ProcessInfo.processInfo.arguments)
        isolated = !args.isDisjoint(with: ["-demo", "-ui-testing", "-expired", "-paywall", "-paid-mode"])
        forcePro = args.contains("-demo") && !args.contains("-expired") && !args.contains("-paywall")
        if isolated {
            if args.contains("-demo") {
                now = DemoData.reference
                data = DemoData.make(now: now)
            }
            if args.contains("-expired") {
                data.entitlement.proStartedAt = now.addingTimeInterval(-31 * 86400)
            }
            if args.contains("-calendar") { tab = .calendar }
            if args.contains("-insights") { tab = .insights }
            if args.contains("-hidden") { data.preferences.hideAmounts = true }
            if args.contains("-paywall") { sheet = .paywall }
            else if args.contains("-share") { sheet = .weekShare }
            else if args.contains("-sample-shift") { sheet = .shift(Day.shiftDefault(at: now), nil, focus: true) }
        }
        #else
        isolated = false
        forcePro = false
        #endif

        if !isolated {
            do { data = try LocalStore.load() }
            catch {
                storageBlocked = true
                notice = L.t("Could not read your records. Your local file is preserved.")
            }
        }
        if !Launch.freePeriod {
            let keychain = isolated ? nil : TrialClock.read()
            data.entitlement.proStartedAt = [data.entitlement.proStartedAt, keychain].compactMap { $0 }.min() ?? now
            if !isolated, let start = data.entitlement.trialStart { TrialClock.keep(start) }
        }
        if !data.preferences.loggedFirstShift, data.ledger.shifts.isEmpty, sheet == nil, !storageBlocked {
            sheet = .shift(Day.shiftDefault(at: now), nil, focus: true)
        }
        locked = data.preferences.biometrics && data.entitlement.hasPro(at: now)
        var initial = data
        initial.ledger.purge(at: now)
        _ = commit(initial, requestCloud: false)
        rebuild()
    }

    func start() async {
        guard !started else { return }
        started = true
        handleLaunchFlag()
        requestCloud()
        guard !isolated, !Launch.freePeriod else { return }
        storeUpdates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, case .verified(let transaction) = result,
                      [Self.proID, Self.trialID].contains(transaction.productID) else { continue }
                await self.refreshEntitlements()
                await transaction.finish()
            }
        }
        async let fetchProducts: () = loadProducts()
        await refreshEntitlements()
        await fetchProducts
    }

    func refreshTime() {
        guard !isolated else { return }
        let old = now
        now = Date()
        let proChanged = data.entitlement.hasPro(at: old) != data.entitlement.hasPro(at: now)
        if proChanged {
            if !hasPro { locked = false }
            writeWidget()
            if !hasPro && !isolated { Task { await Reminders.cancel() } }
        } else if Day(old) != today {
            var next = data
            next.ledger.purge(at: now)
            if next.ledger != data.ledger { _ = commit(next) }
            else { writeWidget() }
        }
    }

    func foreground() {
        refreshTime()
        handleLaunchFlag()
        if let last = data.preferences.lastSync, now.timeIntervalSince(last) < 30 { return }
        requestCloud()
    }

    func foregroundTick() {
        refreshTime()
        if case .synced(let last) = cloudState, now.timeIntervalSince(last) >= 180 {
            requestCloud()
        }
    }

    var proPriceText: String? {
        products[Self.proID]?.displayPrice ?? (isolated ? "US$5.99" : nil)
    }

    func background() {
        if data.preferences.biometrics && hasPro { locked = true }
    }

    func unlock() async {
        guard locked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                   localizedReason: L.t("Unlock your Tipsheet records")) else { return }
            locked = false
            if let url = pendingURL { pendingURL = nil; open(url) }
            if pendingLog { pendingLog = false; logShift() }
        } catch {}
    }

    func setBiometrics(_ enabled: Bool) async {
        guard !enabled || requirePro() else { return }
        if enabled {
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                       localizedReason: L.t("Protect your Tipsheet records")) else { return }
            } catch {
                notice = L.t("Set up Face ID or a device passcode first.")
                return
            }
        }
        set(\.biometrics, enabled)
    }

    func handleLaunchFlag() {
        guard !isolated, WidgetBridge.consumeLog() else { return }
        logShift()
    }

    func logShift(day: Day? = nil) {
        guard !locked else { pendingLog = true; return }
        if case .shift(_, nil, _) = sheet { return }
        sheet = .shift(day ?? Day.shiftDefault(at: now), nil, focus: true)
    }

    func requirePro() -> Bool {
        if hasPro { return true }
        sheet = .paywall
        return false
    }

    func job(_ id: UUID) -> Job { data.ledger.jobs.first { $0.id == id } ?? jobs[0] }
    func rows(in range: DayRange, jobID: UUID? = nil) -> [EarnedShift] {
        earned.filter { range.contains($0.shift.day) && (jobID == nil || $0.shift.jobID == jobID) }
    }
    func rows(on day: Day) -> [EarnedShift] {
        Array(earned.filter { $0.shift.day == day }.reversed())
    }

    func display(_ amount: Int) -> String { hidden ? L.t("••••") : Money.text(amount) }
    func hourly(_ amount: Int?) -> String { amount.map { L.f("%@ / hr", Money.text($0)) } ?? "—" }

    func set<T>(_ setting: WritableKeyPath<Preferences, T>, _ value: T) {
        var next = data
        next.preferences[keyPath: setting] = value
        _ = commit(next, requestCloud: false)
    }

    func preview(_ shift: Shift) -> EarnedShift? {
        var shifts = data.ledger.shifts.filter { $0.id != shift.id }
        shifts.append(shift)
        return Earnings.calculate(shifts, firstWeekday: data.preferences.firstWeekday).first { $0.id == shift.id }
    }

    @discardableResult
    func save(_ draft: Shift, new: Bool) -> Bool {
        guard draft.isValid, data.ledger.jobs.contains(where: { $0.id == draft.jobID }) else { return false }
        var next = data
        var shift = draft
        if !new {
            guard let record = next.ledger.entries.first(where: { $0.id == draft.id }), !record.deleted else { return false }
            shift.updated = max(Date(), record.updated.addingTimeInterval(0.001))
            if var existing = record.shift {
                existing.updated = shift.updated
                if existing == shift { return true }
            }
        } else {
            guard !next.ledger.entries.contains(where: { $0.id == draft.id }) else { return false }
            shift.updated = Date()
            shift.created = shift.updated
            next.preferences.savedShifts += 1
            next.preferences.loggedFirstShift = true
            next.preferences.lastJob = shift.jobID
            var job = self.job(shift.jobID)
            job.updated = max(shift.updated, job.updated.addingTimeInterval(0.001))
            job.time = shift.time
            job.hourly = shift.hourly
            next.ledger.put(job)
        }
        next.ledger.put(shift)
        let ask = new && next.preferences.savedShifts == 3 && !next.preferences.reviewRequested && !isolated
        if ask { next.preferences.reviewRequested = true }
        guard commit(next) else { return false }
        if new {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            tab = .home
            sheet = nil
            if ask { pendingReview = true }
            scheduleReminder(shift: shift)
        }
        return true
    }

    @discardableResult
    func saveJob(_ input: Job) -> Bool {
        let existing = data.ledger.jobs.first { $0.id == input.id }
        guard existing != nil || data.ledger.jobs.count == 1 && data.ledger.shifts.isEmpty || requirePro() else { return false }
        guard input.isValid else { return false }
        var job = input
        job.updated = max(Date(), (existing?.updated ?? .distantPast).addingTimeInterval(0.001))
        var next = data
        next.ledger.put(job)
        return commit(next)
    }

    func createJob(named name: String) -> Job? {
        guard requirePro() else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let job = Job(name: clean, color: data.ledger.jobs.count % 5)
        return saveJob(job) ? job : nil
    }

    func deactivate(_ shift: Shift) {
        var next = data
        guard let index = next.ledger.entries.firstIndex(where: { $0.id == shift.id && !$0.deleted }) else { return }
        next.ledger.entries[index].deleted = true
        next.ledger.entries[index].updated = max(Date(), next.ledger.entries[index].updated.addingTimeInterval(0.001))
        guard commit(next) else { return }
        undoID = shift.id
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.undoID = nil
        }
    }

    func restore(_ id: UUID) {
        var next = data
        guard let entry = deleted.first(where: { $0.id == id }), var shift = entry.shift else { return }
        shift.updated = max(Date(), entry.updated.addingTimeInterval(0.001))
        next.ledger.put(shift)
        if commit(next), undoID == id { undoID = nil }
    }

    func open(_ url: URL) {
        guard !locked else { pendingURL = url; return }
        if url.isFileURL {
            restoreFile(url)
            return
        }
        if url.scheme == "tipsheet", url.host == "log" { logShift(); return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let code: String?
        if url.scheme == "tipsheet", url.host == "setup" {
            code = components.queryItems?.first(where: { $0.name == "code" })?.value
        } else if url.scheme == "https", url.host == StoreLinks.support.host, url.path == StoreLinks.support.path {
            code = components.fragment
        } else { return }
        guard let code, JobSetup.parse(code) != nil else { return }
        _ = addSetup(code)
    }

    @discardableResult
    func addSetup(_ code: String) -> Bool {
        guard let setup = JobSetup.parse(code) else {
            notice = L.t("That setup code could not be read.")
            return false
        }
        let candidate = setup.job()
        if jobs.contains(where: {
            $0.name == candidate.name && $0.hourly == candidate.hourly && $0.overtime == candidate.overtime
                && $0.rules == candidate.rules
        }) {
            importCode = ""
            notice = L.t("This job setup is already saved.")
            return true
        }
        guard hasPro else {
            importCode = code
            sheet = .paywall
            return false
        }
        let existing = jobs.first { $0.id == Job.defaultID && $0.updated == .distantPast }
        var job = candidate
        if let existing, data.ledger.shifts.isEmpty { job.id = existing.id }
        guard saveJob(job) else { return false }
        importCode = ""
        notice = L.f("Added %@", job.title)
        return true
    }

    func restoreFile(_ url: URL) {
        do {
            let raw = try readFile(url)
            let backup = try JSONDecoder().decode(Ledger.self, from: raw)
            guard backup.isValid else { throw ExchangeError.invalidFile }
            var next = data
            next.ledger = next.ledger.merged(with: backup)
            if !next.ledger.shifts.isEmpty { next.preferences.loggedFirstShift = true }
            if commit(next) {
                notice = L.t("Backup merged with your records.")
                if case .shift(_, nil, _) = sheet, !data.ledger.shifts.isEmpty { sheet = nil }
            }
        } catch { notice = L.t("Could not restore this backup.") }
    }

    func loadCSV(_ url: URL) {
        guard requirePro() else { return }
        do {
            let raw = try readFile(url)
            guard let source = String(data: raw, encoding: .utf8) else { throw ExchangeError.invalidFile }
            importRows = try ShiftCSV.parse(source)
        } catch ExchangeError.invalidRow(let line) {
            notice = L.f("Check CSV row %@.", String(line))
        } catch { notice = L.t("Could not read this CSV file.") }
    }

    func confirmCSV() -> Bool {
        guard requirePro(), !importRows.isEmpty else { return false }
        var next = data
        var signatures = Dictionary(grouping: next.ledger.shifts, by: importSignature).mapValues { $0.count }
        for row in importRows {
            let name = row.job.isEmpty ? L.t("My job") : row.job
            let found = next.ledger.jobs.first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
            let job = found ?? Job(name: row.job, color: next.ledger.jobs.count % 5)
            let shift = row.makeShift(jobID: job.id, now: now)
            let signature = importSignature(shift)
            if let matches = signatures[signature], matches > 0 {
                signatures[signature] = matches - 1
                continue
            }
            if found == nil { next.ledger.put(job) }
            next.ledger.put(shift)
        }
        next.preferences.loggedFirstShift = true
        guard commit(next) else { return false }
        importRows = []
        notice = L.t("CSV import finished.")
        return true
    }

    private func importSignature(_ shift: Shift) -> String {
        let numbers = [shift.time.start, shift.time.end, shift.time.breakMinutes, shift.card, shift.cash,
                       shift.pool, shift.tipOut, shift.hourly, shift.sales, shift.covers]
        let fields = [shift.day.rawValue, shift.jobID.uuidString, String(shift.reported ?? -1),
                      shift.recipientNames, shift.notes] + shift.tags
        return numbers.map { String($0) }.joined(separator: ",") + fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 24_000_000 else { throw ExchangeError.invalidFile }
        return try Data(contentsOf: url)
    }

    func exportBackup() {
        do { pendingFiles = [try ExportFiles.write(JSONEncoder().encode(data.ledger), as: "Tipsheet-backup.tipsheet")] }
        catch { notice = L.t("Could not prepare the export.") }
    }

    func exportCSV() {
        do { pendingFiles = [try ExportFiles.csv(earned, jobName: { self.job($0).title })] }
        catch { notice = L.t("Could not prepare the export.") }
    }

    func setReminders(_ enabled: Bool) async {
        guard !enabled || requirePro() else { return }
        if enabled {
            guard await Reminders.authorize() else {
                notice = L.t("Allow notifications in iPhone Settings to use reminders.")
                return
            }
            set(\.reminders, true)
            if let shift = earned.last?.shift { scheduleReminder(shift: shift) }
        } else {
            set(\.reminders, false)
            await Reminders.cancel()
        }
    }

    private func scheduleReminder(shift: Shift) {
        guard !isolated, data.preferences.reminders, hasPro else { return }
        let now = Date()
        let until = data.entitlement.purchasedPro || Launch.freePeriod ? nil : data.entitlement.trialEnd
        Task { await Reminders.schedule(endMinute: shift.time.end, after: now, until: until) }
    }

    func setCloud(_ enabled: Bool) {
        set(\.cloudEnabled, enabled)
        if enabled { requestCloud() }
        else { syncing?.cancel(); cloudState = .disabled }
    }

    func requestCloud() {
        guard !isolated, !storageBlocked, data.preferences.cloudEnabled else { return }
        cloudNeedsRun = true
        guard syncing == nil else { return }
        syncing = Task { [weak self] in await self?.syncLoop() }
    }

    private func syncLoop() async {
        defer {
            syncing = nil
            if cloudNeedsRun && data.preferences.cloudEnabled { requestCloud() }
        }
        while cloudNeedsRun && data.preferences.cloudEnabled && !Task.isCancelled {
            cloudNeedsRun = false
            cloudState = .running
            do {
                let account = try await cloud.account()
                try Task.checkCancellation()
                if let known = data.preferences.cloudAccount, known != account { throw CloudProblem.changedAccount }
                if data.preferences.cloudAccount == nil {
                    var bound = data
                    bound.preferences.cloudAccount = account
                    guard commit(bound, requestCloud: false) else { cloudState = .failed; return }
                }
                var local = data.ledger
                local.purge(at: now)
                let remote = try await cloud.sync(local, account: account, at: now)
                try Task.checkCancellation()
                guard data.preferences.cloudEnabled else { return }
                var next = data
                next.ledger = next.ledger.merged(with: remote)
                next.ledger.purge(at: now)
                next.preferences.lastSync = Date()
                if !next.ledger.shifts.isEmpty { next.preferences.loggedFirstShift = true }
                guard commit(next, requestCloud: false) else { cloudState = .failed; return }
                cloudState = .synced(next.preferences.lastSync ?? now)
            } catch is CancellationError {
                return
            } catch CloudProblem.unavailable {
                cloudState = .unavailable
            } catch CloudProblem.changedAccount {
                cloudState = .changedAccount
            } catch {
                if !Task.isCancelled { cloudState = .failed }
            }
        }
    }

    func loadProducts() async {
        guard !isolated, !Launch.freePeriod else { return }
        do {
            let available = try await Product.products(for: [Self.proID, Self.trialID])
            products = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        } catch { purchaseMessage = L.t("The App Store is currently unavailable.") }
    }

    func purchase(_ id: String) async {
        guard !isolated, !busy, !Launch.freePeriod else { return }
        busy = true
        purchaseMessage = nil
        defer { busy = false }
        if products[id] == nil { await loadProducts() }
        guard let product = products[id] else {
            purchaseMessage = L.t("The App Store is currently unavailable.")
            return
        }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await refreshEntitlements(verified: transaction)
                await transaction.finish()
                purchaseMessage = id == Self.proID ? L.t("Pro is unlocked.") : L.t("Trial receipt saved.")
            case .success(.unverified):
                purchaseMessage = L.t("Purchase could not be verified.")
            case .pending:
                purchaseMessage = L.t("Purchase pending approval.")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { purchaseMessage = L.t("Purchase could not be completed.") }
    }

    func restorePurchases() async {
        guard !isolated, !busy, !Launch.freePeriod else { return }
        busy = true
        purchaseMessage = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseMessage = data.entitlement.purchasedPro ? L.t("Pro is unlocked.") : L.t("No Pro purchase found.")
        } catch { purchaseMessage = L.t("Purchases could not be restored.") }
    }

    private func refreshEntitlements(verified: Transaction? = nil) async {
        var purchased = verified?.productID == Self.proID
        var claim = verified?.productID == Self.trialID ? verified?.originalPurchaseDate : nil
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == Self.proID { purchased = true }
            if transaction.productID == Self.trialID {
                claim = min(claim ?? transaction.originalPurchaseDate, transaction.originalPurchaseDate)
            }
        }
        var next = data
        next.entitlement.purchasedPro = purchased
        if let claim { next.entitlement.trialClaimedAt = min(next.entitlement.trialClaimedAt ?? claim, claim) }
        guard next.entitlement != data.entitlement else { return }
        if let start = next.entitlement.trialStart { TrialClock.keep(start) }
        _ = commit(next, requestCloud: false)
        if hasPro, !importCode.isEmpty { _ = addSetup(importCode) }
        if !hasPro && !isolated { Task { await Reminders.cancel() } }
    }

    private func commit(_ next: AppData, requestCloud: Bool = true) -> Bool {
        guard !storageBlocked else { return false }
        do {
            if !isolated { try LocalStore.save(next) }
            let recalculate = data.ledger != next.ledger || data.preferences.firstWeekday != next.preferences.firstWeekday
            let changedWidget = recalculate || data.entitlement != next.entitlement
                || data.preferences.hideAmounts != next.preferences.hideAmounts || data.preferences.biometrics != next.preferences.biometrics
            data = next
            if recalculate { rebuild() }
            else if changedWidget { writeWidget() }
            if requestCloud { self.requestCloud() }
            return true
        } catch {
            notice = L.t("Could not save changes. Try again after freeing storage.")
            return false
        }
    }

    private func rebuild() {
        earned = Earnings.calculate(data.ledger.shifts, firstWeekday: data.preferences.firstWeekday)
        writeWidget()
    }

    private func writeWidget() {
        guard !isolated, let periodEnd = week.end.date() else { return }
        let weekRows = rows(in: week)
        let total = Totals(weekRows)
        let values = (0..<7).map { day in max(0, Totals(weekRows.filter { $0.shift.day == week.start.adding(day) }).total) }
        let maxValue = Double(max(1, values.max() ?? 0))
        let hidden = hidden || data.preferences.biometrics
        let snapshot = WidgetBridge.Snapshot(total: hidden ? "••••" : Money.text(total.total), hourly: hidden ? "••••" : hourly(total.hourly),
            bars: hidden ? [] : values.map { Double($0) / maxValue }, currentDay: (0..<7).first { week.start.adding($0) == today } ?? 0,
            periodEnd: periodEnd, proUntil: data.entitlement.trialEnd,
            unlimited: Launch.freePeriod || data.entitlement.purchasedPro, hidden: hidden)
        WidgetBridge.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

enum DemoData {
    static var reference: Date {
        let day = Day(rawValue: "2025-11-15").date() ?? Date()
        return day.addingTimeInterval(14 * 3600)
    }

    static func make(now: Date) -> AppData {
        var data = AppData()
        let today = Day(now)
        let start = today.week(firstWeekday: 2).start
        let first = Job(id: Job.defaultID, name: "The Larder · Server", hourly: 750,
                        time: WorkTime(start: 990, end: 70, breakMinutes: 30),
                        rules: [TipRule(name: "Bar", basis: .sales, value: 150), TipRule(name: "Busser", basis: .tips, value: 300)])
        let second = Job(name: "Ninth St Bar · Bartender", color: 1, hourly: 675,
                         time: WorkTime(start: 1140, end: 120))
        data.ledger.jobs = [first, second]
        for (index, day) in [-12, -10, -9, -7, -6, -5, -3, 1, 2, 4, 5].enumerated() {
            let job = index % 3 == 2 ? second : first
            var shift = Shift(updated: now, created: now, day: start.adding(day), jobID: job.id, time: job.time,
                              hourly: job.hourly, card: 12_450 + (index % 5) * 2860, cash: 4900 + index * 450, sales: 128_000)
            shift.payouts = job.rules.map { $0.payout(sales: shift.sales, tips: shift.gross) }
            data.ledger.put(shift)
        }
        data.preferences.lastJob = first.id
        data.preferences.loggedFirstShift = true
        return data
    }
}
