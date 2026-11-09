import EventKit
import PulseEngine
import SwiftUI

struct ConnectionsScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            Section("Apple Calendar") {
                NavigationLink("Calendar events") { CalendarConnectionScreen(mode: .events) }
                NavigationLink("Publish a time block") { CalendarConnectionScreen(mode: .publish) }
            }
            Section {
                NavigationLink("Import reminders") { CalendarConnectionScreen(mode: .reminders) }
                NavigationLink("Screen Time") { ScreenTimeScreen() }
                NavigationLink("Sleep and activity") { HealthConnectionScreen() }
                NavigationLink("Health and energy") { HealthEnergyScreen() }
                Button("System permissions") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            }
            Section {
                NavigationLink("OneRep") { OneRepScreen() }
                if store.journal.connections?.oneRep == true {
                    Button("Turn off OneRep", role: .destructive) {
                        do { if store.canSync { try OneRepCredentials.delete() } }
                        catch { store.notice = error.localizedDescription; return }
                        PrivacySession.preferences.removeObject(forKey: "readOneRepHealth")
                        store.change { journal in journal.connections?.oneRep = false }
                    }
                }
            } footer: {
                Text("Log a workout, ask OneRep’s coach or read the health stats you choose to share.")
            }
        }
        .formPaper().navigationTitle("Connections")
        .disabled(store.isDemo || PrivacySession.connectionsLocked)

    }
}

private enum CalendarMode {
    case events, reminders, publish
    var kind: EKEntityType { self == .reminders ? .reminder : .event }
    var title: String {
        switch self {
        case .events: "Calendar events"
        case .reminders: "Import reminders"
        case .publish: "Publish block"
        }
    }
}

private struct CalendarConnectionScreen: View {
    let mode: CalendarMode
    @Environment(Workspace.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var bridge = CalendarBridge()
    @State private var calendars: [EKCalendar] = []
    @State private var calendarID = ""
    @State private var events: [CalendarCandidate] = []
    @State private var reminders: [ReminderCandidate] = []
    @State private var selected = Set<UUID>()
    @State private var status = EKAuthorizationStatus.notDetermined
    @State private var busy = false
    @State private var reviewed = false
    @State private var message: String?
    @State private var publication: Block?
    @State private var conflicts: [String] = []
    var body: some View {
        Form {
            if mode == .events, store.liveCalendar.source != nil, status != .fullAccess || !calendars.contains(where: { $0.calendarIdentifier == store.liveCalendar.source }) {
                Button("Disconnect calendar") { store.liveCalendar.source = nil }
            }
            if mode == .reminders, !store.liveReminders.sources.isEmpty {
                let unavailable = store.liveReminders.sources.subtracting(calendars.map(\.calendarIdentifier))
                if status != .fullAccess {
                    Button("Stop automatic imports") { store.liveReminders.sources = [] }
                } else if !unavailable.isEmpty {
                    Button("Disconnect unavailable lists") { store.liveReminders.sources.subtract(unavailable) }
                }
            }
            if status != .fullAccess {
                Section {
                    if status == .denied || status == .restricted {
                        Button("Open iPhone Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    } else {
                        Button("Allow access") { Task { await authorize() } }.disabled(busy)
                    }
                } footer: {
                    Text(
                        mode == .reminders
                            ? "Choose individual reminders or turn on automatic imports for a list."
                            : "Select a calendar to review its events. Publishing always requires a separate confirmation."
                    )
                }
            } else if calendars.isEmpty {
                Text("No available calendars or lists.")
            } else {
                Picker(mode == .reminders ? "List" : "Calendar", selection: $calendarID) {
                    ForEach(calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                }
                if mode == .reminders {
                    Section {
                        Toggle("Automatically import this list", isOn: Binding(
                            get: { store.liveReminders.sources.contains(calendarID) },
                            set: { enabled in
                                if enabled { store.liveReminders.sources.insert(calendarID) }
                                else { store.liveReminders.sources.remove(calendarID) }
                            }
                        ))
                    } footer: {
                        Text("Dated reminders enter Plan. Undated reminders wait in Inbox. Edits you make in Pulse are kept.")
                    }
                }
                if mode == .events {
                    Section {
                        Toggle("Keep in Plan", isOn: Binding(
                            get: { store.liveCalendar.source == calendarID },
                            set: { enabled in store.liveCalendar.source = enabled ? calendarID : nil }
                        ))
                    } footer: {
                        Text("Keep the next 14 days of busy times up to date on this device.")
                    }
                }
                if mode == .publish {
                    Section("Planned blocks") {
                        let work = store.blocks.filter { if case .task = $0.kind { true } else { false } }
                        if work.isEmpty { Text("No work blocks to publish today.") }
                        ForEach(work) { block in
                            Button {
                                do {
                                    conflicts = try bridge.conflicts(for: block, calendarID: calendarID)
                                    publication = block
                                } catch { message = error.localizedDescription }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(block.title)
                                    Text(
                                        block.start.formatted(date: .abbreviated, time: .shortened)
                                            + " · \(block.minutes) min"
                                    ).font(.caption)
                                }
                            }
                        }
                    }
                } else {
                    Button(busy ? "Loading…" : "Review \(mode == .events ? "next 14 days" : "open reminders")") {
                        Task { await review() }
                    }.disabled(busy)
                    if reviewed {
                        if events.isEmpty && reminders.isEmpty { Text("No matching items.") }
                        ForEach(events) { event in
                            Button {
                                toggle(event.id)
                            } label: {
                                HStack {
                                    selectionMark(event.id)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.title)
                                        Text(
                                            event.start.formatted(date: .abbreviated, time: .shortened) + " to "
                                                + event.end.formatted(date: .abbreviated, time: .shortened)
                                        ).font(.caption)
                                        if event.matchingCopy(in: store.journal.events) != nil {
                                            Text("Updates imported event").font(.caption)
                                        }
                                        if overlaps(event) {
                                            Label("Overlapping commitment", systemImage: "clock.badge.exclamationmark")
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        let importedIDs = importedReminderIDs
                        ForEach(reminders, id: \.itemID) { reminder in
                            let imported = importedIDs.contains(reminder.itemID)
                            Button {
                                toggle(reminder.selectionID)
                            } label: {
                                HStack {
                                    selectionMark(reminder.selectionID)
                                    VStack(alignment: .leading) {
                                        Text(reminder.title)
                                        if imported {
                                            Text("Already imported").font(.caption)
                                        } else if let due = reminder.due {
                                            Text(due.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                        }
                                    }
                                }
                            }.disabled(imported)
                        }
                        if !selected.isEmpty { Button("Import selected (\(selected.count))") { commit() } }
                    }
                }
            }
        }.formPaper().navigationTitle(mode.title).disabled(store.isDemo || PrivacySession.connectionsLocked)
            .onAppear { refreshAccess() }.onChange(of: phase) { if phase == .active { refreshAccess() } }
            .onChange(of: calendarID) {
                reviewed = false
                selected = []
                events = []
                reminders = []
            }
            .confirmationDialog(
                "Publish this block?",
                isPresented: Binding(get: { publication != nil }, set: { if !$0 { publication = nil } }),
                titleVisibility: .visible, presenting: publication
            ) { block in
                Button("Save to Apple Calendar") {
                    guard !store.isDemo, !PrivacySession.connectionsLocked,
                        case .task(let id) = block.kind, store.blocks.contains(block)
                    else {
                        message = ConnectionError.invalidBlock.localizedDescription
                        return
                    }
                    let key = CalendarBridge.publicationKey(id, on: block.start)
                    do {
                        guard try bridge.conflicts(for: block, calendarID: calendarID) == conflicts else {
                            message = "Your calendar changed. Select the block to review its overlaps again."
                            return
                        }
                        let identifier = try bridge.publish(
                            block, calendarID: calendarID, priorID: store.journal.connections?.published[key])
                        store.change { j in
                            var state = j.connections ?? ConnectionState()
                            state.published[key] = identifier
                            j.connections = state
                        }
                        message = "Block saved to Calendar."
                    } catch { message = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { block in
                Text(
                    block.title + " · " + block.start.formatted(date: .abbreviated, time: .shortened)
                        + (conflicts.isEmpty ? "" : "\nAlso scheduled: " + conflicts.joined(separator: ", ")))
            }
            .alert("Calendar", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("Close") {}
            } message: {
                Text(message ?? "")
            }
    }
    private func selectionMark(_ id: UUID) -> some View {
        Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle").accessibilityLabel(
            selected.contains(id) ? "Selected" : "Unselected")
    }
    private func toggle(_ id: UUID) { if !selected.insert(id).inserted { selected.remove(id) } }
    private func overlaps(_ event: CalendarCandidate) -> Bool {
        store.journal.events.contains { event.overlaps($0) }
            || events.contains { other in
                other.id != event.id && selected.contains(other.id) && other.start < event.end
                    && event.start < other.end
            }
    }
    private var importedReminderIDs: Set<String> {
        let receipts = store.journal.reminderImports ?? [:]
        let ids = Set(store.journal.tasks.map(\.id))
        var items = Set(receipts.compactMap { ids.contains($0.key) ? $0.value.itemID : nil })
        for reminder in reminders where receipts[reminder.id] == nil && ids.contains(reminder.id) {
            items.insert(reminder.itemID)
        }
        return items
    }

    private func refreshAccess() {
        status = EKEventStore.authorizationStatus(for: mode.kind)
        guard status == .fullAccess else {
            calendars = []
            reviewed = false
            return
        }
        calendars = bridge.store.calendars(for: mode.kind).filter { mode != .publish || $0.allowsContentModifications }
        if !calendars.contains(where: { $0.calendarIdentifier == calendarID }) {
            calendarID = calendars.first(where: { mode == .events && $0.calendarIdentifier == store.liveCalendar.source })?.calendarIdentifier
                ?? calendars.first?.calendarIdentifier ?? ""
        }
    }
    private func authorize() async {
        guard !store.isDemo, !PrivacySession.connectionsLocked else { return }
        busy = true
        defer {
            busy = false
            refreshAccess()
        }
        do { try await bridge.request(mode.kind) } catch { message = error.localizedDescription }
    }
    private func review() async {
        let id = calendarID
        busy = true
        defer { busy = false }
        do {
            if mode == .events {
                events = try bridge.events(calendarID: id, from: .now)
            } else {
                let loaded = try await bridge.reminders(calendarID: id)
                guard id == calendarID else { return }
                reminders = loaded
            }
            selected = []
            reviewed = true
        } catch { message = error.localizedDescription }
    }
    private func commit() {
        guard !store.isDemo, !PrivacySession.connectionsLocked,
            EKEventStore.authorizationStatus(for: mode.kind) == .fullAccess
        else {
            refreshAccess()
            return
        }
        store.change { j in
            for e in events where selected.contains(e.id) {
                let model = e.commitment
                let existing = e.matchingCopy(in: j.events)
                if let i = j.events.firstIndex(where: { $0.id == existing }) {
                    j.events[i] = model
                } else {
                    j.events.append(model)
                }
            }
            j.importReminders(reminders.filter { selected.contains($0.selectionID) }, manual: true)
            j.starterAvailable = false
        }
        if mode == .events, store.liveCalendar.source == calendarID {
            store.liveCalendar.snapshotIDs.formUnion(selected)
        }
        selected = []
        message = "Selected items saved to Pulse."
    }
}

private struct HealthConnectionScreen: View {
    @Environment(Workspace.self) private var store
    @State private var sleep = false
    @State private var activity = false
    @State private var busy = false
    @State private var days: [HealthDay] = []
    @State private var selectedDate = Date.now
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Toggle("Sleep duration", isOn: $sleep)
                Toggle("Steps", isOn: $activity)
                Button(busy ? "Reading…" : "Review this week") { Task { await load() } }.disabled(
                    busy || (!sleep && !activity))
            } footer: {
                Text("Reads the selected measures from Health for this screen. Values disappear when you leave.")
            }
            if let day = days.first(where: { $0.date == selectedDate }) {
                Section {
                    Picker("Day", selection: $selectedDate) {
                        ForEach(days) { item in
                            Text(item.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                                .tag(item.date)
                        }
                    }
                    if sleep {
                        LabeledContent("Sleep", value: day.sleepHours.map {
                            $0.formatted(.number.precision(.fractionLength(1))) + " h"
                        } ?? "No reading")
                    }
                    if activity { LabeledContent("Steps", value: day.steps?.formatted() ?? "No reading") }
                }
                Section("Check-ins") {
                    let reports = day.checkIns(in: store.journal.reports)
                    if reports.isEmpty { Text("No check-ins this day.").foregroundStyle(.secondary) }
                    ForEach(reports) { report in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(report.date.formatted(date: .omitted, time: .shortened),
                                value: "Energy " + report.energy.formatted(.number.precision(.fractionLength(0...1))) + " / 10")
                            if report.feltWorseAfterActivity == true {
                                Text("Felt worse after activity").font(.subheadline)
                            }
                            if let note = report.fatigueNote, !note.isEmpty {
                                Text(note).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
            if let message { Text(message) }
        }.formPaper().navigationTitle("Health").disabled(store.isDemo || PrivacySession.connectionsLocked)
            .onChange(of: sleep) { days = [] }.onChange(of: activity) { days = [] }
    }
    private func load() async {
        guard !store.isDemo, !PrivacySession.connectionsLocked else { return }
        let requestedSleep = sleep
        let requestedActivity = activity
        busy = true
        defer { busy = false }
        do {
            let result = try await HealthBridge.week(sleep: sleep, activity: activity)
            if sleep == requestedSleep && activity == requestedActivity {
                if !result.contains(where: { $0.date == selectedDate }), let first = result.first { selectedDate = first.date }
                days = result
                message = nil
            }
        } catch { message = error.localizedDescription }
    }
}
