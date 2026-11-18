import SwiftUI
import WidgetKit

private struct TipEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetBridge.Snapshot?
    var placeholder = false

    var valid: Bool { snapshot.map { $0.unlimited || $0.proUntil.map { date < $0 } == true } ?? false }
    var current: Bool { snapshot.map { date < $0.periodEnd } ?? false }
}

private struct TipTimeline: TimelineProvider {
    func placeholder(in context: Context) -> TipEntry {
        let now = Date()
        return TipEntry(date: now, snapshot: WidgetBridge.Snapshot(total: "$1,284.60", hourly: "$34.20 / hr",
            bars: [0, 0.45, 0.60, 0, 1, 0.86, 0], currentDay: 5, periodEnd: .distantFuture,
            proUntil: nil, unlimited: true, hidden: false), placeholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (TipEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TipEntry(date: Date(), snapshot: WidgetBridge.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TipEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetBridge.read()
        var dates = [now]
        if let periodEnd = snapshot?.periodEnd, periodEnd > now { dates.append(periodEnd) }
        if let expiry = snapshot?.proUntil, expiry > now, snapshot?.unlimited == false { dates.append(expiry) }
        let entries = Set(dates).sorted().map { TipEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after((entries.last?.date ?? now).addingTimeInterval(3600))))
    }
}

private struct TipWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TipEntry

    private var total: String {
        guard let snapshot = entry.snapshot, entry.current else { return "—" }
        return snapshot.total
    }

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L.t("This week"), systemImage: "chart.bar")
                        .font(.caption).widgetAccentable()
                    Text(entry.valid ? total : L.t("Log shift")).font(.headline).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    if entry.valid {
                        HStack {
                            Text(L.t("This week")).font(.caption.weight(.medium))
                            Spacer()
                            if family == .systemMedium {
                                Link(destination: WidgetBridge.logURL) {
                                    Label(L.t("Log shift"), systemImage: "plus.circle.fill").font(.caption.weight(.semibold))
                                }
                            } else {
                                Image(systemName: "plus.circle.fill").imageScale(.medium).accessibilityHidden(true)
                            }
                        }
                        Text(total).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                            .minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                        Text(entry.current ? entry.snapshot?.hourly ?? "—" : "—").font(.caption.weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.5).privacySensitive()
                        if let snapshot = entry.snapshot, entry.current, !snapshot.hidden { bars(snapshot) }
                    } else {
                        Image(systemName: "chart.bar").font(.title2)
                        Text("Tipsheet").font(.headline)
                        Text(L.t("Log shift")).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Color(red: 0.11, green: 0.34, blue: 0.28))
            }
        }
        .containerBackground(for: .widget) { Color(red: 0.96, green: 0.95, blue: 0.92) }
        .widgetURL(WidgetBridge.logURL)
    }

    private func bars(_ snapshot: WidgetBridge.Snapshot) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(snapshot.bars.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.12, green: 0.36, blue: 0.29).opacity(index == snapshot.currentDay ? 0.9 : 0.25))
                    .frame(height: max(2, min(25, snapshot.bars[index] * 25)))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TipWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TipsheetWeek", provider: TipTimeline()) { entry in TipWidgetView(entry: entry) }
            .configurationDisplayName(L.t("Weekly earnings"))
            .description(L.t("See this week’s income and open the shift log."))
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@available(iOS 18.0, *)
private struct TipControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.hgsldswk.tipsheet.log") {
            ControlWidgetButton(action: OpenTipsheetLog(.log)) {
                Label(L.t("Log shift"), systemImage: "plus.circle")
            }
        }
        .displayName("Log shift")
        .description("Open Tipsheet to log a shift.")
    }
}

@main
struct TipsheetWidgets: WidgetBundle {
    var body: some Widget {
        TipWidget()
        if #available(iOS 18.0, *) { TipControl() }
    }
}
