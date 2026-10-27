import Cocoa

/// Borderless, non-activating panel: it sits over the menu bar without taking
/// key focus or activating the app, so using it can never interrupt typing.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make(card: NotchCardView) -> NotchPanel {
        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: NotchStyle.maxWidth, height: NotchStyle.collapsedLineHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // .statusBar is the first level above the menu bar; .popUpMenu would
        // also float over open menus, which this hint should not.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = false
        panel.contentView = card
        return panel
    }
}

/// The notch card. Drawing everything keeps one source of truth for layout, so a
/// click can be mapped to the row under the cursor. The view knows only whether
/// it is expanded — what the surface is *doing* is the controller's business.
final class NotchCardView: NSView {
    var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            updateLayout()
            needsDisplay = true
        }
    }

    /// Distance from the card's top to the first drawable row: the hardware
    /// cutout's height, or zero on a simulated notch.
    var contentTop: CGFloat = 0 {
        didSet {
            guard oldValue != contentTop else { return }
            updateLayout()
            needsDisplay = true
        }
    }

    var isSimulated = true { didSet { if oldValue != isSimulated { needsDisplay = true } } }

    /// One drawable expanded row. The current row can be taller than the others
    /// because its text wraps, so rows are laid out once and then both drawn and
    /// hit-tested from these rects — never from a pitch.
    private struct Row {
        let slot: Int
        let rect: NSRect
        let lines: [String]
    }

    private var rowLayout: [Row] = []
    private var artworkRect: NSRect = .zero

    var onHoverChanged: ((Bool) -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?

    /// nil while the surface is a dot: there is nothing to say right now.
    private var lyrics: LyricsWindow?
    private var artwork: NSImage?
    private var trackingArea: NSTrackingArea?

    /// Top-down drawing: the card hangs from the notch, so rows count downward.
    override var isFlipped: Bool { true }

    /// Content arrives on every lyric tick; only a real change may redraw.
    func setContent(lyrics newLyrics: LyricsWindow?, artwork newArtwork: NSImage?) {
        guard newArtwork !== artwork || !hasSameLines(as: newLyrics) else { return }
        lyrics = newLyrics
        artwork = newArtwork
        updateLayout()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayout()
    }

    private func hasSameLines(as other: LyricsWindow?) -> Bool {
        guard let other, let lyrics else { return other == nil && lyrics == nil }
        guard other.currentIndex == lyrics.currentIndex, other.lines.count == lyrics.lines.count else {
            return false
        }
        return zip(other.lines, lyrics.lines).allSatisfy { pair in
            pair.0?.text == pair.1?.text && pair.0?.timestamp == pair.1?.timestamp
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil))
    }

    // MARK: - Layout

    /// Lays the expanded rows out once per content, width or state change. The
    /// collapsed card and the dot need no rows.
    private func updateLayout() {
        guard isExpanded else {
            rowLayout = []
            artworkRect = .zero
            return
        }
        let columnX = NotchStyle.horizontalPadding + NotchStyle.artworkSize + NotchStyle.artworkGap
        let columnWidth = NotchStyle.textColumnWidth(for: bounds.width)
        var y = contentTop + NotchStyle.verticalPadding
        var rows: [Row] = []
        for slot in 0...(NotchStyle.rowRadius * 2) {
            let line = line(at: slot)
            let isCurrent = slot == NotchStyle.rowRadius
            let lines: [String]
            if isCurrent {
                lines = NotchText.wrapped(
                    line?.text ?? "",
                    font: NotchStyle.currentFont,
                    to: columnWidth,
                    maxRows: NotchStyle.currentLineRows
                )
            } else {
                lines = line.map { [$0.text] } ?? []
            }
            let height = NotchStyle.rowHeight(slot: slot, currentLineCount: lines.count)
            rows.append(Row(
                slot: slot,
                rect: NSRect(x: columnX, y: y, width: columnWidth, height: height),
                lines: lines
            ))
            y += height + NotchStyle.lineSpacing
        }
        rowLayout = rows

        let top = rows.first?.rect.minY ?? (contentTop + NotchStyle.verticalPadding)
        let bottom = rows.last?.rect.maxY ?? top
        artworkRect = NSRect(
            x: NotchStyle.horizontalPadding,
            y: (top + bottom) / 2 - NotchStyle.artworkSize / 2,
            width: NotchStyle.artworkSize,
            height: NotchStyle.artworkSize
        )
    }

    /// Slot under a card-space point, or nil for a miss: padding, the artwork,
    /// the spacings between rows, the glass strip. A hit must be inside a row's
    /// own rect, so clicking a gap never seeks to a neighbouring line.
    func slot(at point: NSPoint) -> Int? {
        guard isExpanded else { return nil }
        return rowLayout.first { $0.rect.contains(point) }?.slot
    }

    func line(at slot: Int) -> LyricLine? {
        let rows = windowRows
        return rows.indices.contains(slot) ? rows[slot] : nil
    }

    // MARK: - Drawing

    /// The slots within the visible radius, current line in the middle.
    private var windowRows: [LyricLine?] {
        lyrics?.rows(radius: NotchStyle.rowRadius) ?? []
    }

    override func draw(_ dirtyRect: NSRect) {
        let rows = windowRows
        if !isExpanded, rows.isEmpty {
            drawDot()
            return
        }
        drawCard()
        if isExpanded {
            drawExpanded()
        } else {
            drawLine(lyrics?.current?.text, in: lineRect(), isCurrent: true)
        }
    }

    private func drawCard() {
        let radius = min(NotchStyle.cornerRadius, min(bounds.width, bounds.height) / 2)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard !isSimulated else { return }
        // Flush with the screen edge the top corners are square, so the card
        // merges with the hardware cutout instead of drawing round wedges next
        // to it. The bottom corners stay rounded.
        NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: radius)).fill()
    }

    private func drawDot() {
        // A black puck keeps the dot readable on a light and on a dark menu bar.
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: bounds.midX - 10,
            y: bounds.midY - 10,
            width: 20,
            height: 20
        )).fill()
        NotchStyle.dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: bounds.midX - NotchStyle.dotDiameter / 2,
            y: bounds.midY - NotchStyle.dotDiameter / 2,
            width: NotchStyle.dotDiameter,
            height: NotchStyle.dotDiameter
        )).fill()
    }

    private func lineRect() -> NSRect {
        NSRect(
            x: NotchStyle.horizontalPadding,
            y: contentTop,
            width: max(0, bounds.width - 2 * NotchStyle.horizontalPadding),
            height: NotchStyle.collapsedLineHeight
        )
    }

    private func drawExpanded() {
        drawArtwork()
        for row in rowLayout {
            let isCurrent = row.slot == NotchStyle.rowRadius
            guard !row.lines.isEmpty else { continue }
            if isCurrent {
                // Wrapped rows are already exact; drawing them back through
                // `fitted` would re-truncate what the wrap just made fit.
                let font = NotchStyle.currentFont
                let lineHeight = ceil(font.ascender - font.descender)
                for (index, text) in row.lines.enumerated() {
                    let y = row.rect.minY + CGFloat(index) * (NotchStyle.lineHeight + NotchStyle.wrappedLineSpacing)
                    drawText(
                        text,
                        in: NSRect(x: row.rect.minX, y: y, width: row.rect.width, height: NotchStyle.lineHeight),
                        font: font,
                        color: NotchStyle.currentColor,
                        fitted: false,
                        visualLineHeight: lineHeight
                    )
                }
            } else {
                drawLine(row.lines[0], in: row.rect, isCurrent: false)
            }
        }
    }

    private func drawArtwork() {
        let rect = artworkRect
        let box = NSBezierPath(
            roundedRect: rect,
            xRadius: NotchStyle.artworkCornerRadius,
            yRadius: NotchStyle.artworkCornerRadius
        )
        NotchStyle.artworkFill.setFill()
        box.fill()

        guard let artwork else {
            let glyph = "♪" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NotchStyle.artworkFont,
                .foregroundColor: NotchStyle.artworkGlyphColor,
            ]
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                withAttributes: attributes
            )
            return
        }

        // Aspect-fill the square slot, clipped to its rounded corners, so any
        // cover shape fills it without distortion.
        let scale = max(rect.width / artwork.size.width, rect.height / artwork.size.height)
        let size = NSSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        box.addClip()
        artwork.draw(in: NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLine(_ text: String?, in rect: NSRect, isCurrent: Bool) {
        guard let text, !text.isEmpty, rect.width > 0 else { return }
        let font = isCurrent ? NotchStyle.currentFont : NotchStyle.lineFont
        drawText(
            text,
            in: rect,
            font: font,
            color: isCurrent ? NotchStyle.currentColor : NotchStyle.lineColor,
            fitted: true,
            visualLineHeight: ceil(font.ascender - font.descender)
        )
    }

    /// Centres one visual line in `rect`. `fitted` tail-ellipsizes to the rect's
    /// width; wrapped rows have already been split and pass it off.
    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        fitted shouldFit: Bool,
        visualLineHeight: CGFloat
    ) {
        guard !text.isEmpty, rect.width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let display = shouldFit ? NotchText.fitted(text, font: font, to: rect.width) : text
        (display as NSString).draw(
            in: NSRect(
                x: rect.minX,
                y: rect.midY - visualLineHeight / 2,
                width: rect.width,
                height: visualLineHeight
            ),
            withAttributes: attributes
        )
    }
}
