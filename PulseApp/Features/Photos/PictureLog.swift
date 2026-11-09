import AVFoundation
import CoreTransferable
import PhotosUI
import PulseEngine
import SwiftUI
import UniformTypeIdentifiers

private struct PickedPhoto: Transferable {
    let jpeg: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            // The provider owns this URL for the duration of this import.
            try Task.checkCancellation()
            let data = try await PreparedPhoto.pickedJPEG(from: received.file)
            try Task.checkCancellation()
            return PickedPhoto(jpeg: data)
        }
    }
}

extension PreparedPhoto {
    @concurrent static func pickedJPEG(from url: URL) async throws -> Data {
        try Task.checkCancellation()
        return try jpeg(from: url)
    }

    @concurrent static func cameraJPEG(from image: UIImage) async throws -> Data {
        try Task.checkCancellation()
        guard let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: side, height: side)) else {
            throw CaptureError.image
        }
        try Task.checkCancellation()
        // UIKit can retain an orientation tag on a thumbnail. Drawing only these
        // bounded pixels bakes rotations and mirroring into the exported JPEG.
        guard let pixels = thumbnail.cgImage else { throw CaptureError.image }
        if thumbnail.imageOrientation == .up { return try jpeg(fromOrientedPixels: pixels) }
        let size = CGSize(width: thumbnail.size.width * thumbnail.scale, height: thumbnail.size.height * thumbnail.scale)
        guard size.width > 0, size.height > 0, max(size.width, size.height) <= CGFloat(side) else { throw CaptureError.image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let oriented = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            thumbnail.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let orientedPixels = oriented.cgImage else { throw CaptureError.image }
        return try jpeg(fromOrientedPixels: orientedPixels)
    }
}

struct PhotoSelection<Source> {
    struct Request {
        let id = UUID()
        let source: Source
    }
    private(set) var current: Request?

    mutating func choose(_ source: Source) {
        current = Request(source: source)
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard current?.id == id else { return false }
        current = nil
        return true
    }
}

struct PhotoInput: View {
    let accept: (Data) -> Void
    private enum Source {
        case library(PhotosPickerItem)
        case camera(UIImage)
    }
    @State private var choices = PhotoSelection<Source>()
    @State private var camera = false
    @State private var photoError: String?
    private var selection: Binding<PhotosPickerItem?> {
        Binding {
            if case .library(let item) = choices.current?.source { return item }
            return nil
        } set: { item in
            if let item { choices.choose(.library(item)) }
        }
    }

    var body: some View {
        Group {
            PhotosPicker(selection: selection, matching: .images, preferredItemEncoding: .current) {
                Label("Choose photo", systemImage: "photo")
            }
            .task(id: choices.current?.id) { await prepareSelection() }
            .fullScreenCover(isPresented: $camera) {
                PictureCamera { result in
                    camera = false
                    switch result {
                    case .success(let image): if let image { choices.choose(.camera(image)) }
                    case .failure: photoError = "The camera couldn’t provide a photo. Try taking it again."
                    }
                }.ignoresSafeArea()
            }
            .alert(
                "Photo unavailable", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })
            ) {
                Button("Close") {}
            } message: {
                Text(photoError ?? "")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take photo", systemImage: "camera") {
                    Task {
                        if await AVCaptureDevice.requestAccess(for: .video) {
                            camera = true
                        } else {
                            photoError = "Allow camera access in Settings, or choose a saved photo."
                        }
                    }
                }
            }
            if choices.current != nil { ProgressView("Preparing photo") }
        }
    }

    private func prepareSelection() async {
        guard let current = choices.current else { return }
        do {
            let jpeg: Data
            switch current.source {
            case .library(let item):
                guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else { throw CaptureError.image }
                jpeg = picked.jpeg
            case .camera(let image):
                jpeg = try await PreparedPhoto.cameraJPEG(from: image)
            }
            guard !Task.isCancelled, choices.finish(current.id) else { return }
            accept(jpeg)
        } catch {
            guard !Task.isCancelled, choices.finish(current.id) else { return }
            photoError = (error as? CaptureError)?.localizedDescription ?? "This photo couldn’t be opened. Choose another image."
        }
    }
}

private struct PictureCamera: UIViewControllerRepresentable {
    let finish: (Result<UIImage?, CaptureError>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finish) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (Result<UIImage?, CaptureError>) -> Void
        init(_ finish: @escaping (Result<UIImage?, CaptureError>) -> Void) { self.finish = finish }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(.success(nil)) }
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else { finish(.failure(.image)); return }
            finish(.success(image))
        }
    }
}

extension View {
    func completionProofSheet(active: Bool = true, onDismiss: @escaping () -> Void = {}) -> some View {
        modifier(CompletionProofSheet(active: active, onDismiss: onDismiss))
    }
}

private struct CompletionProofSheet: ViewModifier {
    @Environment(Workspace.self) private var store
    let active: Bool
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? store.pendingCompletionProof : nil }, set: { request in
            if active { store.pendingCompletionProof = request }
        }), onDismiss: onDismiss) { request in
            NavigationStack { CompletionPhotoScreen(request: request) }
                .preferredColorScheme(store.sky.interfaceScheme)
        }
    }
}

struct CompletionPhotoScreen: View {
    @Environment(Workspace.self) private var store
    @Environment(\.dismiss) private var dismiss
    private enum Source {
        case session(ActiveSession)
        case required(CompletionProofRequest)
    }
    private let source: Source
    @State private var jpeg: Data?
    @State private var issue: String?
    @State private var saved = false

    init(session: ActiveSession) { source = .session(session) }
    init(request: CompletionProofRequest) { source = .required(request) }

    private var taskTitle: String {
        switch source {
        case .session(let session): return session.title
        case .required(let request):
            return store.journal.tasks.first { $0.id == request.taskID }?.title ?? "Task"
        }
    }

    private var saveLabel: String {
        switch source {
        case .session: "Save and finish"
        case .required(let request): request.sessionStart == nil ? "Save and complete" : "Save and finish"
        }
    }

    var body: some View {
        Form {
            Section {
                if let jpeg, let image = UIImage(data: jpeg) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 235)
                        .frame(maxWidth: .infinity).privacySensitive().accessibilityLabel("Selected photo")
                }
                PhotoInput { data in
                    guard JournalPhoto.fits(data, in: store.journal) else {
                        jpeg = nil
                        issue = "The picture log is full. Remove an older photo, then try again."
                        return
                    }
                    jpeg = data
                    issue = nil
                }
            } header: {
                Text(taskTitle).textCase(nil).accessibilityAddTraits(.isHeader)
            } footer: {
                if case .required = source { Text("Add a photo to the picture log to complete this task.") }
            }
            if let issue { Text(issue).foregroundStyle(Color.clay).fixedSize(horizontal: false, vertical: true) }
        }
        .formPaper().navigationTitle("Completion photo").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveLabel, action: save)
                    .disabled(jpeg == nil || saved || !store.ready || store.restoring)
                    .accessibilityIdentifier("save-completion-proof")
            }
        }
    }

    private func save() {
        guard let jpeg, !saved, store.ready, !store.restoring else { return }
        guard JournalPhoto.fits(jpeg, in: store.journal) else {
            issue = "The picture log is full. Remove an older photo, then try again."
            return
        }
        switch source {
        case .required(let request):
            do { try store.completeWithProof(request, jpeg: jpeg) }
            catch { issue = error.localizedDescription; return }
        case .session(let session):
            guard let active = store.journal.active, active.started == session.started,
                  active.sessionID == session.sessionID, active.taskID == session.taskID else {
                issue = "This focus session is no longer active."
                return
            }
            store.finish(done: true, photo: JournalPhoto(taskID: session.taskID, title: session.title, completion: true, jpeg: jpeg))
            guard store.journal.active == nil else {
                issue = "This session couldn’t finish. Try again."
                return
            }
        }
        saved = true
        dismiss()
    }
}
