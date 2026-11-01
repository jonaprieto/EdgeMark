import PhotosUI
import SwiftUI

/// Library and camera buttons for any place that takes a photo.
struct PhotoButtons: View {
    let onPhoto: (UIImage) -> Void

    @State private var picked: [PhotosPickerItem] = []
    @State private var showingCamera = false

    var body: some View {
        HStack {
            PhotosPicker(selection: $picked, maxSelectionCount: 4, matching: .images) {
                Label("Photo", systemImage: "photo")
            }
            .buttonStyle(.borderless)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Camera", systemImage: "camera") { showingCamera = true }
                    .buttonStyle(.borderless)
            }
        }
        .onChange(of: picked) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { onPhoto(image) }
                }
                picked = []
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            Camera(onPhoto: onPhoto).ignoresSafeArea()
        }
    }
}

private struct Camera: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: Camera

        init(_ parent: Camera) {
            self.parent = parent
        }

        func imagePickerController(_: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// A small preview of a photo in the mirror.
struct Thumbnail: View {
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            image = await UIImage(contentsOfFile: url.path)?.byPreparingThumbnail(ofSize: CGSize(width: 128, height: 128))
        }
    }
}
