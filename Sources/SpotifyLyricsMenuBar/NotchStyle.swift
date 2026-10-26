import Cocoa

/// The notch surface's fixed look. One place for the numbers the controller's
/// frame math and the card's drawing both need, so they cannot drift apart.
enum NotchStyle {
    static let maxWidth: CGFloat = 460
    /// The collapsed pill stays narrower than the expanded card: it is a hint
    /// sitting on the menu bar, not a reading surface.
    static let collapsedMaxWidth: CGFloat = 420
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
    /// The line being read wraps instead of truncating; two rows is the budget,
    /// because a taller card starts to cover the content it is meant to hint at.
    static let currentLineRows = 2
    static let wrappedLineSpacing: CGFloat = 1

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

    /// Width of the lyric column in a card `width` wide: the side paddings and
    /// the artwork slot are not available to text.
    static func textColumnWidth(for width: CGFloat) -> CGFloat {
        max(0, width - 2 * horizontalPadding - artworkSize - artworkGap)
    }

    /// Height of one expanded row. Only the current row grows, and only by the
    /// number of lines its text wraps to.
    static func rowHeight(slot: Int, currentLineCount: Int) -> CGFloat {
        guard slot == rowRadius else { return lineHeight }
        let count = max(1, currentLineCount)
        return CGFloat(count) * lineHeight + CGFloat(count - 1) * wrappedLineSpacing
    }

    /// Height of all rows, gaps included.
    static func rowsHeight(currentLineCount: Int) -> CGFloat {
        let slots = rowRadius * 2 + 1
        let rows = (0..<slots).reduce(CGFloat.zero) {
            $0 + rowHeight(slot: $1, currentLineCount: currentLineCount)
        }
        return rows + CGFloat(slots - 1) * lineSpacing
    }

    /// How many rows the current line needs at the expanded card's width. The
    /// card draws from the same function, so its frame and its layout agree.
    static func currentLineCount(_ text: String) -> Int {
        NotchText.wrapped(
            text,
            font: currentFont,
            to: textColumnWidth(for: maxWidth),
            maxRows: currentLineRows
        ).count
    }

    static func collapsedSize(for geometry: NotchGeometry, text: String) -> NSSize {
        let measured = NotchText.width(of: text, font: currentFont)
        let width = min(collapsedMaxWidth, max(geometry.notchFrame.width, measured + 2 * horizontalPadding))
        return NSSize(
            width: ceil(width),
            height: contentTop(for: geometry) + collapsedLineHeight + bottomPadding
        )
    }

    static func expandedSize(for geometry: NotchGeometry, currentLine: String) -> NSSize {
        let rowCount = max(1, currentLineCount(currentLine))
        let contentHeight = max(rowsHeight(currentLineCount: rowCount), artworkSize) + 2 * verticalPadding
        return NSSize(width: maxWidth, height: contentTop(for: geometry) + contentHeight)
    }
}

/// Measuring and splitting lyric text. Truncating here instead of in the text
/// system keeps a line stable while the card changes width.
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

    /// Splits `text` into at most `maxRows` rows that each fit `available`,
    /// breaking on spaces. Every row but the last is exact — no ellipsis, so the
    /// line the user is reading is never cut short. Only when the text does not
    /// fit `maxRows` rows is the last one ellipsized. A single word wider than
    /// the column is broken mid-word rather than left overflowing.
    static func wrapped(_ text: String, font: NSFont, to available: CGFloat, maxRows: Int) -> [String] {
        guard available > 0, maxRows > 0 else { return [] }
        var remaining = Substring(text.trimmingCharacters(in: .whitespaces))
        var rows: [String] = []
        while !remaining.isEmpty, rows.count < maxRows {
            let rest = String(remaining)
            let isFinalRow = rows.count == maxRows - 1
            if width(of: rest, font: font) <= available {
                rows.append(rest)
                break
            }
            if isFinalRow {
                rows.append(fitted(rest, font: font, to: available))
                break
            }
            var cut = longestPrefix(of: remaining, font: font, fitting: available)
            if let space = remaining.prefix(cut).lastIndex(of: " "), space > remaining.startIndex {
                cut = remaining.distance(from: remaining.startIndex, to: space)
            }
            rows.append(String(remaining.prefix(cut)))
            remaining = remaining.dropFirst(cut).drop(while: { $0 == " " })
        }
        return rows
    }

    /// Character count of the longest prefix that fits, at least 1 so a call
    /// always makes progress.
    private static func longestPrefix(of text: Substring, font: NSFont, fitting available: CGFloat) -> Int {
        var low = 1
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            if width(of: String(text.prefix(mid)), font: font) <= available {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
