import ImageIO
import PulseEngine
import SwiftUI

struct PictureLogScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dynamicTypeSize) private var type
    var taskID: UUID?
    @State private var adding = false
    @State private var deleting: JournalPhoto?
    private enum Filter: String, CaseIterable { case all = "All photos", plan = "Plan", completion = "Completed" }
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @Namespace private var photoTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var photos: [JournalPhoto] {
        (store.journal.photos ?? []).filter { taskID == nil || $0.taskID == taskID }.sorted { $0.date > $1.date }
    }
    var body: some View {
        let all = photos
        let matches = JournalPhoto.matching(all, query: query, tasks: store.journal.tasks)
        let visible = matches.filter { filter == .all || $0.completion == (filter == .completion) }
        let groups = Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.date) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if all.isEmpty {
                    ContentUnavailableView {
                        Label("No photos yet", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("Keep a reference for a task or a picture of what you finished.")
                    } actions: {
                        Button("Add a photo") { adding = true }
                    }
                } else {
                    if filter != .all || (all.contains(where: \.completion) && all.contains(where: { !$0.completion })) {
                        Picker("Photos", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { option in Text(option.rawValue).tag(option) }
                        }.pickerStyle(.segmented)
                    }
                    if visible.isEmpty {
                        if query.isEmpty { Text("No photos in this view.").foregroundStyle(Color.moss) }
                        else { ContentUnavailableView.search(text: query) }
                    }
                    ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                        let entries = groups[day] ?? []
                        VStack(alignment: .leading, spacing: 10) {
                            Text(dayTitle(day)).font(.title3.weight(.medium)).accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns(count: searching ? 1 : entries.count), alignment: .leading, spacing: 16) {
                                ForEach(entries) { photo in
                                    NavigationLink { detail(photo) } label: {
                                        if searching {
                                            HStack(alignment: .top, spacing: 12) {
                                                thumbnail(photo, aspect: 1).frame(width: 64, height: 64)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    photoTitle(photo)
                                                    if let note = photo.caption, !query.isEmpty && note.localizedStandardContains(query) {
                                                        Text(note).font(.subheadline).foregroundStyle(Color.moss)
                                                            .lineLimit(type.isAccessibilitySize ? nil : 2)
                                                            .fixedSize(horizontal: false, vertical: true).privacySensitive()
                                                    } else { photoTime(photo) }
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                            }.contentShape(Rectangle())
                                        } else {
                                            VStack(alignment: .leading, spacing: 6) {
                                                thumbnail(photo, aspect: entries.count == 1 ? 1.5 : 1)
                                                photoTitle(photo)
                                                photoTime(photo)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(PressStyle())
                                    .accessibilityLabel(photo.title + (photo.completion ? ", completion photo" : ", plan photo"))
                                    .accessibilityValue(photo.date.formatted(date: .abbreviated, time: .shortened))
                                    .contextMenu { Button("Delete photo", systemImage: "trash", role: .destructive) { deleting = photo } }
                                    .accessibilityAction(named: "Delete photo") { deleting = photo }
                                }
                            }
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity).background(Color.paper)
        .safeAreaInset(edge: .top, spacing: 0) {
            if searching {
                HStack(spacing: 10) {
                    TextField("Find a photo", text: $query, prompt: Text("Find a photo").foregroundStyle(Color.moss))
                        .font(.body).foregroundStyle(Color.journalInk).focused($searchFocused)
                        .submitLabel(.search).onSubmit { searchFocused = false }
                        .accessibilityLabel("Find a photo").accessibilityIdentifier("picture-search-input")
                    if !query.isEmpty {
                        Button { query = ""; searchFocused = true } label: {
                            Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(Color.moss)
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("Clear search")
                    }
                }
                .frame(maxWidth: 580, minHeight: 48).padding(.horizontal, 20)
                .frame(maxWidth: .infinity).background(Color.paper)
                .onAppear { searchFocused = true }
            }
        }
        .navigationTitle("Picture log").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if taskID == nil && !all.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        searching.toggle()
                        if !searching { query = ""; searchFocused = false }
                    } label: {
                        Image(systemName: searching ? "xmark" : "magnifyingglass")
                            .font(.headline).frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(searching ? "Close search" : "Search photos")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add photo", systemImage: "plus") { adding = true }
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { PictureEntryForm(taskID: taskID) } }
        .alert("Delete photo?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { photo in
            Button("Delete", role: .destructive) {
                store.change { $0.photos?.removeAll { $0.id == photo.id } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private func photoTitle(_ photo: JournalPhoto) -> some View {
        Text(photo.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.journalInk)
            .lineLimit(type.isAccessibilitySize ? nil : 2)
    }

    private func photoTime(_ photo: JournalPhoto) -> some View {
        Label(photo.date.formatted(date: .omitted, time: .shortened), systemImage: photo.completion ? "checkmark.circle" : "calendar")
            .font(.caption).foregroundStyle(Color.moss)
    }

    @ViewBuilder private func thumbnail(_ photo: JournalPhoto, aspect: CGFloat) -> some View {
        let thumbnail = PictureThumbnail(photo: photo).aspectRatio(aspect, contentMode: .fit)
        if #available(iOS 18.0, *), !reduceMotion {
            thumbnail.matchedTransitionSource(id: photo.id, in: photoTransition)
        } else { thumbnail }
    }

    @ViewBuilder private func detail(_ photo: JournalPhoto) -> some View {
        let screen = PictureDetailScreen(id: photo.id)
        if #available(iOS 18.0, *), !reduceMotion {
            screen.navigationTransition(.zoom(sourceID: photo.id, in: photoTransition))
        } else { screen }
    }

    private func columns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading), count: count == 1 || type.isAccessibilitySize ? 1 : 2)
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }
}

private struct PictureThumbnail: View {
    let photo: JournalPhoto
    @Environment(\.displayScale) private var scale
    @State private var thumb: UIImage?
    private struct Request: Equatable {
        let jpeg: Data
        let pixels: Int
    }
    var body: some View {
        GeometryReader { proxy in
            let pixels = min(1440, max(128, Int(max(proxy.size.width, proxy.size.height) * scale)))
            Color.primary.opacity(0.055)
                .overlay {
                    if let thumb { Image(uiImage: thumb).resizable().scaledToFill() }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .task(id: Request(jpeg: photo.jpeg, pixels: pixels)) {
                    let data = photo.jpeg
                    let bitmap = await Task.detached(priority: .utility) {
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: pixels,
                            kCGImageSourceShouldCacheImmediately: true,
                        ] as CFDictionary)
                    }.value
                    if !Task.isCancelled { thumb = bitmap.map { UIImage(cgImage: $0) } }
                }
        }.accessibilityHidden(true).privacySensitive()
    }
}

private struct PictureDetailScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var type
    let id: UUID
    @State private var deleting = false
    @State private var editingCaption = false
    var body: some View {
        if let photo = store.journal.photos?.first(where: { $0.id == id }) {
            GeometryReader { viewport in
                if type.isAccessibilitySize {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            image(photo).frame(height: max(180, viewport.size.height * 0.42))
                            caption(photo).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        image(photo)
                        caption(photo)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }.background(Color.paper)
                .navigationTitle(photo.completion ? "Completion photo" : "Plan photo").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Delete photo", systemImage: "trash") { deleting = true }
                    }
                }
                .sheet(isPresented: $editingCaption) {
                    NavigationStack { PictureCaptionEditor(photo: photo) }
                        .presentationDetents(type.isAccessibilitySize ? [.large] : [.medium, .large])
                }
                .alert("Delete photo?", isPresented: $deleting) {
                    Button("Delete", role: .destructive) {
                        store.change { $0.photos?.removeAll { $0.id == id } }
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
        } else {
            ContentUnavailableView("Photo unavailable", systemImage: "photo")
                .navigationTitle("Picture log")
        }
    }
    private func image(_ photo: JournalPhoto) -> some View {
        ZoomableJournalPicture(jpeg: photo.jpeg, title: photo.title).privacySensitive()
    }

    private func caption(_ photo: JournalPhoto) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(photo.title).font(.title2.weight(.medium)).accessibilityAddTraits(.isHeader)
            Text(photo.date.formatted(date: .long, time: .shortened)).font(.subheadline).foregroundStyle(Color.moss)
            Button { editingCaption = true } label: {
                if let note = photo.caption {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(note).font(.body).multilineTextAlignment(.leading).lineLimit(type.isAccessibilitySize ? nil : 3).privacySensitive()
                        Image(systemName: "pencil").font(.caption)
                    }.frame(minHeight: 44, alignment: .leading)
                } else {
                    Label("Add caption", systemImage: "text.bubble").font(.subheadline).frame(minHeight: 44)
                }
            }
            .accessibilityLabel(photo.caption == nil ? "Add caption" : "Edit caption")
            .accessibilityValue(photo.caption ?? "").accessibilityIdentifier("picture-caption")
            if let task = store.journal.tasks.first(where: { $0.id == photo.taskID }) {
                NavigationLink("Open task") { TaskEditor(task: task) }.frame(minHeight: 44)
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }

}


private struct PictureCaptionEditor: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var writing: Bool
    let photo: JournalPhoto
    @State private var text: String

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(photo: JournalPhoto) {
        self.photo = photo
        _text = State(initialValue: photo.caption ?? "")
    }

    var body: some View {
        Form {
            TextField("Photo caption", text: $text, axis: .vertical)
                .font(.body).lineLimit(3...8).focused($writing).privacySensitive().accessibilityIdentifier("picture-caption-input")
        }
        .formPaper().navigationTitle("Photo caption").navigationBarTitleDisplayMode(.inline)
        .onAppear { writing = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    let note = trimmed
                    store.change { journal in
                        guard let index = journal.photos?.firstIndex(where: { $0.id == photo.id }) else { return }
                        journal.photos?[index].caption = note.isEmpty ? nil : note
                    }
                    dismiss()
                } label: {
                    Image(systemName: "checkmark").font(.headline).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Save")
                .disabled(!store.ready || store.restoring || trimmed == (photo.caption ?? ""))
            }
        }
    }
}
