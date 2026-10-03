import SwiftUI

/// Small rounded badge with a file's extension in white on its language colour, shown in
/// place of the document icon for non-Markdown gist files. The label and colour come from
/// `FileTypeStyle`; no images are bundled.
struct FileTypeBadge: View {
    let fileExtension: String
    /// Width of the icon slot it fills, like the 24 pt document icon.
    var size: CGFloat = 24

    var body: some View {
        let style = FileTypeStyle.style(forExtension: fileExtension)
        let shape = RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
        Text(style.label)
            .font(.system(size: size * (style.label.count > 3 ? 0.3 : 0.38), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, size * 0.06)
            .frame(width: size, height: size * 0.72)
            .background(shape.fill(Color(red: style.rgb.red, green: style.rgb.green, blue: style.rgb.blue)))
            // Keeps the edge visible on dark backgrounds; invisible on light ones.
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityLabel(style.label)
    }
}

/// The icon of a note row: a `FileTypeBadge` for a non-Markdown gist file, the document
/// icon otherwise.
struct NoteTypeIcon: View {
    let note: Note
    let width: CGFloat

    var body: some View {
        if note.isPlainTextFile {
            FileTypeBadge(fileExtension: note.fileExtension, size: width)
                .frame(width: width)
        } else {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: width)
        }
    }
}
