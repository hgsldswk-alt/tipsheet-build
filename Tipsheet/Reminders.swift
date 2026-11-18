import UIKit
import UserNotifications

@MainActor
enum Reminders {
    private static let id = "shift.end"

    static func authorize() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func schedule(endMinute: Int, after now: Date, until expiry: Date?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let time = DateComponents(hour: endMinute / 60, minute: endMinute % 60)
        guard let next = Calendar.tipsheet.nextDate(after: now, matching: time, matchingPolicy: .nextTime),
              expiry.map({ next < $0 }) ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = L.t("Log tonight’s tips?")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.tipsheet.dateComponents([.year, .month, .day, .hour, .minute], from: next),
                                                    repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel() async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { WidgetBridge.requestLog() }
    }
}
