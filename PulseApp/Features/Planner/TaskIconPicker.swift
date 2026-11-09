import PulseEngine
import SwiftUI

struct TaskIconView: View {
    let icon: TaskIcon?
    var fallback = "checklist"

    @ViewBuilder var body: some View {
        Group {
            switch icon {
            case .character(let text): Text(verbatim: text)
            case .symbol(let name): Image(systemName: UIImage(systemName: name) == nil ? fallback : name)
            case nil: Image(systemName: fallback)
            }
        }.accessibilityHidden(true)
    }
}

struct TaskIconTitle: View {
    let title: String
    let icon: TaskIcon?

    var body: some View {
        if let icon {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TaskIconView(icon: icon)
                Text(title)
            }
        } else {
            Text(title)
        }
    }
}

struct TaskTitleField: View {
    @Environment(\.dynamicTypeSize) private var type
    @Binding var task: PlanTask
    @State private var choosing = false
    var body: some View {
        HStack(spacing: 10) {
            Button { choosing = true } label: {
                TaskIconView(icon: task.icon, fallback: task.category.symbol)
                    .font(.title3).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(width: 44, height: 44)
                    .background(Color.journalInk.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil").font(.system(size: 9, weight: .semibold))
                            .padding(3).background(Color.paper, in: Circle()).accessibilityHidden(true)
                    }
            }.buttonStyle(.plain).accessibilityLabel("Change task icon")
                .accessibilityValue(TaskIconPicker.name(for: task.icon))
                .accessibilityIdentifier("task-icon-picker")
            TextField("Task name", text: $task.title, prompt: Text("Task name").foregroundStyle(Color.moss))
        }
        .sheet(isPresented: $choosing) {
            NavigationStack { TaskIconPicker(icon: $task.icon, fallback: task.category.symbol) }
                .presentationDetents(type.isAccessibilitySize ? [.large] : [.medium, .large]).presentationDragIndicator(.visible)
                .foregroundStyle(Color.journalInk).tint(.journalAccent)
        }
    }
}

struct SavedTaskIconPicker: View {
    @Environment(Workspace.self) private var store
    @State private var epoch: UUID?
    let taskID: UUID

    var body: some View {
        Group {
            if let task = store.journal.tasks.first(where: { $0.id == taskID }) {
                TaskIconPicker(icon: Binding(get: { task.icon }, set: { value in
                    guard store.journalEpoch == epoch, let index = store.journal.tasks.firstIndex(where: { $0.id == taskID }) else { return }
                    store.change { $0.tasks[index].icon = value }
                }), fallback: task.category.symbol)
            } else {
                ContentUnavailableView("Task unavailable", systemImage: "checklist")
            }
        }
        .onAppear { if epoch == nil { epoch = store.journalEpoch } }
    }
}

private struct TaskIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var type
    @Binding var icon: TaskIcon?
    let fallback: String
    @State private var entry = ""
    private static let symbols: [(name: String, label: String)] = [
        ("book", "Book"), ("pencil", "Pencil"), ("paintbrush", "Paintbrush"),
        ("laptopcomputer", "Computer"), ("folder", "Folder"), ("lightbulb", "Idea"),
        ("envelope", "Mail"), ("phone", "Phone"), ("bubble.left", "Conversation"),
        ("house", "Home"), ("leaf", "Leaf"), ("cart", "Shopping"),
        ("fork.knife", "Food"), ("cup.and.saucer", "Coffee"), ("figure.walk", "Walk"),
        ("dumbbell", "Workout"), ("heart", "Heart"), ("music.note", "Music"),
        ("camera", "Camera"), ("tram", "Transit"), ("airplane", "Travel"),
        ("wrench.and.screwdriver", "Tools"), ("flag", "Flag"), ("star", "Star")
    ]

    static func name(for icon: TaskIcon?) -> String {
        switch icon {
        case .character(let value): value
        case .symbol(let value): symbols.first { $0.name == value }?.label ?? value
        case nil: "Category icon"
        }
    }

    private func choose(_ value: TaskIcon?) {
        icon = value
        dismiss()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let entryLayout = type.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                    : AnyLayout(HStackLayout(spacing: 8))
                entryLayout {
                    TextField("Emoji or initial", text: $entry, prompt: Text("Emoji or initial").foregroundStyle(Color.moss))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { if TaskIcon.character(entry).isValid { choose(.character(entry)) } }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("task-icon-character")
                    Button("Use") { choose(.character(entry)) }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!TaskIcon.character(entry).isValid)
                }
                .padding(.horizontal, 12)
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.rule) }
                if !entry.isEmpty && !TaskIcon.character(entry).isValid {
                    Text("Choose one emoji or letter.").font(.footnote).foregroundStyle(Color.moss)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: type.isAccessibilitySize ? 62 : 46))], spacing: 6) {
                    ForEach(Self.symbols, id: \.name) { item in
                        let selected = icon == .symbol(item.name)
                        Button { choose(.symbol(item.name)) } label: {
                            Image(systemName: item.name).font(.title3)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(selected ? Color.journalInk.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).accessibilityLabel(item.label)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("task-icon-" + item.name)
                    }
                }
                Button { choose(nil) } label: {
                    Label("Use category icon", systemImage: fallback).frame(minHeight: 44)
                }.accessibilityAddTraits(icon == nil ? .isSelected : [])
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color.paper)
        .navigationTitle("Task icon").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear { if case .character(let value) = icon { entry = value } }
    }
}
