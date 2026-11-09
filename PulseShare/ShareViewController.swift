import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let model = ShareCaptureForm(items: items) { [weak self] added in
            if added {
                self?.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        }
        let host = UIHostingController(rootView: model)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct ShareCaptureForm: View {
    let items: [NSExtensionItem]
    let finish: (Bool) -> Void
    @State private var text = ""
    @State private var link: URL?
    @State private var jpeg: Data?
    @State private var completed = false
    @State private var distraction = false
    @State private var timingCaption = ""
    @State private var missingImage = false
    @State private var loading = true
    @State private var saving = false
    @State private var captureID = UUID()
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                HStack(spacing: 12) {
                    if let jpeg, let preview = UIImage(data: jpeg) {
                        Image(uiImage: preview).resizable().scaledToFill().frame(width: 68, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityLabel("Shared photo")
                    }
                    TextField("Task", text: $text, axis: .vertical).lineLimit(2...10)
                        .accessibilityLabel("Task to add")
                }.disabled(loading || saving)
                Section {
                    Toggle("Save as distraction", isOn: $distraction)
                    if distraction {
                        TextField("Timing (optional)", text: $timingCaption)
                            .accessibilityHint("For example, tomorrow at 3 PM")
                    } else if jpeg != nil {
                        Toggle("Already completed", isOn: $completed)
                    }
                } footer: {
                    if distraction { Text("Stays in Inbox unless you add timing, like “tomorrow at 3pm”.") }
                }
                .disabled(loading || saving)
                if let link {
                    Label(link.absoluteString, systemImage: "link").font(.footnote).lineLimit(2)
                }
                if let failure { Text(failure).font(.footnote) }
                if loading || saving { ProgressView() }
            }
            .navigationTitle("Add to Pulse").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(false) }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard !saving else { return }
                        saving = true
                        failure = nil
                        Task {
                            do {
                                let capture = try SharedCapture(text: text, url: link, id: captureID, jpeg: jpeg,
                                                                alreadyCompleted: !distraction && completed, distraction: distraction,
                                                                timingCaption: timingCaption, timeZoneID: TimeZone.current.identifier)
                                try await SharedCaptureQueue.shared.add(capture)
                                finish(true)
                            } catch {
                                failure = error.localizedDescription
                                saving = false
                            }
                        }
                    }.disabled(loading || saving || missingImage || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task { await readInput() }
    }

    @MainActor private func readInput() async {
        defer { loading = false }
        var bodies: [String] = []
        var titles: [String] = []
        for item in items {
            if let content = item.attributedContentText?.string { bodies.append(content) }
            if let title = item.attributedTitle?.string { titles.append(title) }
            for provider in item.attachments ?? [] {
                if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                    guard jpeg == nil else { missingImage = true; failure = "Choose one photo at a time."; return }
                    do {
                        jpeg = try await Self.photo(from: provider, type: type)
                    } catch {
                        missingImage = true
                        failure = CaptureError.image.localizedDescription
                        return
                    }
                }
                if link == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let value: URL? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                            let url = (item as? URL)
                                ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                ?? (item as? String).flatMap { URL(string: $0) }
                            continuation.resume(returning: url)
                        }
                    }
                    if let value, SharedCapture.isWebLink(value) { link = value }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let body: String? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                            let value = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                            continuation.resume(returning: value)
                        }
                    }
                    if let body { bodies.append(body) }
                }
            }
        }
        let title = (bodies + titles).lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != link?.absoluteString }
        if let title { text = title }
        else if let link { text = link.host ?? link.absoluteString }
        else if jpeg != nil { text = "Photo task" }
        else { failure = "Enter a task to save it to your inbox." }
    }
    private static func photo(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { file, error in
                guard let file else {
                    continuation.resume(throwing: error ?? CaptureError.image)
                    return
                }
                // The provider owns this URL only for the lifetime of the callback.
                continuation.resume(with: Result { try PreparedPhoto.jpeg(from: file) })
            }
        }
    }
}
