import Cocoa

/// Borderless, non-activating panel: it sits over the menu bar without taking
/// key focus or activating the app, so using it can never interrupt typing.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit scales the resize animation with the distance travelled, which
    /// for a hover expand is long enough to watch an empty card shrink. The
    /// card is a glance surface: keep every resize short.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        0.12
    }

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

    /// The controller owns pin state; the button renders it.
    var isPinned = false {
        didSet {
            guard oldValue != isPinned else { return }
            updatePinButton()
        }
    }

    /// The playback state the buttons render, so play/pause follows the player.
    var playback: PlaybackState = .none {
        didSet {
            guard oldValue != playback else { return }
            needsDisplay = true
        }
    }

    /// The track and its playhead. The card runs the clock forward itself, so
    /// the controller only has to ask for a redraw while it plays.
    var nowPlaying: NowPlaying? {
        didSet {
            guard oldValue != nowPlaying else { return }
            needsDisplay = true
        }
    }

    /// The one geometry of the expanded card: header, rows, footer and size,
    /// all from `NotchCardLayout`. Drawing and hit testing read this, never a
    /// second copy of the arithmetic.
    private var layout: NotchCardLayout?

    var onHoverChanged: ((Bool) -> Void)?
    var onClick: ((NSPoint) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    var onPinToggle: (() -> Void)?

    /// A native button provides mouse-up tracking, a tooltip and accessibility.
    let pinButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pinButton.setButtonType(.pushOnPushOff)
        pinButton.bezelStyle = .recessed
        pinButton.imagePosition = .imageOnly
        pinButton.imageScaling = .scaleProportionallyDown
        // The card stays black even when the rest of macOS uses light mode.
        pinButton.appearance = NSAppearance(named: .darkAqua)
        pinButton.contentTintColor = .white
        pinButton.refusesFirstResponder = true
        pinButton.target = self
        pinButton.action = #selector(togglePin(_:))
        pinButton.setAccessibilityLabel("Keep lyrics open")
        addSubview(pinButton)
        updatePinButton()
        updateLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updatePinButton() {
        pinButton.state = isPinned ? .on : .off
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pinButton.toolTip = isPinned ? "Unpin lyrics" : "Pin lyrics open"
    }

    @objc private func togglePin(_ sender: NSButton) {
        onPinToggle?()
    }

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

    /// Lays the expanded card out once per content, width or state change. All
    /// the arithmetic lives in `NotchCardLayout.make`, which the controller also
    /// uses to size the window.
    private func updateLayout() {
        layout = isExpanded
            ? NotchCardLayout.make(
                for: lyrics,
                width: bounds.width,
                contentTop: contentTop
            )
            : nil
        pinButton.isHidden = layout == nil
        if let layout {
            pinButton.frame = layout.pinButton
        }
    }

    /// Slot under a card-space point, or nil for a miss: padding, the artwork,
    /// the spacings between rows, the glass strip. A hit must be inside a row's
    /// own rect, so clicking a gap never seeks to a neighbouring line.
    func slot(at point: NSPoint) -> Int? {
        layout?.rows.first { $0.rect.contains(point) }?.slot
    }

    func line(at slot: Int) -> LyricLine? {
        let rows = windowRows
        return rows.indices.contains(slot) ? rows[slot] : nil
    }

    /// The button under a point, matched against the laid-out targets.
    func transportCommand(at point: NSPoint) -> TransportCommand? {
        layout?.transport.first { $0.rect.contains(point) }?.command
    }

    /// True anywhere inside the footer band (progress row and transports),
    /// including the gaps between targets. A click there must never pin or seek
    /// to a line.
    func isInFooter(_ point: NSPoint) -> Bool {
        layout?.footer.contains(point) ?? false
    }

    /// 0...1 along the progress track under a point, or nil when the point is
    /// not on the track (or there is no track to seek in).
    func progressFraction(at point: NSPoint) -> CGFloat? {
        guard let layout, let nowPlaying, nowPlaying.duration > 0,
              layout.progressHitArea.contains(point),
              layout.progressBar.width > 0 else { return nil }
        return min(1, max(0, (point.x - layout.progressBar.minX) / layout.progressBar.width))
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
        // One clock reading per frame, so the bar and the time always agree.
        let playhead = nowPlaying.flatMap { track -> (position: TimeInterval, duration: TimeInterval)? in
            guard track.duration > 0 else { return nil }
            return (track.position(at: Date(), playing: playback == .playing), track.duration)
        }
        if isExpanded {
            drawExpanded(playhead: playhead)
        } else {
            drawLine(lyrics?.current?.text, in: lineRect(), color: NotchStyle.currentColor, isCurrent: true)
            if let playhead {
                drawCollapsedProgress(fraction: CGFloat(playhead.position / playhead.duration))
            }
        }
    }

    /// A hairline along the pill's bottom edge, inside the text margins so it
    /// never meets the rounded corners.
    private func drawCollapsedProgress(fraction: CGFloat) {
        let track = NSRect(
            x: NotchStyle.horizontalPadding,
            y: bounds.maxY - NotchStyle.bottomPadding / 2 - NotchStyle.collapsedProgressHeight / 2,
            width: max(0, bounds.width - 2 * NotchStyle.horizontalPadding),
            height: NotchStyle.collapsedProgressHeight
        )
        drawProgress(
            in: track,
            fraction: fraction,
            track: NotchStyle.collapsedProgressTrackColor,
            fill: NotchStyle.collapsedProgressFillColor
        )
    }

    private func drawProgress(in rect: NSRect, fraction: CGFloat, track: NSColor, fill: NSColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = rect.height / 2
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let filled = NSRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, max(0, fraction)), height: rect.height)
        guard filled.width > 0 else { return }
        fill.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
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

    private func drawExpanded(playhead: (position: TimeInterval, duration: TimeInterval)?) {
        guard let layout else { return }
        drawArtwork(in: layout.artwork)
        drawHeader(layout)
        for row in layout.rows {
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
                drawLine(row.lines[0], in: row.rect, color: NotchStyle.contextLineColor(slot: row.slot))
            }
        }
        if let playhead {
            drawFooterProgress(layout, position: playhead.position, duration: playhead.duration)
        }
        drawTransport(layout.transport)
    }

    /// Title over artist, left-aligned against the cover. With no track the
    /// header still names the app's source, so a pinned empty card reads.
    private func drawHeader(_ layout: NotchCardLayout) {
        let title = nowPlaying.map { $0.title.isEmpty ? "Spotify" : $0.title } ?? "Spotify"
        let artist = nowPlaying?.artist ?? "Not playing"
        drawLabel(title, in: layout.title, font: NotchStyle.titleFont, color: NotchStyle.titleColor)
        drawLabel(artist, in: layout.artist, font: NotchStyle.artistFont, color: NotchStyle.artistColor)
    }

    /// Elapsed time, the track, the duration. Without a known duration the row
    /// stays empty rather than drawing a bar that can never move.
    private func drawFooterProgress(_ layout: NotchCardLayout, position: TimeInterval, duration: TimeInterval) {
        drawProgress(
            in: layout.progressBar,
            fraction: CGFloat(position / duration),
            track: NotchStyle.progressTrackColor,
            fill: NotchStyle.progressFillColor
        )
        let font = NotchStyle.timeFont
        let color = NotchStyle.timeColor
        drawLabel(NotchStyle.formatTime(position), in: layout.elapsedLabel, font: font, color: color)
        drawLabel(NotchStyle.formatTime(duration), in: layout.durationLabel, font: font, color: color, alignment: .right)
    }

    /// One tail-ellipsized line, vertically centred in `rect`.
    private func drawLabel(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        guard !text.isEmpty, rect.width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byClipping
        let height = ceil(font.ascender - font.descender)
        (NotchText.fitted(text, font: font, to: rect.width) as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }

    private func drawTransport(_ targets: [(command: TransportCommand, rect: NSRect)]) {
        for (command, rect) in targets {
            let pointSize = command == .playPause ? NotchStyle.primaryTransportGlyphSize : NotchStyle.transportGlyphSize
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NotchStyle.transportColor]))
            guard let symbol = NSImage(
                systemSymbolName: NotchStyle.transportSymbol(command, playback: playback),
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config) else { continue }
            let size = symbol.size
            symbol.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
    }

    private func drawArtwork(in rect: NSRect) {
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
            NotchStyle.artworkEdge.setStroke()
            box.lineWidth = 1
            box.stroke()
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
        // Edge on top of the cover: a dark sleeve still reads as a tile.
        NotchStyle.artworkEdge.setStroke()
        box.lineWidth = 1
        box.stroke()
    }

    private func drawLine(_ text: String?, in rect: NSRect, color: NSColor, isCurrent: Bool = false) {
        guard let text, !text.isEmpty, rect.width > 0 else { return }
        let font = isCurrent ? NotchStyle.currentFont : NotchStyle.lineFont
        drawText(
            text,
            in: rect,
            font: font,
            color: color,
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
