import AppKit
import ImageIO
import SwiftUI

/// An attachment's bytes, shown on demand.
///
/// The row in the turn deliberately shows only the name — reading the file back
/// for every turn on every frame is a cost the transcript does not need. This is
/// the other half of that choice: the bytes are still on disk beside the thread,
/// so asking for the file again costs one read at the moment it is wanted, and
/// the popover is where that read happens.
///
/// Missing bytes are an ordinary state, not an error: the store sweeps files
/// whose records are gone, and a thread restored from an older archive may never
/// have had them. Saying so plainly is kinder than an empty card.
struct AttachmentPreview: View {

    @Environment(\.panelTextScale) private var textScale

    let attachment: Attachment
    let data: Data?
    /// An input, so an open preview restyles when the theme changes.
    var palette: PanelPalette = PanelTheme.palette

    var body: some View {
        VStack(alignment: .leading, spacing: PanelTheme.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: PanelTheme.Space.small) {
                Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
                Text(attachment.name)
                    .font(PanelTheme.Font.at(12, textScale, weight: .medium))
                    .foregroundStyle(PanelTheme.Palette.primaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(attachment.sizeDescription)
                    .font(PanelTheme.Font.caption(textScale))
                    .foregroundStyle(PanelTheme.Palette.tertiaryText)
            }

            content
        }
        .accessibilityElement(children: .contain)
        .padding(PanelTheme.Space.medium)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if let data {
            switch attachment.kind {
            case .image:
                if let image = Self.downsampledImage(from: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 300)
                } else {
                    // The record says image, the bytes disagree — possible after a
                    // hand-edited archive, and worth saying rather than blank space.
                    Text("These bytes do not decode as an image.")
                        .font(PanelTheme.Font.caption(textScale))
                        .foregroundStyle(PanelTheme.Palette.secondaryText)
                }
            case .text, .other:
                if let text = String(data: data, encoding: .utf8) {
                    ScrollView {
                        Text(text)
                            .font(PanelTheme.Font.at(11, textScale, design: .monospaced))
                            .foregroundStyle(PanelTheme.Palette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text("These bytes do not decode as text.")
                        .font(PanelTheme.Font.caption(textScale))
                        .foregroundStyle(PanelTheme.Palette.secondaryText)
                }
            }
        } else {
            Text("The attachment's bytes are no longer stored — only its name "
                 + "and size were kept.")
                .font(PanelTheme.Font.caption(textScale))
                .foregroundStyle(PanelTheme.Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ImageIO decodes near the displayed size, avoiding a full-resolution bitmap
    /// for a thumbnail that is at most 300 points tall.
    private static func downsampledImage(from data: Data) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 720
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
