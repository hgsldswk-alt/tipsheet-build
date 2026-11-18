import SwiftUI

private struct EditorDraft: Equatable {
    var shift: Shift
    var card: String
    var cash: String
    var hourly: String
    var sales: String
    var pool: String
    var covers: String
    var manual: String
    var reported: String
    var tags: String

    init(day: Day, existing: Shift?, job: Job) {
        let value = existing ?? Shift(day: day, jobID: job.id, time: job.time, hourly: job.hourly, overtime: job.overtime)
        shift = value
        card = Self.input(value.card)
        cash = Self.input(value.cash)
        hourly = Self.input(value.hourly)
        sales = Self.input(value.sales)
        pool = Self.input(value.pool)
        covers = value.covers == 0 ? "" : String(value.covers)
        manual = value.manualTipOut.map { Money.entry($0) } ?? ""
        reported = value.reported.map { Money.entry($0) } ?? ""
        tags = value.tags.joined(separator: ", ")
    }

    static func input(_ value: Int) -> String { value == 0 ? "" : Money.entry(value) }

    func value(using job: Job, pro: Bool, existing: Bool) -> Shift? {
        guard let card = Money.cents(card), let cash = Money.cents(cash), let hourly = Money.cents(hourly),
              let sales = Money.cents(sales), let pool = Money.cents(pool),
              let manual = Money.cents(manual), let reported = Money.cents(reported),
              let covers = Int(covers.isEmpty ? "0" : covers) else { return nil }
        var result = shift
        result.card = card
        result.cash = cash
        result.hourly = hourly
        result.sales = sales
        result.pool = pool
        result.covers = covers
        result.manualTipOut = self.manual.isEmpty ? nil : manual
        result.reported = self.reported.isEmpty ? nil : reported
        result.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !existing {
            result.overtime = pro ? job.overtime : Overtime()
            result.appliedRules = pro ? job.rules : []
        }
        if (!existing || pro), let rules = result.appliedRules {
            result.payouts = rules.map { $0.payout(sales: result.sales, tips: result.gross) }
        }
        return result.isValid ? result : nil
    }
}

struct ShiftEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EditorDraft
    @State private var showTime = false
    @State private var showDetails = false
    @State private var showTipOverrides = false
    @State private var showPool = false
    @State private var showJob = false
    @State private var showMembership = false
    @State private var jobName = ""
    @State private var poolTotal = ""
    @State private var poolHours = ""
    @FocusState private var focus: Field?
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize = 34.0
    private enum Field: Hashable { case card, cash }
    let existing: Shift?
    let shouldFocus: Bool

    init(day: Day, existing: Shift?, shouldFocus: Bool, job: Job) {
        _draft = State(initialValue: EditorDraft(day: day, existing: existing, job: job))
        self.existing = existing
        self.shouldFocus = shouldFocus
    }

    private var job: Job { model.job(draft.shift.jobID) }
    private var useValue: Shift? { draft.value(using: job, pro: model.hasPro, existing: existing != nil) }
    private var preview: EarnedShift? { useValue.flatMap { model.preview($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 13) {
                    jobs
                    HStack(alignment: .top, spacing: 10) {
                        amountBox(L.t("Card tips"), value: $draft.card, field: .card, identifier: "cardTips")
                        amountBox(L.t("Cash tips"), value: $draft.cash, field: .cash, identifier: "cashTips")
                    }
                    mainForm
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
                    } label: {
                        Label(job.isDelivery ? L.t("Deliveries and notes") : L.t("Sales, covers, notes"),
                              systemImage: showDetails ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.medium)).padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("shiftDetails")
                    if showDetails { details }
                    HStack {
                        Text(L.t("This shift")).foregroundStyle(Palette.subdued)
                        Spacer()
                        Text(model.hourly(preview?.hourly)).font(.title3.weight(.semibold)).foregroundStyle(Palette.accent)
                            .ledgerNumber().accessibilityIdentifier("shiftHourly")
                    }
                    .font(.subheadline).padding(.horizontal, 4)
                    if !Launch.freePeriod, !model.data.preferences.loggedFirstShift, !model.data.entitlement.purchasedPro,
                       model.data.entitlement.remainingDays(at: model.now) > 0 {
                        Text(L.f("Pro is free for 30 days. Then %@ once to keep job rules, full reports, widgets and reminders. Logging and export stay free.",
                                 model.proPriceText ?? "US$5.99"))
                            .font(.footnote).foregroundStyle(Palette.subdued)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if useValue == nil {
                        Text(L.t("Check the amounts and hours.")).font(.footnote).foregroundStyle(Palette.subdued)
                    }
                    if let shift = useValue, existing != nil, shift.tipOut > 0 {
                        Button {
                            model.sheet = .receipt(shift)
                        } label: {
                            Label(L.t("Share tip-out receipt"), systemImage: "square.and.arrow.up")
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .ledgerCanvas()
            .navigationTitle(Display.day(draft.shift.day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if existing == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(L.t("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L.t("Save")) {
                            if let value = useValue { _ = model.save(value, new: true) }
                        }
                        .fontWeight(.semibold).disabled(useValue == nil).accessibilityIdentifier("saveShift")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L.t("Done")) {
                            if let value = useValue, model.save(value, new: false) { dismiss() }
                        }
                            .disabled(useValue == nil)
                            .accessibilityIdentifier("doneShift")
                    }
                }
            }
            .alert(L.t("New job"), isPresented: $showJob) {
                TextField(L.t("Job name"), text: $jobName)
                Button(L.t("Cancel"), role: .cancel) {}
                Button(L.t("Add")) {
                    if let job = model.createJob(named: jobName) { select(job) }
                }
            }
            .sheet(isPresented: $showMembership) {
                PaywallView().ledgerCanvas()
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-sample-shift") {
                    draft.card = "284"
                    draft.sales = "1600"
                }
                #endif
                guard shouldFocus else { return }
                try? await Task.sleep(for: .milliseconds(350))
                if !Task.isCancelled { focus = .card }
            }
            .onChange(of: useValue) { old, new in
                if existing != nil, let new, old != new { _ = model.save(new, new: false) }
            }
            .accessibilityIdentifier("shiftEditor")
        }
    }

    private var jobs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(model.jobs) { job in
                    Button { select(job) } label: {
                        HStack(spacing: 6) {
                            JobDot(job: job)
                            Text(job.title).lineLimit(1)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .foregroundStyle(draft.shift.jobID == job.id ? Palette.accent : Palette.subdued)
                        .background(draft.shift.jobID == job.id ? Palette.soft : Palette.card, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.shift.jobID == job.id ? .isSelected : [])
                }
                Button {
                    focus = nil
                    if model.hasPro { jobName = ""; showJob = true }
                    else { showMembership = true }
                } label: {
                    Image(systemName: "plus").fontWeight(.semibold)
                        .frame(width: 40, height: 37).background(Palette.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.t("New job"))
            }
        }
        .scrollIndicators(.hidden)
    }

    private func select(_ job: Job) {
        guard draft.shift.jobID != job.id else { return }
        draft.shift.jobID = job.id
        draft.hourly = EditorDraft.input(job.hourly)
        if existing == nil {
            draft.shift.time = job.time
        } else if model.hasPro {
            draft.shift.overtime = job.overtime
            draft.shift.appliedRules = job.rules
        }
    }

    private func amountBox(_ title: String, value: Binding<String>, field: Field, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(Palette.subdued)
            HStack(spacing: 2) {
                Text(Locale.current.currencySymbol ?? "$").accessibilityHidden(true)
                TextField("", text: value, prompt: Text("0").foregroundColor(Palette.subdued))
                    .keyboardType(.decimalPad).focused($focus, equals: field)
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
            }
            .font(.system(size: amountSize, weight: .semibold, design: .rounded))
            .ledgerNumber()
        }
        .padding(13).ledgerCard()
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(focus == field ? Palette.accent : .clear, lineWidth: 2) }
    }

    private var mainForm: some View {
        VStack(spacing: 0) {
            Button {
                focus = nil
                withAnimation { showTime.toggle() }
            } label: {
                HStack {
                    Text(L.t("Hours")).foregroundStyle(Palette.subdued)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(L.f("%@ – %@", Display.clock(draft.shift.time.start).formatted(date: .omitted, time: .shortened),
                                 Display.clock(draft.shift.time.end).formatted(date: .omitted, time: .shortened)))
                        if draft.shift.time.breakMinutes > 0 || draft.shift.time.wraps {
                            Text(timeDetail).font(.caption2).foregroundStyle(Palette.subdued)
                        }
                    }.ledgerNumber()
                    Image(systemName: showTime ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(Palette.subdued)
                }
                .frame(minHeight: 49)
            }
            .buttonStyle(.plain).accessibilityIdentifier("shiftHours")
            if showTime { timeFields }
            Divider().overlay(Palette.line)
            Button {
                focus = nil
                withAnimation { showTipOverrides.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Tip out"))
                        if existing == nil, model.hasPro, !job.rules.isEmpty {
                            Text(job.rules.map(\.name).joined(separator: " + ")).font(.caption2).lineLimit(1)
                        }
                    }
                    .foregroundStyle(Palette.subdued)
                    Spacer()
                    Text(Money.text(-(useValue?.tipOut ?? 0))).ledgerNumber()
                    Image(systemName: showTipOverrides ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(Palette.subdued)
                }
                .frame(minHeight: 49)
            }.buttonStyle(.plain)
            if showTipOverrides {
                Divider()
                input(L.t("Override tip out"), text: $draft.manual)
                TextField(L.t("Who received tip out"), text: $draft.shift.recipientNames).padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 13).ledgerCard()
    }

    private var timeDetail: String {
        [draft.shift.time.wraps ? L.t("Next day") : "",
         draft.shift.time.breakMinutes > 0 ? L.f("%@ min break", String(draft.shift.time.breakMinutes)) : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var timeFields: some View {
        VStack(spacing: 8) {
            Divider()
            DatePicker(L.t("Shift date"), selection: Binding(get: { draft.shift.day.date() ?? Date() },
                             set: { draft.shift.day = Day($0) }), displayedComponents: .date)
            DatePicker(L.t("Start"), selection: clockBinding(\.start), displayedComponents: .hourAndMinute)
            DatePicker(L.t("End"), selection: clockBinding(\.end), displayedComponents: .hourAndMinute)
            HStack {
                Text(L.t("Break minutes"))
                Spacer()
                TextField("0", text: Binding(get: { String(draft.shift.time.breakMinutes) },
                        set: { draft.shift.time.breakMinutes = min(1439, max(0, Int($0) ?? 0)) }))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            input(L.t("Base hourly wage"), text: $draft.hourly)
        }
        .padding(.bottom, 9)
    }

    private func clockBinding(_ part: WritableKeyPath<WorkTime, Int>) -> Binding<Date> {
        Binding(get: { Display.clock(draft.shift.time[keyPath: part]) },
                set: { draft.shift.time[keyPath: part] = Display.minute($0) })
    }

    private var details: some View {
        VStack(spacing: 0) {
            input(L.t("Sales"), text: $draft.sales)
            Divider()
            input(job.isDelivery ? L.t("Deliveries") : L.t("Covers"), text: $draft.covers, keyboard: .numberPad)
            Divider()
            input(L.t("Tip pool received"), text: $draft.pool)
            Button(L.t("Pool calculator")) {
                focus = nil
                showPool.toggle()
            }
            .frame(maxWidth: .infinity, alignment: .trailing).font(.subheadline).padding(.bottom, 9)
            if showPool {
                input(L.t("Total pool"), text: $poolTotal)
                input(L.t("Total staff hours"), text: $poolHours)
                Button(L.t("Use my share")) {
                    guard let share = calculatedPool else { return }
                    draft.pool = Money.entry(share)
                    showPool = false
                }
                .disabled(calculatedPool == nil).padding(.bottom, 9)
            }
            Divider()
            input(L.t("Tips reported to employer"), text: $draft.reported)
            Divider()
            TextField(L.t("Notes"), text: $draft.shift.notes, axis: .vertical).lineLimit(2...5).padding(.vertical, 10)
            if model.hasPro || !draft.tags.isEmpty {
                Divider()
                TextField(L.t("Tags, separated by commas"), text: $draft.tags).padding(.vertical, 10)
            }
        }.padding(.horizontal, 13).ledgerCard()
    }

    private var calculatedPool: Int? {
        guard let cents = Money.cents(poolTotal), !poolTotal.isEmpty,
              let hundredths = Money.cents(poolHours), hundredths > 0,
              let value = useValue, value.time.minutes * 100 <= hundredths * 60 else { return nil }
        return Totals.rounded(cents * value.time.minutes * 100, dividedBy: hundredths * 60)
    }

    private func input(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .decimalPad) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.subdued)
            Spacer(minLength: 12)
            TextField("0", text: text).keyboardType(keyboard).multilineTextAlignment(.trailing)
                .frame(minWidth: 45, idealWidth: 75, maxWidth: 110).accessibilityLabel(title)
        }
        .padding(.vertical, 9)
    }
}
