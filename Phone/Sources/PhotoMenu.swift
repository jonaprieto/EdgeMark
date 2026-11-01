import PhotosUI
import SwiftUI

/// Camera and library behind one button, for any place that takes a photo. One pick arrives as one
/// call, however many photos it holds.
struct PhotoMenu<Title: View>: View {
    let onPhotos: ([UIImage]) -> Void
    @ViewBuilder let title: () -> Title

    @State private var picked: [PhotosPickerItem] = []
    @State private var choosing = false
    @State private var showingCamera = false

    var body: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { showingCamera = true }
            }
            Button("Choose Photo", systemImage: "photo") { choosing = true }
        } label: {
            title()
        }
        .photosPicker(isPresented: $choosing, selection: $picked, maxSelectionCount: 4, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var photos: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { photos.append(image) }
                }
                picked = []
                if !photos.isEmpty { onPhotos(photos) }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            Camera { onPhotos([$0]) }.ignoresSafeArea()
        }
    }
}

/// What a sheet will save, before it does.
struct PhotoStrip: View {
    let photos: [UIImage]

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(photos.indices, id: \.self) { index in
                    Image(uiImage: photos[index]).resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
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
