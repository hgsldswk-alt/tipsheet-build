import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum StoreLinks {
    static let support = URL(string: "https://hgsldswk-alt.github.io/tipsheet-support/")!
    static let appStore: URL = {
        let id = (Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? "")
        if !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }),
           let link = URL(string: "https://apps.apple.com/app/id" + id) { return link }
        return URL(string: "https://appstore.com/tipsheetservertiptracker")!
    }()

    static func setup(_ code: String) -> URL {
        var components = URLComponents(url: support, resolvingAgainstBaseURL: false)!
        components.fragment = code
        return components.url!
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private enum SharingPrivacy: String, CaseIterable, Identifiable {
    case hourly, growth, full
    var id: Self { self }
    var title: String {
        switch self {
        case .hourly: L.t("Hourly only")
        case .growth: L.t("Growth only")
        case .full: L.t("Total and hourly")
        }
    }
}

struct CardContent {
    var title: String
    var value: String
    var detail: String
    var lines: [String] = []
    var hashtag: String = "#Tipsheet #ShiftEarnings"
}

struct SharingView: View {
    enum Kind {
        case week, milestones, receipt(Shift)
    }

    @EnvironmentObject private var model: AppModel
    @State private var privacy = SharingPrivacy.hourly
    @State private var milestone = 0
    @State private var shareImage: UIImage?
    let kind: Kind

    private var title: String {
        switch kind {
        case .week: L.t("Share your week")
        case .milestones: L.t("Milestones")
        case .receipt: L.t("Tip-out receipt")
        }
    }
    private var isReceipt: Bool { if case .receipt = kind { true } else { false } }
    private var isMilestone: Bool { if case .milestones = kind { true } else { false } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isMilestone && milestones.isEmpty {
                        Text(L.t("Your milestones will appear here as you log shifts.")).foregroundStyle(Palette.subdued)
                    } else {
                        if isMilestone { milestonePicker }
                        if !isReceipt {
                            Picker(L.t("Card privacy"), selection: $privacy) {
                                ForEach(SharingPrivacy.allCases) { option in Text(option.title).tag(option) }
                            }
                            .pickerStyle(.menu)
                        }
                        if let card = content {
                            ViewThatFits(in: .horizontal) {
                                ShareCard(content: card).frame(width: 296)
                                ShareCard(content: card)
                            }
                            .accessibilityIdentifier("shareCardPreview")
                            Button {
                                let renderer = ImageRenderer(content: ShareCard(content: card).frame(width: 360)
                                    .environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .large))
                                renderer.scale = 3
                                shareImage = renderer.uiImage
                            } label: {
                                Label(L.t("Share image"), systemImage: "square.and.arrow.up")
                                    .fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("shareCardButton")
                        }
                    }
                }
                .padding(20)
            }
            .ledgerCanvas().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { CloseButton() } }
            .sheet(isPresented: Binding(get: { shareImage != nil }, set: { if !$0 { shareImage = nil } })) {
                if let shareImage, let card = content { ActivitySheet(items: [shareImage, card.hashtag, StoreLinks.appStore]) }
            }
            .accessibilityIdentifier("shareScreen")
        }
    }

    private var milestonePicker: some View {
        Picker(L.t("Milestone"), selection: $milestone) {
            ForEach(milestones.indices, id: \.self) { index in Text(milestones[index].title).tag(index) }
        }
        .pickerStyle(.menu)
    }

    private var content: CardContent? {
        switch kind {
        case .week:
            let rows = model.weekRows
            let totals = Totals(rows)
            let previous = DayRange(start: model.week.start.adding(-7), end: model.week.start)
            let prior = Totals(model.rows(in: previous, jobID: model.jobFilter)).total
            var value = model.hourly(totals.hourly)
            var detail = Display.range(model.week)
            if privacy == .full {
                value = Money.text(totals.total)
                detail += "  ·  " + model.hourly(totals.hourly)
            } else if privacy == .growth {
                if prior > 0 {
                    let difference = Double(totals.total - prior) / Double(prior)
                    value = difference.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
                    detail += "  ·  " + L.t("vs last week")
                } else {
                    value = L.f("Shifts logged: %@", rows.count.formatted())
                }
            }
            return CardContent(title: L.t("My week in tips"), value: value, detail: detail)
        case .milestones:
            guard milestones.indices.contains(milestone) else { return nil }
            let item = milestones[milestone]
            let totals = Totals(item.rows)
            let value: String
            switch privacy {
            case .full: value = Money.text(totals.total)
            case .hourly: value = model.hourly(totals.hourly)
            case .growth: value = L.f("Shifts logged: %@", item.rows.count.formatted())
            }
            return CardContent(title: item.title, value: value, detail: item.detail)
        case .receipt(let shift):
            let lines: [String]
            if shift.manualTipOut != nil {
                lines = shift.recipientNames.isEmpty ? [] : [shift.recipientNames]
            } else {
                lines = shift.payouts.filter { $0.cents > 0 }.map { L.f("%@ · %@", $0.name, Money.text($0.cents)) }
            }
            return CardContent(title: L.t("Tip-out receipt"), value: Money.text(shift.tipOut),
                               detail: L.f("%@ · %@", model.job(shift.jobID).title, Display.day(shift.day)), lines: lines,
                               hashtag: "#Tipsheet #TipOut")
        }
    }

    private struct Milestone {
        var title: String
        var detail: String
        var rows: [EarnedShift]
    }

    private var milestones: [Milestone] {
        guard let best = model.earned.max(by: { $0.total < $1.total }),
              let last = model.earned.last, let lastDate = last.shift.day.date(),
              let year = Calendar.tipsheet.dateInterval(of: .year, for: lastDate) else { return [] }
        let yearRows = model.rows(in: DayRange(start: Day(year.start), end: Day(year.end)))
        var result = [
            Milestone(title: L.t("Personal best shift"), detail: Display.day(best.shift.day), rows: [best]),
            Milestone(title: L.t("Year in shifts"), detail: lastDate.formatted(.dateTime.year()), rows: yearRows)
        ]
        if model.earned.count >= 100 {
            let rows = Array(model.earned.prefix(100))
            result.insert(Milestone(title: L.t("100 shifts logged"), detail: Display.day(rows[99].shift.day), rows: rows), at: 0)
        }
        let weeks = Dictionary(grouping: model.earned) { $0.shift.day.week(firstWeekday: model.data.preferences.firstWeekday).start }
        if let first = weeks.keys.sorted().first(where: { Totals(weeks[$0] ?? []).total >= 100_000 }), let rows = weeks[first] {
            result.insert(Milestone(title: L.t("A big week on the books"),
                                    detail: Display.range(DayRange(start: first, end: first.adding(7))), rows: rows), at: 0)
        }
        return result
    }
}

private struct ShareCard: View {
    let content: CardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Tipsheet").font(.subheadline.weight(.semibold)).tracking(0.8)
            Divider()
            Text(content.title).font(.headline)
            Text(content.value)
                .font(.system(size: 45, weight: .semibold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.5).lineLimit(2).foregroundStyle(Palette.accent)
            Text(content.detail).font(.subheadline).foregroundStyle(Palette.subdued)
            ForEach(content.lines.indices, id: \.self) { index in
                Text(content.lines[index]).font(.caption).foregroundStyle(Palette.ink)
            }
            Divider().padding(.top, 5)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("Find Tipsheet on the App Store")).font(.caption.weight(.semibold))
                    Text(content.hashtag).font(.caption2).foregroundStyle(Palette.subdued)
                }
                Spacer(minLength: 4)
                QRCode(value: StoreLinks.appStore.absoluteString, side: 64)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Palette.ink)
        .background(Palette.background)
        .overlay { Rectangle().strokeBorder(Palette.line, lineWidth: 1) }
    }
}

private struct QRCode: View {
    let value: String
    let side: CGFloat

    var body: some View {
        if let image = Self.generate(value) {
            Image(uiImage: image)
                .interpolation(.none).resizable().scaledToFit().frame(width: side, height: side)
                .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(L.t("QR code"))
        }
    }

    private static let context = CIContext()

    private static func generate(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let result = filter.outputImage, let image = context.createCGImage(result, from: result.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct CoworkerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var jobID: UUID?
    @State private var input = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ShareLink(item: StoreLinks.appStore, message: Text(L.t("I use Tipsheet to log shifts and tip out."))) {
                        Label(L.t("Share Tipsheet"), systemImage: "square.and.arrow.up")
                    }
                }
                Section {
                    Picker(L.t("Job"), selection: $jobID) {
                        ForEach(model.jobs) { job in Text(job.title).tag(Optional(job.id)) }
                    }
                    let code = JobSetup(job: model.job(jobID ?? model.defaultJob.id)).code()
                    ShareLink(item: StoreLinks.setup(code), message: Text(L.t("Open this Tipsheet link to add my job setup."))) {
                        Label(L.t("Share job setup link"), systemImage: "link")
                    }
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                    } label: { Label(copied ? L.t("Code copied") : L.t("Copy setup code"), systemImage: "document.on.document") }
                } header: {
                    Text(L.t("Share my job setup"))
                } footer: {
                    Text(L.t("Includes the job name, base wage, overtime and tip-out rules. Your shift records stay private."))
                }
                Section(L.t("Import a job setup")) {
                    TextField(L.t("Paste setup code"), text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(2...4).accessibilityIdentifier("setupCode")
                    Button(L.t("Import setup")) {
                        if model.addSetup(input) { input = "" }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .scrollContentBackground(.hidden).ledgerCanvas()
            .navigationTitle(L.t("Tell a coworker")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { CloseButton() } }
            .onAppear { jobID = model.defaultJob.id }
            .onChange(of: jobID) { _, _ in copied = false }
        }
    }
}
