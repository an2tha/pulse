import ActivityKit
import PulseEngine
import SwiftUI
import UserNotifications

struct ReminderPreferencesView: View {
    @Environment(Workspace.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var permission: UNAuthorizationStatus = .notDetermined
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow reminders", isOn: Binding(get: { store.systemPreferences.enabled }, set: setEnabled))
                    .disabled(busy)
                if permission == .denied {
                    Button("Open iPhone notification settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                if store.systemPreferences.enabled {
                    Toggle(
                        "Focus block finished",
                        isOn: Binding(
                            get: { store.journal.notifications },
                            set: { value in store.change { $0.notifications = value } }))
                    Toggle("Task reminders and deadlines", isOn: binding(\.taskAlerts))
                    Toggle("Morning check-in", isOn: binding(\.morningCheckIn))
                    if store.systemPreferences.morningCheckIn { clock("Check-in time", \.morningMinute) }
                    Toggle("Nudge to revisit an unused plan", isOn: binding(\.recoveryPrompt))
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(
                    "Times you set are honored outside quiet hours. Automatic reminders are spaced at least 15 minutes apart, up to six per day."
                )
            }
            if store.systemPreferences.enabled {
                Section {
                    Toggle("Quiet hours", isOn: binding(\.quietHours))
                    if store.systemPreferences.quietHours {
                        clock("From", \.quietStart)
                        clock("Until", \.quietEnd)
                    }
                } footer: {
                    Text(
                        store.systemPreferences.quietStart == store.systemPreferences.quietEnd
                            && store.systemPreferences.quietHours
                            ? "Matching times silence reminders all day."
                            : "Planning reminders wait until quiet hours end. Focus alerts stay silent during quiet hours."
                    )
                }
            }
            Section {
                Toggle("Show my plan in widgets", isOn: binding(\.widgetDetails))
                Toggle("Show live focus timer", isOn: binding(\.liveTimer))
                Toggle("Show task names in alerts and timers", isOn: binding(\.showTitles))
            } header: {
                Text("Home and Lock Screens")
            } footer: {
                Text(
                    "Widgets can show your task titles when enabled. Live timers use “Focus” unless you choose to show task names."
                )
            }
        }
        .formPaper().navigationTitle("Reminders & widgets").navigationBarTitleDisplayMode(.inline)
        .disabled(store.isDemo)
        .task(id: phase) {
            guard phase == .active, !store.isDemo else { return }
            permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }
    private func setEnabled(_ value: Bool) {
        guard !store.isDemo else { return }
        if !value {
            edit { $0.enabled = false }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let allowed = try await FocusReminder.authorize()
                permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                if allowed {
                    edit { $0.enabled = true }
                } else {
                    store.notice = "Enable notifications for Pulse in iPhone Settings to receive reminders."
                }
            } catch { store.notice = "Notification permission couldn’t be checked. Try again." }
        }
    }
    private func edit(_ change: (inout ReminderPreferences) -> Void) {
        var prefs = store.systemPreferences
        change(&prefs)
        store.change { $0.reminderPreferences = prefs }
    }
    private func binding<T>(_ key: WritableKeyPath<ReminderPreferences, T>) -> Binding<T> {
        Binding(get: { store.systemPreferences[keyPath: key] }, set: { value in edit { $0[keyPath: key] = value } })
    }
    private func clock(_ title: String, _ key: WritableKeyPath<ReminderPreferences, Int>) -> some View {
        DatePicker(
            title,
            selection: Binding(
                get: {
                    let minute = max(0, min(1439, store.systemPreferences[keyPath: key]))
                    return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now)
                        ?? .now
                },
                set: { date in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                    edit { $0[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
                }), displayedComponents: .hourAndMinute)
    }
}
