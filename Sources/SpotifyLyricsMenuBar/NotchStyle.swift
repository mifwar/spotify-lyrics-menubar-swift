import Cocoa

/// The notch surface's fixed look. One place for the numbers the controller's
/// frame math and the card's drawing both need, so they cannot drift apart.
enum NotchStyle {
    static let maxWidth: CGFloat = 420
    static let horizontalPadding: CGFloat = 18
    static let collapsedLineHeight: CGFloat = 26
    static let bottomPadding: CGFloat = 6
    static let lineHeight: CGFloat = 19
    static let lineSpacing: CGFloat = 3
    static let verticalPadding: CGFloat = 10
    static let artworkSize: CGFloat = 44
    static let artworkGap: CGFloat = 14
    static let artworkCornerRadius: CGFloat = 8
    static let cornerRadius: CGFloat = 16

    /// The dot's window is bigger than the dot so a click can find it.
    static let dotDiameter: CGFloat = 6
    static let dotHitSize: CGFloat = 24

    /// The expanded card shows the current line and two either side. The shared
    /// window is wider (see `LyricsWindow.radius`); `rows(radius:)` slices it.
    static let rowRadius = 2
    static let rowsHeight = CGFloat(rowRadius * 2 + 1) * lineHeight + CGFloat(rowRadius * 2) * lineSpacing

    static let currentFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let lineFont = NSFont.systemFont(ofSize: 13)
    static let artworkFont = NSFont.systemFont(ofSize: 28)
    static let currentColor = NSColor.white
    static let lineColor = NSColor.white.withAlphaComponent(0.55)
    static let dotColor = NSColor.white.withAlphaComponent(0.85)
    static let artworkFill = NSColor.white.withAlphaComponent(0.1)
    static let artworkGlyphColor = NSColor.white.withAlphaComponent(0.5)

    /// Blank strip the hardware cutout occupies. Nothing may be drawn there, so
    /// on a notched display all content starts below it; a simulated notch is
    /// drawn by the card itself, so its content starts at the top edge.
    static func contentTop(for geometry: NotchGeometry) -> CGFloat {
        geometry.isSimulated ? 0 : geometry.notchFrame.height
    }

    static func collapsedSize(for geometry: NotchGeometry, text: String) -> NSSize {
        let measured = NotchText.width(of: text, font: currentFont)
        let width = min(maxWidth, max(geometry.notchFrame.width, measured + 2 * horizontalPadding))
        return NSSize(
            width: ceil(width),
            height: contentTop(for: geometry) + collapsedLineHeight + bottomPadding
        )
    }

    static func expandedSize(for geometry: NotchGeometry) -> NSSize {
        let contentHeight = max(rowsHeight, artworkSize) + 2 * verticalPadding
        return NSSize(width: maxWidth, height: contentTop(for: geometry) + contentHeight)
    }
}

/// Measuring and tail-ellipsizing lyric text. Truncating here instead of in the
/// text system keeps a line stable while the card changes width.
enum NotchText {
    static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func fitted(_ text: String, font: NSFont, to available: CGFloat) -> String {
        guard width(of: text, font: font) > available else { return text }
        let ellipsis = "…"
        guard width(of: ellipsis, font: font) <= available else { return "" }
        var low = 0
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            if width(of: String(text.prefix(mid)) + ellipsis, font: font) <= available {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(text.prefix(low)) + ellipsis
    }
}
