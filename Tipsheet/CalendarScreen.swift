import SwiftUI

struct CalendarScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var viewedMonth: Day?
    private var month: Day { viewedMonth ?? model.today }

    private var interval: DateInterval? {
        month.date().flatMap { Calendar.tipsheet.dateInterval(of: .month, for: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L.t("Calendar")).font(.largeTitle.bold())
                    Spacer()
                    Button { model.sheet = .settings } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel(L.t("Settings"))
                }
                monthHeader
                grid
                if let interval {
                    let totals = Totals(model.rows(in: DayRange(start: Day(interval.start), end: Day(interval.end))))
                    summary(totals)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 9)
        }
        .accessibilityIdentifier("calendarScreen")
    }

    private var monthHeader: some View {
        HStack {
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(L.t("Previous month")).accessibilityIdentifier("previousMonth")
            Spacer()
            Button {
                viewedMonth = nil
            } label: {
                Text(Display.day(month, style: .dateTime.month(.wide).year()))
                    .font(.headline).foregroundStyle(Palette.ink)
            }
            .accessibilityHint(L.t("Return to this month"))
            Spacer()
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel(L.t("Next month")).accessibilityIdentifier("nextMonth")
        }
        .buttonStyle(.plain)
    }

    private func move(_ amount: Int) {
        guard let start = interval?.start, let next = Calendar.tipsheet.date(byAdding: .month, value: amount, to: start) else { return }
        viewedMonth = Day(next)
    }

    private var grid: some View {
        let first = interval.map { Day($0.start) } ?? model.today
        let end = interval.map { Day($0.end) } ?? first.adding(1)
        let week = first.week(firstWeekday: model.data.preferences.firstWeekday).start
        let raw = model.rows(in: DayRange(start: first, end: end))
        let groups = Dictionary(grouping: raw, by: { $0.shift.day }).mapValues { Totals($0).total }
        let maximum = Double(max(1, groups.values.map(abs).max() ?? 0))
        let count = (0..<42).first { week.adding($0) >= end } ?? 42
        let dayCells = ((count + 6) / 7) * 7
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 5) {
            ForEach(0..<7) { offset in
                Text(Display.day(week.adding(offset), style: .dateTime.weekday(.narrow)))
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.subdued)
                    .frame(maxWidth: .infinity)
            }
            ForEach(0..<dayCells, id: \.self) { offset in
                let day = week.adding(offset)
                if day >= first && day < end {
                    cell(day, amount: groups[day], scale: Double(abs(groups[day] ?? 0)) / maximum)
                } else {
                    Color.clear.frame(height: 49).accessibilityHidden(true)
                }
            }
        }
        .padding(8).ledgerCard()
    }

    private func cell(_ day: Day, amount: Int?, scale: Double) -> some View {
        Button {
            if amount == nil { model.logShift(day: day) }
            else { model.sheet = .day(day) }
        } label: {
            VStack(spacing: 3) {
                Text(Display.day(day, style: .dateTime.day()))
                    .font(.subheadline.weight(day == model.today ? .bold : .medium))
                if let amount {
                    Text(model.hidden ? "•••" : Money.text(amount))
                        .font(.caption2.weight(.medium)).foregroundStyle(Palette.accent)
                        .lineLimit(1).minimumScaleFactor(0.42)
                }
            }
            .padding(.horizontal, 1)
            .frame(maxWidth: .infinity, minHeight: 49)
            .background(amount == nil ? Color.clear : Palette.accent.opacity(0.09 + 0.14 * scale), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(day == model.today ? Palette.accent : .clear, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(amount.map { L.f("%@ · %@", Display.day(day), model.display($0)) } ?? Display.day(day))
        .accessibilityIdentifier("day-" + day.rawValue)
    }

    private func summary(_ totals: Totals) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("Month total")).font(.caption).foregroundStyle(Palette.subdued)
                Text(model.display(totals.total)).font(.title2.bold())
            }
            Spacer()
            Text(model.hourly(totals.hourly)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
        }
        .ledgerNumber().padding(16).ledgerCard()
    }
}

struct DayDetail: View {
    @EnvironmentObject private var model: AppModel
    let day: Day

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.rows(on: day)) { item in
                    Button {
                        model.sheet = .shift(day, item.shift, focus: false)
                    } label: { ShiftRow(item: item) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.deactivate(item.shift) } label: { Label(L.t("Delete"), systemImage: "trash") }
                        }
                        .listRowBackground(Palette.card)
                }
                if let id = model.undoID {
                    Button(L.t("Undo")) { model.restore(id) }.listRowBackground(Palette.card)
                }
                Button {
                    model.logShift(day: day)
                } label: {
                    Label(L.t("Log shift"), systemImage: "plus")
                }
                .listRowBackground(Palette.card)
            }
            .scrollContentBackground(.hidden).ledgerCanvas()
            .navigationTitle(Display.day(day)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { CloseButton() } }
        }
    }
}
