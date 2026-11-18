import Foundation
import SwiftUI
import UIKit

@MainActor
enum ExportFiles {
    static func write(_ data: Data, as file: String, in directory: URL? = nil) throws -> URL {
        let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    static func csv(_ rows: [EarnedShift], year: Int? = nil, directory: URL? = nil, jobName: (UUID) -> String) throws -> URL {
        let filename = year.map { "Tipsheet-\($0).csv" } ?? "Tipsheet-shifts.csv"
        let result = "\u{FEFF}" + ShiftCSV.export(rows, jobName: jobName)
        return try write(Data(result.utf8), as: filename, in: directory)
    }

    static func tax(_ rows: [EarnedShift], year: Int, jobName: (UUID) -> String) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let summary = Totals(rows)
        let currency = Locale.current.currency?.identifier ?? "USD"
        let annual = pdf(title: L.t("Annual tip summary"), subtitle: L.f("Year: %@ · Currency: %@", String(year), currency),
            headers: [L.t("Category"), L.t("Amount")], widths: [275, 214], rows: [
                [L.t("Cash tips"), Money.text(summary.cash)],
                [L.t("Card tips"), Money.text(summary.card)],
                [L.t("Tip pool received"), Money.text(summary.pool)],
                [L.t("Gross tips"), Money.text(summary.gross)],
                [L.t("Tip out"), Money.text(summary.tipOut)],
                [L.t("Net tips"), Money.text(summary.net)],
                [L.t("Wages"), Money.text(summary.wages)],
                [L.t("Hours"), Display.hours(summary.minutes)],
                [L.t("Tips reported to employer"), Money.text(summary.reported)],
                [L.t("Unreported difference"), Money.text(summary.net - summary.reported)]
            ])
        let daily = pdf(title: L.t("Daily record of tips"),
            subtitle: L.f("4070A-style record · %@ · %@", String(year), currency),
            headers: [L.t("Tips date"), L.t("Entry date"), L.t("Job"), L.t("Direct / pool"), L.t("Card"),
                      L.t("Tips paid out"), L.t("Paid to")],
            widths: [62, 62, 70, 72, 63, 70, 90], rows: rows.map { item in
                let shift = item.shift
                let names = shift.manualTipOut == nil
                    ? shift.payouts.filter { $0.cents > 0 }.map(\.name).joined(separator: ", ")
                    : shift.recipientNames
                return [shift.day.rawValue, Day(shift.created).rawValue, jobName(shift.jobID), Money.text(shift.cash + shift.pool),
                        Money.text(shift.card), Money.text(shift.tipOut), names.isEmpty ? "—" : names]
            })
        return [
            try csv(rows, year: year, directory: folder, jobName: jobName),
            try write(daily, as: "Tipsheet-\(year)-daily-tips.pdf", in: folder),
            try write(annual, as: "Tipsheet-\(year)-annual-summary.pdf", in: folder)
        ]
    }

    private static func pdf(title: String, subtitle: String, headers: [String], widths: [CGFloat], rows: [[String]]) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let ink = UIColor(red: 0.09, green: 0.10, blue: 0.10, alpha: 1)
        let moss = UIColor(red: 0.12, green: 0.36, blue: 0.29, alpha: 1)
        let normal: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: ink]
        let strong: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: moss]

        return renderer.pdfData { context in
            var y: CGFloat = 0
            var page = 0

            func drawRow(_ values: [String], attributes: [NSAttributedString.Key: Any], height: CGFloat) {
                var x: CGFloat = 44
                for (value, width) in zip(values, widths) {
                    let rect = CGRect(x: x + 3, y: y + 3, width: width - 6, height: height - 4)
                    (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
                    x += width
                }
                y += height
                context.cgContext.setStrokeColor(UIColor(white: 0.87, alpha: 1).cgColor)
                context.cgContext.setLineWidth(0.5)
                context.cgContext.move(to: CGPoint(x: 44, y: y))
                context.cgContext.addLine(to: CGPoint(x: x, y: y))
                context.cgContext.strokePath()
            }

            func startPage() {
                context.beginPage()
                page += 1
                ("Tipsheet" as NSString).draw(at: CGPoint(x: 44, y: 35), withAttributes: strong)
                (title as NSString).draw(at: CGPoint(x: 44, y: 51), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: ink])
                (subtitle as NSString).draw(at: CGPoint(x: 44, y: 88), withAttributes: normal)
                (L.t("Records you can give your tax preparer.") as NSString).draw(at: CGPoint(x: 44, y: 743), withAttributes: normal)
                ("\(page)" as NSString).draw(at: CGPoint(x: 539, y: 743), withAttributes: strong)
                y = 115
                drawRow(headers, attributes: strong, height: 30)
            }

            startPage()
            for row in rows {
                let height = max(21, zip(row, widths).map { value, width in
                    ceil((value as NSString).boundingRect(with: CGSize(width: width - 6, height: .greatestFiniteMagnitude),
                        options: .usesLineFragmentOrigin, attributes: normal, context: nil).height) + 6
                }.max() ?? 21)
                if y + height > 720 { startPage() }
                drawRow(row, attributes: normal, height: height)
            }
        }
    }
}

struct TaxView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Int?

    private var currentYear: Int { Calendar.tipsheet.component(.year, from: model.now) }
    private var years: [Int] {
        Set(model.earned.compactMap { Int($0.shift.day.rawValue.prefix(4)) } + [currentYear]).sorted(by: >)
    }

    var body: some View {
        let year = selection ?? currentYear
        let rows = model.earned.filter { Int($0.shift.day.rawValue.prefix(4)) == year }
        let totals = Totals(rows)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Picker(L.t("Year"), selection: Binding(get: { year }, set: { selection = $0 })) {
                        ForEach(years, id: \.self) { item in Text(String(item)).tag(item) }
                    }
                    .pickerStyle(.menu)
                    VStack(spacing: 12) {
                        LabelValue(label: L.t("Cash tips"), value: model.display(totals.cash))
                        LabelValue(label: L.t("Card tips"), value: model.display(totals.card))
                        LabelValue(label: L.t("Tip pool received"), value: model.display(totals.pool))
                        LabelValue(label: L.t("Tip out"), value: model.display(totals.tipOut))
                        LabelValue(label: L.t("Net tips"), value: model.display(totals.net))
                        LabelValue(label: L.t("Wages"), value: model.display(totals.wages))
                        LabelValue(label: L.t("Hours"), value: Display.hours(totals.minutes))
                        Divider()
                        LabelValue(label: L.t("Tips reported to employer"), value: model.display(totals.reported))
                        LabelValue(label: L.t("Unreported difference"), value: model.display(totals.net - totals.reported))
                    }
                    .padding(16).ledgerCard()
                    Button {
                        do { model.pendingFiles = try ExportFiles.tax(rows, year: year, jobName: { model.job($0).title }) }
                        catch { model.notice = L.t("Could not prepare the export.") }
                    } label: {
                        Label(L.t("Export CSV and PDFs"), systemImage: "square.and.arrow.up")
                            .fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 39)
                    }
                    .disabled(rows.isEmpty).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("exportTax")
                    Text(L.t("Records you can give your tax preparer.")).font(.footnote).foregroundStyle(Palette.subdued)
                }
                .padding(20)
            }
            .ledgerCanvas().navigationTitle(L.t("Tax report")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { CloseButton() } }
            .accessibilityIdentifier("taxScreen")
        }
    }
}
