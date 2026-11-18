import SwiftUI
import UserNotifications

/// Minutniki z kroków przepisu. Każdy minutnik ma też lokalne powiadomienie z dźwiękiem,
/// więc zadzwoni nawet przy zablokowanym ekranie albo gdy aplikacja jest w tle.
@MainActor
@Observable
final class CookingTimers {
    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let recipeTitle: String
        let end: Date
    }

    static let shared = CookingTimers()

    private(set) var items: [Item] = []

    private let notificationDelegate = NotificationDelegate()

    private init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    func start(step: Step, recipeTitle: String) {
        let label = step.text.count > 60 ? String(step.text.prefix(60)) + "…" : step.text
        let item = Item(label: label, recipeTitle: recipeTitle, end: Date().addingTimeInterval(step.minutes * 60))
        items.append(item)

        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = "⏰ \(recipeTitle)"
            content.body = L.t("timer.body", ["label": label])
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, step.minutes * 60), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: trigger))
        }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
    }

}

/// Pokazuje powiadomienie minutnika także wtedy, gdy aplikacja jest na ekranie.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Pasek z działającymi minutnikami.
struct TimersBar: View {
    private var timers = CookingTimers.shared

    var body: some View {
        if !timers.items.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 6) {
                    ForEach(timers.items) { item in
                        let left = item.end.timeIntervalSince(context.date)
                        HStack(spacing: 10) {
                            Text(left > 0 ? Kitchen.clock(left) : L.t("timer.done"))
                                .font(.title3.monospacedDigit().bold())
                            Text(item.label)
                                .font(.subheadline)
                                .lineLimit(1)
                                .opacity(0.85)
                            Spacer(minLength: 0)
                            Button {
                                timers.remove(item)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel(L.t("timer.remove"))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(left > 0 ? Color(.systemBackground) : .white)
                        .background(left > 0 ? Color.primary : Color.brand, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }
        }
    }
}
