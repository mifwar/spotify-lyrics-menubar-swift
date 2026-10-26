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
    /// The cover slot keeps the waveform of the lyric column: 44 pt of artwork
    /// and a 14 pt gutter leave exactly the width the wrapped line is measured
    /// against, so shrinking either would change where lyrics wrap.
    static let artworkSize: CGFloat = 44
    static let artworkGap: CGFloat = 14
    /// Slightly squarer than a squircle at this size: a restrained tile next to
    /// the 16 pt card, not a pill.
    static let artworkCornerRadius: CGFloat = 6
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

    /// Transport controls. The target is 20 pt and the spacing between targets
    /// is deliberately wider than a target, so a near-miss inside the row lands
    /// on nothing instead of on a neighbour's track.
    static let transportButtonSize: CGFloat = 20
    static let transportGap: CGFloat = 28
    static let transportGlyphSize: CGFloat = 15
    static let transportColor = NSColor.white.withAlphaComponent(0.85)

    /// The pinned footer is its own band under the lyric block: a hairline, a
    /// gap, then the transports. The spacing is explicit here instead of being
    /// borrowed from a font's leading, so a font change cannot re-space it.
    static let footerTopGap: CGFloat = 10
    static let separatorHeight: CGFloat = 1
    static let separatorColor = NSColor.white.withAlphaComponent(0.12)
    static let footerGap: CGFloat = 9
    static var footerHeight: CGFloat {
        footerTopGap + separatorHeight + footerGap + transportButtonSize
    }

    static let currentFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let lineFont = NSFont.systemFont(ofSize: 13)
    static let artworkFont = NSFont.systemFont(ofSize: 22)
    static let currentColor = NSColor.white
    static let lineColor = NSColor.white.withAlphaComponent(0.55)
    static let dotColor = NSColor.white.withAlphaComponent(0.85)
    static let artworkFill = NSColor.white.withAlphaComponent(0.1)
    /// A hairline edge so a very dark cover still reads as a tile on the black
    /// card. Faint enough to disappear behind actual artwork.
    static let artworkEdge = NSColor.white.withAlphaComponent(0.08)
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

    /// Slots that actually carry text, with their original indices. Empty slots
    /// at either end are padding — a song's intro has nothing above the first
    /// line — and a card that reserved their space would sit low at the start of
    /// a track and high at the end of one.
    static func visibleSlots(in window: LyricsWindow?) -> [Int] {
        let rows = window?.rows(radius: rowRadius) ?? []
        let filled = rows.indices.filter { rows[$0]?.text.isEmpty == false }
        guard let first = filled.first, let last = filled.last else { return [] }
        // Keep the interior (a gap inside the song is still a row), drop the ends.
        return Array(first...last)
    }

    static func collapsedSize(for geometry: NotchGeometry, text: String) -> NSSize {
        let measured = NotchText.width(of: text, font: currentFont)
        let width = min(collapsedMaxWidth, max(geometry.notchFrame.width, measured + 2 * horizontalPadding))
        return NSSize(
            width: ceil(width),
            height: contentTop(for: geometry) + collapsedLineHeight + bottomPadding
        )
    }

    /// Width of the three transport targets plus the gaps between them.
    static var transportWidth: CGFloat {
        CGFloat(3) * transportButtonSize + CGFloat(2) * transportGap
    }

    /// The glyph for a button. Paused and stopped both offer play: pressing it
    /// is the way back to playing. The card draws from this and the harness
    /// checks it, so the two can never disagree.
    static func transportSymbol(_ command: TransportCommand, playback: PlaybackState) -> String {
        switch command {
        case .previous: return "backward.fill"
        case .next: return "forward.fill"
        case .playPause: return playback == .playing ? "pause.fill" : "play.fill"
        }
    }

    static func expandedSize(
        for geometry: NotchGeometry,
        window: LyricsWindow?,
        showsTransport: Bool
    ) -> NSSize {
        NotchCardLayout.make(
            for: window,
            width: maxWidth,
            contentTop: contentTop(for: geometry),
            showsTransport: showsTransport
        ).size
    }
}

/// One computed geometry for the expanded card: the rows with their wrapped
/// text, the artwork slot, the pinned footer (separator and transport targets)
/// and the size the panel must be.
///
/// Both the controller (which sizes the window) and the view (which draws and
/// hit-tests it) call `make`, so padding, wrapping and the footer cannot make
/// the frame and the drawing disagree — there is no second copy of the
/// arithmetic anywhere.
struct NotchCardLayout {
    /// One drawable expanded row. Rows are laid out once and then both drawn and
    /// hit-tested from these rects — never from a pitch.
    struct Row {
        let slot: Int
        let rect: NSRect
        let lines: [String]
    }

    let size: NSSize
    let rows: [Row]
    let artwork: NSRect
    /// The hairline above the transport targets; nil unless the footer is shown.
    let separator: NSRect?
    /// The whole footer band, separator to the bottom of the targets: a click
    /// anywhere in it belongs to the footer, never to a pin or a seek.
    let footer: NSRect?
    let transport: [(command: TransportCommand, rect: NSRect)]

    /// Only the rows the window has text for are laid out — empty slots at the
    /// ends would otherwise reserve space and leave a song's first lines sitting
    /// near the bottom of the card — and the block is centred vertically inside
    /// the content area, with the artwork centred against it.
    static func make(
        for window: LyricsWindow?,
        width: CGFloat,
        contentTop: CGFloat,
        showsTransport: Bool
    ) -> NotchCardLayout {
        let columnX = NotchStyle.horizontalPadding + NotchStyle.artworkSize + NotchStyle.artworkGap
        let columnWidth = NotchStyle.textColumnWidth(for: width)
        let windowRows = window?.rows(radius: NotchStyle.rowRadius) ?? []
        let slots = NotchStyle.visibleSlots(in: window)

        var texts: [[String]] = []
        var heights: [CGFloat] = []
        for slot in slots {
            let line = windowRows.indices.contains(slot) ? windowRows[slot] : nil
            let lines: [String]
            if slot == NotchStyle.rowRadius {
                lines = NotchText.wrapped(
                    line?.text ?? "",
                    font: NotchStyle.currentFont,
                    to: columnWidth,
                    maxRows: NotchStyle.currentLineRows
                )
            } else {
                lines = line.map { [$0.text] } ?? []
            }
            texts.append(lines)
            heights.append(NotchStyle.rowHeight(slot: slot, currentLineCount: lines.count))
        }

        let rowsHeight = heights.reduce(0, +) + CGFloat(max(0, slots.count - 1)) * NotchStyle.lineSpacing
        let blockHeight = max(rowsHeight, NotchStyle.artworkSize)
        let blockTop = contentTop + NotchStyle.verticalPadding
        var y = blockTop + (blockHeight - rowsHeight) / 2
        var rows: [Row] = []
        for (index, slot) in slots.enumerated() {
            rows.append(Row(
                slot: slot,
                rect: NSRect(x: columnX, y: y, width: columnWidth, height: heights[index]),
                lines: texts[index]
            ))
            y += heights[index] + NotchStyle.lineSpacing
        }

        let artwork = NSRect(
            x: NotchStyle.horizontalPadding,
            y: blockTop + blockHeight / 2 - NotchStyle.artworkSize / 2,
            width: NotchStyle.artworkSize,
            height: NotchStyle.artworkSize
        )

        var height = blockTop + blockHeight + NotchStyle.verticalPadding
        var separator: NSRect?
        var footer: NSRect?
        var transport: [(command: TransportCommand, rect: NSRect)] = []
        if showsTransport {
            // The hairline lines up with the text margins, not with the card's
            // edge, so it reads as part of the composition above it.
            let separatorRect = NSRect(
                x: NotchStyle.horizontalPadding,
                y: blockTop + blockHeight + NotchStyle.footerTopGap,
                width: max(0, width - 2 * NotchStyle.horizontalPadding),
                height: NotchStyle.separatorHeight
            )
            let targetTop = separatorRect.maxY + NotchStyle.footerGap
            let stride = NotchStyle.transportButtonSize + NotchStyle.transportGap
            let firstX = width / 2 - NotchStyle.transportWidth / 2
            let commands: [TransportCommand] = [.previous, .playPause, .next]
            transport = commands.enumerated().map { index, command in
                (command, NSRect(
                    x: firstX + CGFloat(index) * stride,
                    y: targetTop,
                    width: NotchStyle.transportButtonSize,
                    height: NotchStyle.transportButtonSize
                ))
            }
            separator = separatorRect
            footer = NSRect(
                x: 0,
                y: separatorRect.minY,
                width: width,
                height: separatorRect.height + NotchStyle.footerGap + NotchStyle.transportButtonSize
            )
            height += NotchStyle.footerHeight
        }

        return NotchCardLayout(
            size: NSSize(width: width, height: height),
            rows: rows,
            artwork: artwork,
            separator: separator,
            footer: footer,
            transport: transport
        )
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
