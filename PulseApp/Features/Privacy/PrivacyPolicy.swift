import SwiftUI

enum ReleaseFeatures {
    // Each release can disable an optional surface through its app Info.plist.
    static let demo = Bundle.main.object(forInfoDictionaryKey: "PulseDemoEnabled") as? Bool ?? true
    static let returnAfterAbsence =
        Bundle.main.object(forInfoDictionaryKey: "PulseReturnPromptEnabled") as? Bool ?? true
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                policy(
                    "Your journal",
                    "Pulse keeps tasks, check-ins, focus history and settings on your device. Text, links and individual photos you add through the share sheet wait on this device until Pulse saves them. Shared photos are resized and their original metadata is removed. The share sheet receives only the items you select, and the journal stays in the app. Pulse has no account, advertising SDK or developer-operated analytics service."
                )
                policy(
                    "Connections",
                    "Calendar and Reminders imports and calendar writes require your permission. If you connect a calendar, Pulse reads its upcoming busy times on this device. For each Reminders list you choose, Pulse can import changes when you open the app and while it is active. The Health page reads the measurements you select on this device. HRV comparisons use your own readings. Screen Time usage appears inside Apple’s report. OneRep statistics use authorized Health samples from OneRep. Automatic plan adjustments are optional. When enabled, Pulse reads available measurements while the app is active to update your plan. Hourly energy corrections, your expected energy windows and saved day-ahead forecasts stay in your local journal and its backups. Screen Time shows usage inside Apple’s authorized report. OneRep links open its app. If you enable shared stats, Pulse reads only the workouts, water, protein and weight that OneRep wrote to Apple Health, and shows them without saving them to your journal. The optional assistant uses Apple’s on-device model when available. You review suggested edits before they enter your plan."
                )
                policy(
                    "Files and sync",
                    "You choose when to export, what to include in a CSV, and where files go. JSON backups contain your saved journal entries, including photos and their captions, in readable form. Stimulant intake, effects and lab entries stay in your local journal and its explicit JSON backups. Private sync can include activities you create, your activity ratings and time blocks. Unsent capture drafts stay on this device. Photos and their captions stay out of private sync and CSV exports. Private sync encrypts shared content before writing to the folder you choose. Keep the recovery key private. Your folder provider may retain encrypted files and earlier copies."
                )
                policy(
                    "Reminders and widgets",
                    "You can choose what appears on the Home Screen, Lock Screen and notifications in Reminders & widgets. People who can see those screens may see information you enable."
                )
                policy(
                    "Diagnostics and feedback",
                    "With your permission Pulse keeps counts from Apple’s diagnostic reports on this device. Turning diagnostics off removes Pulse’s local counts. You choose whether to share feedback or counts through the system share sheet."
                )
                policy(
                    "Your controls",
                    "You can keep all external connections off, including when setting up Pulse for a teen. Settings lets you disconnect sync, export your journal or delete local data. Delete separately saved files in their original locations. Apple permissions and device backups are managed in iPhone Settings."
                )
            }.frame(maxWidth: 600, alignment: .leading).padding(22)
        }.background(Color.paper).navigationTitle("Privacy policy").navigationBarTitleDisplayMode(.inline)
    }

    private func policy(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.headline).accessibilityAddTraits(.isHeader)
            Text(body).font(.body)
        }
    }
}
