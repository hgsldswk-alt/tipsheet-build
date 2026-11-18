import SwiftUI

private enum InsightPeriod: String, CaseIterable, Identifiable {
    case week, month, year, pay, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .week: L.t("Week")
        case .month: L.t("Month")
        case .year: L.t("Year")
        case .pay: L.t("Pay period")
        case .custom: L.t("Custom")
        }
    }
}

struct InsightsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var period = InsightPeriod.week
    @State private var selectedAnchor: Day?
    private var anchor: Day { selectedAnchor ?? model.today }
    @State private var from = Date()
    @State private var through = Date()
    @State private var jobID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L.t("Insights")).font(.largeTitle.bold())
                    Spacer()
                    Button { model.sheet = .settings } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel(L.t("Settings"))
                }
                if model.hasPro { report }
                else { locked }
            }
            .padding(.horizontal, 20).padding(.vertical, 9)
        }
        .accessibilityIdentifier("insightsScreen")
    }

    private var range: DayRange {
        let calendar = Calendar.tipsheet
        let prefs = model.data.preferences
        switch period {
        case .week: return anchor.week(firstWeekday: prefs.firstWeekday)
        case .pay: return prefs.payCycle.range(at: anchor, firstWeekday: prefs.firstWeekday, anchor: prefs.payAnchor)
        case .month, .year:
            if let date = anchor.date(), let interval = calendar.dateInterval(of: period == .month ? .month : .year, for: date) {
                return DayRange(start: Day(interval.start), end: Day(interval.end))
            }
            return model.week
        case .custom: return DayRange(start: Day(min(from, through)), end: Day(max(from, through)).adding(1))
        }
    }

    private var report: some View {
        let rows = model.rows(in: range, jobID: jobID)
        return VStack(alignment: .leading, spacing: 15) {
            filters
            if period == .custom {
                VStack {
                    DatePicker(L.t("From"), selection: $from, displayedComponents: .date)
                    DatePicker(L.t("Through"), selection: $through, displayedComponents: .date)
                }
                .padding(12).ledgerCard()
            } else {
                rangeNavigator
            }
            composition(Totals(rows))
            Button { model.sheet = .tax } label: { linkLabel(L.t("Tax report"), icon: "doc.text") }
                .buttonStyle(.plain).accessibilityIdentifier("taxReport")
            if !rows.isEmpty {
                weekdayBreakdown(rows)
                jobBreakdown(rows)
                shiftBreakdown(rows)
                if let best = rows.max(by: { $0.total < $1.total }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Best shift")).font(.headline)
                        Button { model.sheet = .shift(best.shift.day, best.shift, focus: false) } label: { ShiftRow(item: best) }
                            .buttonStyle(.plain)
                    }
                    .padding(14).ledgerCard()
                }
            }
            Button { model.sheet = .milestones } label: { linkLabel(L.t("Milestones"), icon: "flag") }
                .buttonStyle(.plain).accessibilityIdentifier("milestonesButton")
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(InsightPeriod.allCases) { candidate in
                    Button(candidate.title) {
                        period = candidate
                        selectedAnchor = nil
                    }
                }
            } label: {
                Label(period.title, systemImage: "chevron.up.chevron.down").lineLimit(1).padding(10)
                    .background(Palette.soft, in: Capsule())
            }
            .accessibilityIdentifier("insightsPeriod")
            Spacer()
            Menu {
                Button(L.t("All jobs")) { jobID = nil }
                ForEach(model.jobs) { job in Button(job.title) { jobID = job.id } }
            } label: {
                Label(jobID.map { model.job($0).title } ?? L.t("All jobs"), systemImage: "line.3.horizontal.decrease")
                    .lineLimit(1).padding(10).background(Palette.soft, in: Capsule())
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private var rangeNavigator: some View {
        HStack {
            Button { selectedAnchor = range.start.adding(-1) } label: { Image(systemName: "chevron.left").frame(width: 42, height: 38) }
                .accessibilityLabel(L.t("Previous period"))
            Spacer()
            Text(Display.range(range)).font(.subheadline.weight(.medium))
            Spacer()
            Button { selectedAnchor = range.end } label: { Image(systemName: "chevron.right").frame(width: 42, height: 38) }
                .accessibilityLabel(L.t("Next period"))
        }
        .buttonStyle(.plain)
    }

    private func composition(_ totals: Totals) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.display(totals.total)).font(.title.bold()).ledgerNumber()
                Spacer()
                Text(model.hourly(totals.hourly)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent).ledgerNumber()
            }
            Divider()
            LabelValue(label: L.t("Gross tips"), value: model.display(totals.gross))
            LabelValue(label: L.t("Tip out"), value: model.display(totals.tipOut))
            LabelValue(label: L.t("Net tips"), value: model.display(totals.net))
            LabelValue(label: L.t("Wages"), value: model.display(totals.wages))
            LabelValue(label: L.t("Hours"), value: Display.hours(totals.minutes))
        }
        .padding(16).ledgerCard()
    }

    private func weekdayBreakdown(_ rows: [EarnedShift]) -> some View {
        let calendar = Calendar.tipsheet
        let groups = Dictionary(grouping: rows, by: { row in
            row.shift.day.date().map { calendar.component(.weekday, from: $0) } ?? 1
        })
        let order = (0..<7).map { ($0 + model.data.preferences.firstWeekday - 1) % 7 + 1 }
        let values = order.compactMap { weekday in
            groups[weekday].flatMap { group in
                group.first.map { (Display.day($0.shift.day, style: .dateTime.weekday(.wide)), Totals(group)) }
            }
        }
        return breakdown(L.t("By weekday"), values: values)
    }

    private func jobBreakdown(_ rows: [EarnedShift]) -> some View {
        let groups = Dictionary(grouping: rows, by: { $0.shift.jobID })
        return breakdown(L.t("By job"), values: model.jobs.compactMap { job in groups[job.id].map { (job.title, Totals($0)) } })
    }

    private func shiftBreakdown(_ rows: [EarnedShift]) -> some View {
        let groups = Dictionary(grouping: rows, by: { $0.shift.time.start >= 16 * 60 || $0.shift.time.start < 5 * 60 })
        return breakdown(L.t("By shift"), values: [false, true].compactMap { late in
            groups[late].map { (late ? L.t("Evening") : L.t("Daytime"), Totals($0)) }
        })
    }

    private func breakdown(_ title: String, values: [(String, Totals)]) -> some View {
        let maximum = Double(max(1, values.compactMap { $0.1.hourly }.map(abs).max() ?? 0))
        return VStack(alignment: .leading, spacing: 11) {
            Text(title).font(.headline)
            ForEach(values.indices, id: \.self) { index in
                let (label, totals) = values[index]
                VStack(alignment: .leading, spacing: 5) {
                    LabelValue(label: label, value: model.hourly(totals.hourly))
                    GeometryReader { geometry in
                        Capsule().fill(Palette.accent.opacity(0.75))
                            .frame(width: geometry.size.width * Double(abs(totals.hourly ?? 0)) / maximum)
                    }
                    .frame(height: 5)
                    .background(Palette.soft, in: Capsule())
                    .accessibilityHidden(true)
                }
            }
        }
        .padding(14).ledgerCard()
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("See what your time earns")).font(.title2.bold())
            Text(L.t("Compare shifts, review a pay period, and prepare a tip report.")).foregroundStyle(Palette.subdued)
            Button(L.t("Explore Pro")) { model.sheet = .paywall }
                .buttonStyle(.borderedProminent)
            Button { model.sheet = .milestones } label: { linkLabel(L.t("Milestones"), icon: "flag") }
                .buttonStyle(.plain)
        }
        .padding(17).ledgerCard()
    }

    private func linkLabel(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
        }
        .padding(14).ledgerCard()
    }
}

struct LabelValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Palette.subdued)
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).ledgerNumber()
        }
        .font(.subheadline).accessibilityElement(children: .combine)
    }
}
