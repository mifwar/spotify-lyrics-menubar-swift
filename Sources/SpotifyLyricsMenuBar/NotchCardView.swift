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
    var isExpanded = false { didSet { if oldValue != isExpanded { needsDisplay = true } } }
    /// Distance from the card's top to the first drawable row: the hardware
    /// cutout's height, or zero on a simulated notch.
    var contentTop: CGFloat = 0 { didSet { if oldValue != contentTop { needsDisplay = true } } }
    var isSimulated = true { didSet { if oldValue != isSimulated { needsDisplay = true } } }

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
        needsDisplay = true
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

    // MARK: - Hit testing

    /// Column the lyric rows occupy, beside the artwork.
    private var textColumn: NSRect {
        let left = NotchStyle.horizontalPadding + NotchStyle.artworkSize + NotchStyle.artworkGap
        return NSRect(
            x: left,
            y: contentTop + NotchStyle.verticalPadding,
            width: max(0, bounds.width - left - NotchStyle.horizontalPadding),
            height: NotchStyle.rowsHeight
        )
    }

    /// Slot under a card-space point. nil means padding (artwork, gaps, margins,
    /// the glass strip), which pins instead of seeking.
    func slot(at point: NSPoint) -> Int? {
        guard isExpanded, textColumn.contains(point) else { return nil }
        let pitch = NotchStyle.lineHeight + NotchStyle.lineSpacing
        let offset = point.y - textColumn.minY
        let slot = Int(offset / pitch)
        guard slot >= 0, slot <= NotchStyle.rowRadius * 2 else { return nil }
        guard offset - CGFloat(slot) * pitch <= NotchStyle.lineHeight else { return nil }
        return slot
    }

    func line(at slot: Int) -> LyricLine? {
        rows.indices.contains(slot) ? rows[slot] : nil
    }

    // MARK: - Drawing

    /// The slots within the visible radius, current line in the middle.
    private var rows: [LyricLine?] {
        lyrics?.rows(radius: NotchStyle.rowRadius) ?? []
    }

    override func draw(_ dirtyRect: NSRect) {
        let rows = rows
        if !isExpanded, rows.isEmpty {
            drawDot()
            return
        }
        drawCard()
        if isExpanded {
            drawRows(rows)
        } else {
            drawLine(lyrics?.current, in: lineRect(), isCurrent: true)
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

    private func drawRows(_ rows: [LyricLine?]) {
        drawArtwork()
        let pitch = NotchStyle.lineHeight + NotchStyle.lineSpacing
        for (slot, line) in rows.enumerated() {
            let isCurrent = slot == NotchStyle.rowRadius
            drawLine(
                line,
                in: NSRect(
                    x: textColumn.minX,
                    y: textColumn.minY + CGFloat(slot) * pitch,
                    width: textColumn.width,
                    height: NotchStyle.lineHeight
                ),
                isCurrent: isCurrent
            )
        }
    }

    private func drawArtwork() {
        let rect = NSRect(
            x: NotchStyle.horizontalPadding,
            y: textColumn.midY - NotchStyle.artworkSize / 2,
            width: NotchStyle.artworkSize,
            height: NotchStyle.artworkSize
        )
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

    private func drawLine(_ line: LyricLine?, in rect: NSRect, isCurrent: Bool) {
        guard let text = line?.text, !text.isEmpty, rect.width > 0 else { return }
        let font = isCurrent ? NotchStyle.currentFont : NotchStyle.lineFont
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isCurrent ? NotchStyle.currentColor : NotchStyle.lineColor,
            .paragraphStyle: style,
        ]
        let lineHeight = ceil(font.ascender - font.descender)
        (NotchText.fitted(text, font: font, to: rect.width) as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.midY - lineHeight / 2, width: rect.width, height: lineHeight),
            withAttributes: attributes
        )
    }
}
