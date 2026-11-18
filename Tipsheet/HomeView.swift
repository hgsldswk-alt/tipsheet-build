import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize = 52.0
    @State private var selected: Day?

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: 0) {
                top
                headline.padding(.top, 20)
                weekChart.padding(.top, 25)
                metrics.padding(.top, 18)
                recentTitle.padding(.top, 24)
            }
            .listRowInsets(EdgeInsets(top: 1, leading: 22, bottom: 9, trailing: 22))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if model.displayRows.isEmpty {
                Text(L.t("Log your first shift — it takes about ten seconds."))
                    .font(.subheadline).foregroundStyle(Palette.subdued)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading).ledgerCard()
                    .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else {
                ForEach(Array(model.displayRows.reversed().prefix(12).enumerated()), id: \.element.id) { item in
                    row(item.element, index: item.offset, count: min(model.displayRows.count, 12))
                }
            }

            if showCloudHint {
                HStack {
                    Button {
                        model.sheet = .settings
                    } label: {
                        Label(L.t("Turn on iCloud to sync your shifts."), systemImage: "icloud.slash")
                            .font(.footnote).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        model.set(\.dismissedCloudHint, true)
                    } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel(L.t("Dismiss"))
                }
                .foregroundStyle(Palette.subdued)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .accessibilityIdentifier("homeScreen")
    }

    private var showCloudHint: Bool {
        !model.data.preferences.dismissedCloudHint && model.data.ledger.shifts.count >= 10 &&
            (model.cloudState == .unavailable || model.cloudState == .disabled)
    }

    private var top: some View {
        HStack(spacing: 1) {
            Text(Display.range(model.week)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.subdued)
            Spacer(minLength: 8)
            if model.jobs.count > 1 {
                Menu {
                    Button(L.t("All jobs")) { model.jobFilter = nil }
                    ForEach(model.jobs) { job in
                        Button(job.title) { model.jobFilter = job.id }
                    }
                } label: {
                    Image(systemName: model.jobFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .frame(width: 44, height: 43)
                }
                .accessibilityLabel(L.t("Filter jobs"))
            }
            Button {
                model.set(\.hideAmounts, !model.hidden)
            } label: {
                Image(systemName: model.hidden ? "eye.slash" : "eye").frame(width: 43, height: 43)
            }
            .accessibilityLabel(model.hidden ? L.t("Show amounts") : L.t("Hide amounts"))
            .accessibilityIdentifier("privacyButton")
            Button { model.sheet = .settings } label: {
                Image(systemName: "gearshape").frame(width: 43, height: 43)
            }
            .accessibilityLabel(L.t("Settings")).accessibilityIdentifier("settingsButton")
        }
        .font(.system(size: 20))
        .buttonStyle(.plain)
        .foregroundStyle(Palette.subdued)
    }

    private var headline: some View {
        let totals = Totals(model.weekRows)
        let prior = DayRange(start: model.week.start.adding(-7), end: model.week.start)
        let difference = totals.total - Totals(model.rows(in: prior, jobID: model.jobFilter)).total
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L.t("This week")).font(.subheadline.weight(.medium)).foregroundStyle(Palette.subdued)
                Spacer()
                if model.canShare {
                    Button { model.sheet = .weekShare } label: {
                        Label(L.t("Share"), systemImage: "square.and.arrow.up").font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).accessibilityIdentifier("shareWeek")
                }
            }
            headlineAmount(totals.total).accessibilityIdentifier("weeklyTotal")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { headlineDetails(totals, difference: difference) }
                VStack(alignment: .leading, spacing: 3) { headlineDetails(totals, difference: difference) }
            }
        }
    }

    private func headlineAmount(_ value: Int) -> some View {
        let shown = model.display(value)
        let separator = Locale.current.decimalSeparator ?? "."
        let parts = shown.components(separatedBy: separator)
        let regular = Font.system(size: amountSize, weight: .semibold, design: .rounded)
        let major = Text(parts.count == 2 ? parts[0] : shown)
            .font(regular)
        let minor = Text(parts.count == 2 ? separator + parts[1] : "")
            .font(.system(.title2, design: .rounded).weight(.medium)).foregroundColor(Palette.subdued)
        return (major + minor)
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
    }

    @ViewBuilder private func headlineDetails(_ totals: Totals, difference: Int) -> some View {
        Text(model.hourly(totals.hourly)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent).ledgerNumber()
        if model.hidden {
            Text(L.t("Amounts hidden")).font(.footnote).foregroundStyle(Palette.subdued)
        } else {
            Text(L.f("%@ vs last week", (difference > 0 ? "+" : "") + Money.text(difference)))
                .font(.footnote).foregroundStyle(Palette.subdued).ledgerNumber()
        }
    }

    private var weekChart: some View {
        let days = (0..<7).map { model.week.start.adding($0) }
        let values = days.map { day in Totals(model.weekRows.filter { $0.shift.day == day }).total }
        let maxValue = Double(max(1, values.map(abs).max() ?? 0))
        return VStack(alignment: .leading, spacing: 6) {
            if let selected, let index = days.firstIndex(of: selected) {
                Text(L.f("%@ · %@", Display.day(selected, style: .dateTime.weekday(.wide)), model.display(values[index])))
                    .font(.footnote.weight(.medium)).foregroundStyle(Palette.subdued)
            }
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(days.indices, id: \.self) { index in
                    let day = days[index]
                    let value = values[index]
                    let active = day == (selected ?? model.today)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { selected = selected == day ? nil : day }
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(value == 0 ? Palette.line : active ? Palette.accent : Palette.bar)
                                .frame(height: value == 0 ? 3 : max(5, Double(abs(value)) / maxValue * 96))
                            Text(Display.day(day, style: .dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(active ? Palette.ink : Palette.subdued)
                        }
                        .frame(maxWidth: .infinity, minHeight: 114, alignment: .bottom)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.f("%@ · %@", Display.day(day), model.display(value)))
                }
            }
        }
    }

    private var metrics: some View {
        let totals = Totals(model.weekRows)
        return HStack(spacing: 0) {
            metric(L.t("Tips"), model.display(totals.net))
            Divider().overlay(Palette.line)
            metric(L.t("Wages"), model.display(totals.wages))
            Divider().overlay(Palette.line)
            metric(L.t("Hours"), Display.hours(totals.minutes))
        }
        .padding(.vertical, 14)
        .fixedSize(horizontal: false, vertical: true)
        .ledgerCard()
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.subdued)
            Text(value).font(.system(.headline, design: .rounded)).ledgerNumber()
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .padding(.horizontal, 13).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var recentTitle: some View {
        HStack {
            Text(L.t("Recent shifts")).font(.headline)
            Spacer()
            Button(L.t("Calendar")) { model.tab = .calendar }.font(.subheadline.weight(.medium))
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, 2)
    }

    private func row(_ item: EarnedShift, index: Int, count: Int) -> some View {
        let top = index == 0 ? 18.0 : 0.0
        let bottom = index == count - 1 ? 18.0 : 0.0
        return Button {
            model.sheet = .shift(item.shift.day, item.shift, focus: false)
        } label: {
            ShiftRow(item: item)
                .padding(.horizontal, 13)
                .background(alignment: .bottom) {
                    if index < count - 1 { Divider().overlay(Palette.line).padding(.horizontal, 14) }
                }
                .background(Palette.card, in: UnevenRoundedRectangle(
                    topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top))
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { model.deactivate(item.shift) } label: { Label(L.t("Delete"), systemImage: "trash") }
        }
        .accessibilityIdentifier("recentShift-" + String(index))
    }
}

struct ShiftRow: View {
    @EnvironmentObject private var model: AppModel
    var item: EarnedShift
    var body: some View {
        let shift = item.shift
        let job = model.job(shift.jobID)
        HStack(spacing: 10) {
            VStack(spacing: 1) {
                Text(Display.day(shift.day, style: .dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(Palette.subdued)
                Text(Display.day(shift.day, style: .dateTime.day())).font(.headline).ledgerNumber()
            }
            .frame(minWidth: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { JobDot(job: job); Text(job.title).font(.subheadline.weight(.medium)) }
                    .lineLimit(2)
                let time = L.f("%@ – %@", Display.clock(shift.time.start).formatted(date: .omitted, time: .shortened),
                               Display.clock(shift.time.end).formatted(date: .omitted, time: .shortened))
                Text(shift.tipOut > 0 && !model.hidden ? time + " · " + L.f("Tip out %@", Money.text(shift.tipOut)) : time)
                    .font(.caption2).foregroundStyle(Palette.subdued)
            }
            Spacer(minLength: 3)
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.display(item.total)).font(.subheadline.weight(.semibold))
                Text(model.hourly(item.hourly)).font(.caption2).foregroundStyle(Palette.subdued)
            }
            .ledgerNumber()
        }
        .padding(.vertical, 12).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}
