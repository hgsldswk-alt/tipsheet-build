import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.requestReview) private var requestReview
    @State private var input: Input?
    @State private var showPicker = false
    @State private var previewCSV = false

    private enum Input: Equatable { case backup, csv }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        JobsView()
                    } label: { Label(L.t("Jobs"), systemImage: "briefcase") }
                    Picker(L.t("Week starts on"), selection: binding(\.firstWeekday)) {
                        ForEach(1...7, id: \.self) { day in
                            Text(weekday(day)).tag(day)
                        }
                    }
                    Picker(L.t("Pay cycle"), selection: binding(\.payCycle)) {
                        ForEach(PayCycle.allCases) { cycle in Text(cycle.title).tag(cycle) }
                    }
                    if model.data.preferences.payCycle == .biweekly {
                        DatePicker(L.t("First day of a pay period"), selection: Binding(
                            get: { model.data.preferences.payAnchor.date() ?? model.now },
                            set: { model.set(\.payAnchor, Day($0)) }), displayedComponents: .date)
                    }
                }

                Section {
                    Toggle(L.t("Hide amounts"), isOn: binding(\.hideAmounts))
                    Toggle(L.t("Face ID or passcode"), isOn: Binding(get: { model.data.preferences.biometrics && model.hasPro },
                        set: { value in Task { await model.setBiometrics(value) } }))
                    Toggle(L.t("After-shift reminder"), isOn: Binding(get: { model.data.preferences.reminders && model.hasPro },
                        set: { value in Task { await model.setReminders(value) } }))
                }

                Section(L.t("Your data")) {
                    Toggle(L.t("iCloud sync"), isOn: Binding(get: { model.data.preferences.cloudEnabled }, set: model.setCloud))
                    if model.data.preferences.cloudEnabled {
                        Button { model.requestCloud() } label: {
                            Label(cloudStatus, systemImage: "icloud").font(.subheadline)
                        }
                        .disabled(model.cloudState == .running)
                    }
                    Button(L.t("Export CSV")) { model.exportCSV() }.accessibilityIdentifier("exportCSV")
                    Button(L.t("Export backup")) { model.exportBackup() }
                    Button(L.t("Restore backup")) { pick(.backup) }
                    Button(L.t("Import CSV")) { if model.requirePro() { pick(.csv) } }
                    NavigationLink(L.t("Recently deleted")) { TrashView() }
                }

                Section {
                    Button { model.sheet = .coworker } label: {
                        Label(L.t("Tell a coworker"), systemImage: "person.2")
                    }
                    Link(destination: StoreLinks.support) { Label(L.t("Privacy and help"), systemImage: "questionmark.circle") }
                    Button { requestReview() } label: { Label(L.t("Rate Tipsheet"), systemImage: "star") }
                    if !Launch.freePeriod {
                        Button { model.sheet = .paywall } label: {
                            Label(model.data.entitlement.purchasedPro ? L.t("Tipsheet Pro") : L.t("Try or buy Pro"), systemImage: "sparkle")
                        }
                        .accessibilityIdentifier("upgradeButton")
                    }
                }
            }
            .scrollContentBackground(.hidden).ledgerCanvas()
            .navigationTitle(L.t("Settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { CloseButton() } }
            .navigationDestination(isPresented: $previewCSV) { CSVPreview() }
            .onChange(of: model.importRows.isEmpty) { _, empty in
                if !empty { previewCSV = true }
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: input == .backup ? [.tipsheetBackup] : [.commaSeparatedText, .plainText]) { result in
            guard let url = try? result.get() else { return }
            if input == .backup { model.restoreFile(url) }
            else { model.loadCSV(url) }
        }
        .accessibilityIdentifier("settingsScreen")
    }

    private func pick(_ file: Input) {
        input = file
        model.importRows = []
        showPicker = true
    }

    private func binding<T>(_ key: WritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { model.data.preferences[keyPath: key] }, set: { model.set(key, $0) })
    }

    private func weekday(_ day: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.weekdaySymbols[day - 1]
    }

    private var cloudStatus: String {
        switch model.cloudState {
        case .checking: L.t("Check iCloud sync")
        case .disabled: L.t("iCloud sync off")
        case .unavailable: L.t("iCloud unavailable · records saved on this iPhone")
        case .running: L.t("Syncing with iCloud…")
        case .synced(let date): L.f("Synced %@", date.formatted(.relative(presentation: .named)))
        case .failed: L.t("Sync paused · tap to retry")
        case .changedAccount: L.t("iCloud account changed · sync paused")
        }
    }
}

extension UTType {
    static let tipsheetBackup = UTType(exportedAs: "com.hgsldswk.tipsheet.backup")
}

struct TrashView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if model.deleted.isEmpty { Text(L.t("No recently deleted shifts")).foregroundStyle(Palette.subdued) }
            else {
                Section {
                    ForEach(model.deleted) { entry in
                        if let shift = entry.shift {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.job(shift.jobID).title)
                                    Text(Display.day(shift.day)).font(.caption).foregroundStyle(Palette.subdued)
                                }
                                Spacer()
                                Button(L.t("Restore")) { model.restore(entry.id) }
                            }
                        }
                    }
                } footer: { Text(L.t("Deleted shifts can be restored for 30 days.")) }
            }
        }
        .scrollContentBackground(.hidden).ledgerCanvas()
        .navigationTitle(L.t("Recently deleted")).navigationBarTitleDisplayMode(.inline)
    }
}

struct CSVPreview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(Array(model.importRows.prefix(40).enumerated()), id: \.offset) { item in
                    let row = item.element
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.f("%@ · %@", Display.day(row.day), row.job.isEmpty ? L.t("My job") : row.job))
                        Text(L.f("%@ in tips · %@ hr", model.display(row.card + row.cash + row.pool - row.tipOut), Display.hours(row.time.minutes)))
                            .font(.caption).foregroundStyle(Palette.subdued)
                    }
                }
            } header: {
                Text(L.f("Shifts to import: %@", model.importRows.count.formatted()))
            }
        }
        .scrollContentBackground(.hidden).ledgerCanvas()
        .navigationTitle(L.t("CSV preview")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("Import")) { if model.confirmCSV() { dismiss() } }
                    .disabled(model.importRows.isEmpty)
            }
        }
        .onDisappear { model.importRows = [] }
    }
}

struct JobsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newJob = false

    var body: some View {
        List {
            ForEach(model.jobs) { job in
                NavigationLink {
                    JobEditor(job: job)
                } label: {
                    HStack(spacing: 8) { JobDot(job: job); Text(job.title) }
                }
            }
            Button {
                if model.requirePro() { newJob = true }
            } label: { Label(L.t("New job"), systemImage: "plus") }
        }
        .scrollContentBackground(.hidden).ledgerCanvas().navigationTitle(L.t("Jobs")).navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $newJob) { JobEditor(job: Job(color: model.jobs.count % 5), creating: true) }
    }
}

private struct RuleDraft: Identifiable {
    var rule: TipRule
    var amount: String
    var id: UUID { rule.id }

    init(_ rule: TipRule) {
        self.rule = rule
        amount = rule.value == 0 ? "" : Money.entry(rule.value)
    }
}

struct JobEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var job: Job
    @State private var hourly: String
    @State private var rules: [RuleDraft]
    let creating: Bool

    init(job: Job, creating: Bool = false) {
        _job = State(initialValue: job)
        _hourly = State(initialValue: job.hourly == 0 ? "" : Money.entry(job.hourly))
        _rules = State(initialValue: job.rules.map(RuleDraft.init))
        self.creating = creating
    }

    var body: some View {
        Form {
            Section {
                TextField(L.t("Job name"), text: $job.name)
                TextField(L.t("Base hourly wage"), text: $hourly).keyboardType(.decimalPad)
                HStack {
                    Text(L.t("Job color"))
                    Spacer()
                    ForEach(Palette.jobs.indices, id: \.self) { index in
                        Button {
                            job.color = index
                        } label: {
                            Circle().fill(Palette.jobs[index]).overlay {
                                if job.color == index { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                            }.frame(width: 23, height: 23).frame(minWidth: 33, minHeight: 42)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L.f("Color %@", String(index + 1)))
                        .accessibilityAddTraits(job.color == index ? .isSelected : [])
                    }
                }
                DatePicker(L.t("Start"), selection: clock(\.start), displayedComponents: .hourAndMinute)
                DatePicker(L.t("End"), selection: clock(\.end), displayedComponents: .hourAndMinute)
                Stepper(L.f("%@ min break", String(job.time.breakMinutes)), value: $job.time.breakMinutes, in: 0...240, step: 5)
            }
            if model.hasPro {
                Section(L.t("Overtime at 1.5×")) {
                    Toggle(L.t("After 40 hours per week"), isOn: $job.overtime.weekly)
                    Toggle(L.t("After 8 hours per day"), isOn: $job.overtime.daily)
                }
                Section(L.t("Tip-out rules")) {
                    ForEach($rules) { $draft in
                        VStack(alignment: .leading) {
                            TextField(L.t("Recipient or role"), text: $draft.rule.name)
                            Picker(L.t("Calculation"), selection: $draft.rule.basis) {
                                ForEach(TipRule.Basis.allCases) { basis in Text(basis.title).tag(basis) }
                            }
                            TextField(draft.rule.basis == .fixed ? L.t("Amount") : L.t("Percentage"), text: $draft.amount)
                                .keyboardType(.decimalPad)
                        }
                    }
                    .onDelete { rules.remove(atOffsets: $0) }
                    Button(L.t("Add rule")) { rules.append(RuleDraft(TipRule())) }.disabled(rules.count >= 20)
                }
            }
        }
        .scrollContentBackground(.hidden).ledgerCanvas()
        .navigationTitle(creating ? L.t("New job") : job.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("Save")) {
                    if let candidate, model.saveJob(candidate) { dismiss() }
                }
                .disabled(candidate == nil)
            }
        }
    }

    private var candidate: Job? {
        var value = job
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hourly = Money.cents(hourly), !creating || !value.name.isEmpty else { return nil }
        value.hourly = hourly
        if model.hasPro {
            value.rules = rules.compactMap { draft in
                guard let amount = Money.cents(draft.amount), !draft.amount.isEmpty else { return nil }
                var rule = draft.rule
                rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                rule.value = amount
                return rule.isValid ? rule : nil
            }
            guard value.rules.count == rules.count else { return nil }
        }
        return value.isValid ? value : nil
    }

    private func clock(_ key: WritableKeyPath<WorkTime, Int>) -> Binding<Date> {
        Binding(get: { Display.clock(job.time[keyPath: key]) }, set: { job.time[keyPath: key] = Display.minute($0) })
    }
}
