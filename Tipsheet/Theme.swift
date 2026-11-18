import SwiftUI
import UIKit

enum Palette {
    static let background = adaptive(0xF6F4EF, 0x121311)
    static let card = adaptive(0xFFFFFF, 0x1C1D1B)
    static let ink = adaptive(0x16181A, 0xF1F0EC)
    static let subdued = adaptive(0x6E6F6B, 0xA6A7A0)
    static let line = adaptive(0xE7E4DC, 0x353632)
    static let bar = adaptive(0xD9D6CD, 0x42443D)
    static let accent = adaptive(0x1E5B4B, 0x6FB79F)
    static let soft = adaptive(0xE3ECE8, 0x22302B)
    static let onAccent = adaptive(0xFFFFFF, 0x0E1A16)

    static let jobs = [accent, adaptive(0xA2783C, 0xC9A46A), adaptive(0x675C83, 0xA69ABF),
                       adaptive(0x456879, 0x8AB4C7), adaptive(0x845C59, 0xC68F8B)]

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func ledgerCard(_ radius: CGFloat = 18) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius))
    }

    func ledgerCanvas() -> some View {
        foregroundStyle(Palette.ink)
            .background(Palette.background.ignoresSafeArea())
            .tint(Palette.accent)
    }

    func ledgerNumber() -> some View { monospacedDigit() }
}

enum Display {
    static func day(_ day: Day, style: Date.FormatStyle = .dateTime.weekday(.abbreviated).month(.abbreviated).day()) -> String {
        var displayStyle = style
        displayStyle.calendar = .tipsheet
        displayStyle.timeZone = Calendar.tipsheet.timeZone
        return day.date()?.formatted(displayStyle) ?? day.rawValue
    }

    static func range(_ range: DayRange) -> String {
        let end = range.end.adding(-1)
        if range.start == end { return day(end, style: .dateTime.month(.abbreviated).day()) }
        let first = range.start.date() ?? Date()
        let last = end.date() ?? first
        let differentYear = Calendar.tipsheet.component(.year, from: first) != Calendar.tipsheet.component(.year, from: last)
        let formatter = DateIntervalFormatter()
        formatter.calendar = .tipsheet
        formatter.timeZone = Calendar.tipsheet.timeZone
        formatter.dateTemplate = differentYear ? "yMMMd" : "MMMd"
        return formatter.string(from: first, to: last)
    }

    static func clock(_ minute: Int) -> Date {
        let calendar = Calendar.tipsheet
        let day = calendar.date(from: DateComponents(year: 2000, month: 1, day: 15)) ?? Date()
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
    }

    static func minute(_ date: Date) -> Int {
        let parts = Calendar.tipsheet.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func hours(_ minutes: Int) -> String {
        (Double(minutes) / 60).formatted(.number.precision(.fractionLength(0...2)))
    }
}

struct JobDot: View {
    let job: Job
    var body: some View {
        Circle().fill(Palette.jobs[job.color]).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

struct CloseButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button(L.t("Done")) { dismiss() } }
}
