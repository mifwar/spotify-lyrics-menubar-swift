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
    static let verticalPadding: CGFloat = 12
    /// The header is a now-playing row: the cover, then title over artist, with
    /// the pin at the right edge. The lyric block hangs below it at full width,
    /// so the line being read gets the whole card instead of a side column.
    static let artworkSize: CGFloat = 40
    static let artworkGap: CGFloat = 12
    static let headerGap: CGFloat = 12
    static let pinButtonSize: CGFloat = 24
    static let pinButtonGap: CGFloat = 8
    /// Slightly squarer than a squircle at this size: a restrained tile next to
    /// the 16 pt card, not a pill.
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

    /// Transport controls. The target is 22 pt and the spacing between targets
    /// is deliberately wider than a target, so a near-miss inside the row lands
    /// on nothing instead of on a neighbour's track.
    static let transportButtonSize: CGFloat = 22
    static let transportGap: CGFloat = 30
    static let transportGlyphSize: CGFloat = 14
    /// Play/pause is the primary control and reads a size up from its neighbours.
    static let primaryTransportGlyphSize: CGFloat = 19
    static let transportColor = NSColor.white.withAlphaComponent(0.9)

    /// The footer is its own band under the lyric block: elapsed time, a
    /// progress track and the duration, then the transports. The spacing is
    /// explicit here instead of being borrowed from a font's leading, so a font
    /// change cannot re-space it.
    static let footerTopGap: CGFloat = 12
    static let progressRowHeight: CGFloat = 12
    static let progressBarHeight: CGFloat = 4
    /// A thin track is hard to hit; clicks within this distance of it count.
    static let progressHitSlop: CGFloat = 5
    /// Room for "1:00:00" in the time font; the bar runs between the two labels.
    static let timeLabelWidth: CGFloat = 40
    static let timeLabelGap: CGFloat = 8
    static let footerGap: CGFloat = 8
    static var footerHeight: CGFloat {
        footerTopGap + progressRowHeight + footerGap + transportButtonSize
    }

    static let progressTrackColor = NSColor.white.withAlphaComponent(0.18)
    static let progressFillColor = NSColor.white.withAlphaComponent(0.9)
    /// The collapsed pill carries the same progress as a quiet hairline under
    /// the lyric, so the song's position is readable without hovering.
    static let collapsedProgressHeight: CGFloat = 2
    static let collapsedProgressTrackColor = NSColor.white.withAlphaComponent(0.1)
    static let collapsedProgressFillColor = NSColor.white.withAlphaComponent(0.45)

    static let currentFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let lineFont = NSFont.systemFont(ofSize: 13)
    static let artworkFont = NSFont.systemFont(ofSize: 20)
    static let currentColor = NSColor.white
    static let lineColor = NSColor.white.withAlphaComponent(0.55)
    /// Two lines away from the current one: further back, so the block reads
    /// as fading out from the line being sung.
    static let farLineColor = NSColor.white.withAlphaComponent(0.3)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let artistFont = NSFont.systemFont(ofSize: 12)
    static let titleColor = NSColor.white
    static let artistColor = NSColor.white.withAlphaComponent(0.55)
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    static let timeColor = NSColor.white.withAlphaComponent(0.55)
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

    /// Width of the lyric column in a card `width` wide: everything but the
    /// side paddings, since the cover lives in the header above it.
    static func textColumnWidth(for width: CGFloat) -> CGFloat {
        max(0, width - 2 * horizontalPadding)
    }

    /// Where the first lyric row may start: below the cutout, the top padding,
    /// the now-playing header and the gap under it.
    static func lyricsTop(contentTop: CGFloat) -> CGFloat {
        contentTop + verticalPadding + artworkSize + headerGap
    }

    /// Lines further from the current one fade further back.
    static func contextLineColor(slot: Int) -> NSColor {
        abs(slot - rowRadius) >= 2 ? farLineColor : lineColor
    }

    /// "m:ss", or "h:mm:ss" past an hour. Negative and non-finite read as 0:00.
    static func formatTime(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
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
        window: LyricsWindow?
    ) -> NSSize {
        NotchCardLayout.make(
            for: window,
            width: maxWidth,
            contentTop: contentTop(for: geometry)
        ).size
    }
}

/// One computed geometry for the expanded card: the now-playing header (cover,
/// title and artist, pin), the lyric rows with their wrapped text, the playback
/// footer (progress and transport targets) and the size the panel must be.
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
    /// Title over artist, between the cover and the pin.
    let title: NSRect
    let artist: NSRect
    let pinButton: NSRect
    /// The progress track, and the time labels either side of it.
    let progressBar: NSRect
    let elapsedLabel: NSRect
    let durationLabel: NSRect
    /// The whole footer band, progress row to the bottom of the targets: a click
    /// anywhere in it belongs to the footer, never to a pin or a seek to a line.
    let footer: NSRect
    let transport: [(command: TransportCommand, rect: NSRect)]

    /// The track plus its slop, so a thin bar can still be clicked.
    var progressHitArea: NSRect {
        progressBar.insetBy(dx: -NotchStyle.progressHitSlop, dy: -NotchStyle.progressHitSlop)
    }

    /// Only the rows the window has text for are laid out — empty slots at the
    /// ends would otherwise reserve space and leave a song's first lines sitting
    /// near the bottom of the card. The header and footer are fixed bands, so
    /// the card only ever grows or shrinks by its lyric rows.
    static func make(
        for window: LyricsWindow?,
        width: CGFloat,
        contentTop: CGFloat
    ) -> NotchCardLayout {
        let padding = NotchStyle.horizontalPadding
        let columnWidth = NotchStyle.textColumnWidth(for: width)
        let windowRows = window?.rows(radius: NotchStyle.rowRadius) ?? []
        let slots = NotchStyle.visibleSlots(in: window)

        // Header: cover on the left, pin on the right, title over artist
        // between them, the pair centred against the cover.
        let headerTop = contentTop + NotchStyle.verticalPadding
        let artwork = NSRect(x: padding, y: headerTop, width: NotchStyle.artworkSize, height: NotchStyle.artworkSize)
        let pinButton = NSRect(
            x: width - padding - NotchStyle.pinButtonSize,
            y: artwork.midY - NotchStyle.pinButtonSize / 2,
            width: NotchStyle.pinButtonSize,
            height: NotchStyle.pinButtonSize
        )
        let textX = artwork.maxX + NotchStyle.artworkGap
        let textWidth = max(0, pinButton.minX - NotchStyle.pinButtonGap - textX)
        let titleHeight = ceil(NotchStyle.titleFont.ascender - NotchStyle.titleFont.descender)
        let artistHeight = ceil(NotchStyle.artistFont.ascender - NotchStyle.artistFont.descender)
        let textBlockTop = artwork.midY - (titleHeight + 2 + artistHeight) / 2
        let title = NSRect(x: textX, y: textBlockTop, width: textWidth, height: titleHeight)
        let artist = NSRect(x: textX, y: title.maxY + 2, width: textWidth, height: artistHeight)

        // Lyrics: full width under the header.
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
        let lyricsTop = NotchStyle.lyricsTop(contentTop: contentTop)
        var y = lyricsTop
        var rows: [Row] = []
        for (index, slot) in slots.enumerated() {
            rows.append(Row(
                slot: slot,
                rect: NSRect(x: padding, y: y, width: columnWidth, height: heights[index]),
                lines: texts[index]
            ))
            y += heights[index] + NotchStyle.lineSpacing
        }

        // Footer: elapsed ── progress ── duration, then the transports.
        let progressTop = lyricsTop + rowsHeight + NotchStyle.footerTopGap
        let elapsedLabel = NSRect(
            x: padding,
            y: progressTop,
            width: NotchStyle.timeLabelWidth,
            height: NotchStyle.progressRowHeight
        )
        let durationLabel = NSRect(
            x: width - padding - NotchStyle.timeLabelWidth,
            y: progressTop,
            width: NotchStyle.timeLabelWidth,
            height: NotchStyle.progressRowHeight
        )
        let barX = elapsedLabel.maxX + NotchStyle.timeLabelGap
        let progressBar = NSRect(
            x: barX,
            y: progressTop + (NotchStyle.progressRowHeight - NotchStyle.progressBarHeight) / 2,
            width: max(0, durationLabel.minX - NotchStyle.timeLabelGap - barX),
            height: NotchStyle.progressBarHeight
        )

        let targetTop = progressTop + NotchStyle.progressRowHeight + NotchStyle.footerGap
        let stride = NotchStyle.transportButtonSize + NotchStyle.transportGap
        let firstX = width / 2 - NotchStyle.transportWidth / 2
        let commands: [TransportCommand] = [.previous, .playPause, .next]
        let transport = commands.enumerated().map { index, command in
            (command, NSRect(
                x: firstX + CGFloat(index) * stride,
                y: targetTop,
                width: NotchStyle.transportButtonSize,
                height: NotchStyle.transportButtonSize
            ))
        }
        let footer = NSRect(
            x: 0,
            y: progressTop,
            width: width,
            height: targetTop + NotchStyle.transportButtonSize - progressTop
        )
        let height = footer.maxY + NotchStyle.verticalPadding

        return NotchCardLayout(
            size: NSSize(width: width, height: height),
            rows: rows,
            artwork: artwork,
            title: title,
            artist: artist,
            pinButton: pinButton,
            progressBar: progressBar,
            elapsedLabel: elapsedLabel,
            durationLabel: durationLabel,
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
