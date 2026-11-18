import AppIntents
import Foundation

enum WidgetBridge {
    static let group = "group.com.hgsldswk.tipsheet"
    static let logURL = URL(string: "tipsheet://log")!
    static let logRequest = Notification.Name("tipsheet.open-log")
    private static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    struct Snapshot: Codable {
        var total: String
        var hourly: String
        var bars: [Double]
        var currentDay: Int
        var periodEnd: Date
        var proUntil: Date?
        var unlimited: Bool
        var hidden: Bool
    }

    static func save(_ snapshot: Snapshot) {
        defaults?.set(try? JSONEncoder().encode(snapshot), forKey: "widget.snapshot")
    }

    static func read() -> Snapshot? {
        guard let data = defaults?.data(forKey: "widget.snapshot") else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func requestLog() {
        defaults?.set(true, forKey: "widget.open-log")
        NotificationCenter.default.post(name: logRequest, object: nil)
    }

    static func consumeLog() -> Bool {
        guard defaults?.bool(forKey: "widget.open-log") == true else { return false }
        defaults?.removeObject(forKey: "widget.open-log")
        return true
    }
}

@available(iOS 18.0, *)
enum TipsheetDestination: String, AppEnum {
    case log
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tipsheet")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.log: "Log shift"]
}

@available(iOS 18.0, *)
struct OpenTipsheetLog: OpenIntent {
    static let title: LocalizedStringResource = "Log shift"
    static let openAppWhenRun = true

    @Parameter(title: "Destination") var target: TipsheetDestination

    init() {}
    init(_ destination: TipsheetDestination) { target = destination }

    @MainActor func perform() async throws -> some IntentResult {
        WidgetBridge.requestLog()
        return .result()
    }
}
