import Foundation

enum ExchangeError: Error {
    case invalidFile, noRows, invalidRow(Int)
}

struct JobSetup: Codable {
    var version = 1
    var name: String
    var color: Int
    var hourly: Int
    var overtime: Overtime
    var rules: [TipRule]
    static let prefix = "TIP1-"

    init(job: Job) {
        name = job.name
        color = job.color
        hourly = job.hourly
        overtime = job.overtime
        rules = job.rules
    }

    func job() -> Job { Job(name: name, color: color, hourly: hourly, overtime: overtime, rules: rules) }

    func code() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func parse(_ input: String) -> JobSetup? {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count < 20_000, code.hasPrefix(prefix) else { return nil }
        var base64 = String(code.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let setup = try? JSONDecoder().decode(Self.self, from: data),
              setup.version == 1, setup.job().isValid else { return nil }
        return setup
    }
}

struct CSVShift {
    var day: Day
    var job: String
    var time: WorkTime
    var card: Int
    var cash: Int
    var pool: Int
    var tipOut: Int
    var hourly: Int
    var sales: Int
    var covers: Int
    var reported: Int?
    var recipients: String
    var notes: String
    var tags: [String]

    func makeShift(jobID: UUID, now: Date) -> Shift {
        Shift(updated: now, created: now, day: day, jobID: jobID, time: time, hourly: hourly,
              card: card, cash: cash, pool: pool, sales: sales, covers: covers, manualTipOut: tipOut,
              recipientNames: recipients, reported: reported, notes: notes, tags: tags)
    }
}

enum ShiftCSV {
    private static let headings = ["Date", "Job", "Hours", "Cash Tips", "Card Tips", "Tip Pool", "Tip Out",
                                   "Gross Tips", "Net Tips", "Wages", "Total", "Hourly", "Base Rate", "Start",
                                   "End", "Break Minutes", "Sales", "Covers", "Reported Tips", "Recipients", "Notes", "Tags"]

    static func export(_ rows: [EarnedShift], jobName: (UUID) -> String) -> String {
        let lines = rows.map { row -> [String] in
            let shift = row.shift
            return [shift.day.rawValue, safeText(jobName(shift.jobID)), hours(shift.time.minutes),
                    Money.decimal(shift.cash), Money.decimal(shift.card), Money.decimal(shift.pool), Money.decimal(shift.tipOut),
                    Money.decimal(shift.gross), Money.decimal(shift.net), Money.decimal(row.wages), Money.decimal(row.total),
                    row.hourly.map(Money.decimal) ?? "", Money.decimal(shift.hourly), clock(shift.time.start),
                    clock(shift.time.end), String(shift.time.breakMinutes), Money.decimal(shift.sales), String(shift.covers),
                    shift.reported.map(Money.decimal) ?? "", safeText(shift.recipientNames), safeText(shift.notes),
                    safeText(shift.tags.joined(separator: ", "))]
        }
        return ([headings] + lines).map { $0.map(quoted).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func parse(_ source: String) throws -> [CSVShift] {
        let rows = try table(source)
        guard let header = rows.first else { throw ExchangeError.noRows }
        let columns = header.map(normalized)
        guard let dateIndex = columns.firstIndex(where: { ["date", "shiftdate", "day", "workdate"].contains($0) }) else {
            throw ExchangeError.invalidFile
        }
        let results = try rows.dropFirst().enumerated().map { offset, row in
            func value(_ aliases: String...) -> String {
                guard let index = columns.firstIndex(where: aliases.contains), row.indices.contains(index) else { return "" }
                let text = row[index]
                return text.first == "'" && isFormula(String(text.drop(while: { $0 == "'" }))) ? String(text.dropFirst()) : text
            }
            func amount(_ text: String) throws -> Int {
                let match = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
                guard let amount = Money.cents(match, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw ExchangeError.invalidRow(offset + 2)
                }
                return amount
            }
            let rawHours = value("hours", "hour", "hoursworked", "workedhours", "duration").trimmingCharacters(in: .whitespaces)
            let rawStart = value("start", "starttime")
            let rawEnd = value("end", "endtime")
            let rawBreak = value("breakminutes", "break")
            var time = WorkTime()
            if !rawStart.isEmpty || !rawEnd.isEmpty {
                guard let start = minutes(rawStart), let end = minutes(rawEnd),
                      let breakTime = Int(rawBreak.isEmpty ? "0" : rawBreak) else { throw ExchangeError.invalidRow(offset + 2) }
                time = WorkTime(start: start, end: end, breakMinutes: breakTime)
            } else if !rawHours.isEmpty {
                guard let hours = Double(rawHours), hours >= 0, hours < 24 else { throw ExchangeError.invalidRow(offset + 2) }
                let work = Int((hours * 60).rounded())
                time = WorkTime(start: 17 * 60, end: (17 * 60 + work) % 1440)
                guard work < 1440 else { throw ExchangeError.invalidRow(offset + 2) }
            } else {
                time = WorkTime(start: 0, end: 0)
            }
            guard row.indices.contains(dateIndex), let day = date(row[dateIndex]), time.isValid else {
                throw ExchangeError.invalidRow(offset + 2)
            }
            let rawReported = value("reportedtips", "reportedtoemployer")
            let rawCovers = value("covers", "deliveries")
            guard let covers = Int(rawCovers.isEmpty ? "0" : rawCovers) else { throw ExchangeError.invalidRow(offset + 2) }
            let shift = try CSVShift(
                day: day, job: value("job", "jobname", "workplace", "employer").trimmingCharacters(in: .whitespacesAndNewlines),
                time: time, card: amount(value("cardtips", "credittips", "creditcardtips", "card", "creditcard", "chargedtips")),
                cash: amount(value("cashtips", "cash", "directtips")), pool: amount(value("tippool", "pool")),
                tipOut: amount(value("tipout", "tipouts", "tipspaidout", "tipoutamount").trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
                hourly: amount(value("baserate", "basehourly", "wagerate", "hourlywage")), sales: amount(value("sales", "totalsales")),
                covers: covers, reported: rawReported.isEmpty ? nil : amount(rawReported),
                recipients: value("recipients", "tipoutrecipients"), notes: value("notes", "note"),
                tags: value("tags").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            guard shift.job.count <= 80, shift.makeShift(jobID: Job.defaultID, now: Date()).isValid else {
                throw ExchangeError.invalidRow(offset + 2)
            }
            return shift
        }
        guard !results.isEmpty else { throw ExchangeError.noRows }
        return results
    }

    private static func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static func date(_ input: String) -> Day? {
        let string = input.trimmingCharacters(in: .whitespaces)
        let iso = Day(rawValue: String(string.prefix(10)))
        if iso.date() != nil && (string.count == 10 || string.dropFirst(10).first == "T" || string.dropFirst(10).first == " ") {
            return iso
        }
        let chunks = string.split(separator: "/").compactMap { Int($0) }
        guard chunks.count == 3, (1900...9999).contains(chunks[2]), (1...12).contains(chunks[0]), (1...31).contains(chunks[1]) else { return nil }
        let day = Day(rawValue: String(format: "%04d-%02d-%02d", chunks[2], chunks[0], chunks[1]))
        return day.date() == nil ? nil : day
    }

    private static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    private static func hours(_ minutes: Int) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(minutes) / 60)
    }

    private static func minutes(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func isFormula(_ value: String) -> Bool {
        guard let first = value.drop(while: { $0.isWhitespace }).first else { return false }
        return "=+-@".contains(first)
    }

    private static func safeText(_ value: String) -> String {
        isFormula(String(value.drop(while: { $0 == "'" }))) ? "'" + value : value
    }

    private static func table(_ source: String) throws -> [[String]] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.first == "\u{FEFF}" { text.removeFirst() }
        var rows: [[String]] = [], row: [String] = [], value = ""
        var inQuotes = false, afterQuote = false
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            index = text.index(after: index)
            if inQuotes {
                if char == "\"" {
                    if index < text.endIndex, text[index] == "\"" {
                        value.append(char)
                        index = text.index(after: index)
                    } else {
                        inQuotes = false
                        afterQuote = true
                    }
                } else { value.append(char) }
                continue
            }
            switch char {
            case "\"" where value.isEmpty && !afterQuote:
                inQuotes = true
            case ",", "\n":
                row.append(value)
                value = ""
                afterQuote = false
                if char == "\n" {
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                }
            default:
                guard !afterQuote, char != "\"" else { throw ExchangeError.invalidFile }
                value.append(char)
            }
        }
        guard !inQuotes else { throw ExchangeError.invalidFile }
        if !row.isEmpty || !value.isEmpty { rows.append(row + [value]) }
        return rows
    }
}
