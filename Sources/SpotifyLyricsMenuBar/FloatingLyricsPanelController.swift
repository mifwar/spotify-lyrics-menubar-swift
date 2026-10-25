import Cocoa

private let panelDefaultWidth: CGFloat = 480
private let panelHorizontalPadding: CGFloat = 16
private let panelVerticalPadding: CGFloat = 12
private let panelLineHeight: CGFloat = 19
private let panelLineSpacing: CGFloat = 4
private let panelCornerRadius: CGFloat = 12
private let panelTopMargin: CGFloat = 8
// Height floor fits a single (current) line; shrinking the panel reveals
// fewer surrounding lines instead of squishing them.
private let panelMinSize = NSSize(width: 160, height: 43)
private let panelLineCount = LyricsWindow.radius * 2 + 1
private let panelDefaultContentSize = NSSize(
    width: 480,
    height: 12 * 2 + CGFloat(LyricsWindow.radius * 2 + 1) * 19 + CGFloat(LyricsWindow.radius * 2) * 4
)
private let currentLineFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
private let surroundingLineFont = NSFont.systemFont(ofSize: 13)
private let panelAutosaveName = "FloatingLyricsPanel"

private let cursorEdgeThickness: CGFloat = 8
private let scrollAnimationDuration: TimeInterval = 0.28
private let scrollAnimationKey = "lyricsScroll"

/// MiniLyrics-style fade: opacity falls off with distance from the center
/// line, so the current lyric dominates and outer lines melt into the panel.
/// ponytail: linear falloff, ease curve if it reads too sharp.
private func lineAlpha(forSlot slot: Int) -> CGFloat {
    let center = (panelLineCount - 1) / 2
    return 1.0 - CGFloat(abs(slot - center)) * 0.24
}

/// Content view that sets cursor feedback for the borderless panel: resize
/// cursors near the edges, an open hand over the draggable interior.
/// Borderless windows get no automatic cursor management from AppKit.
private final class FloatingPanelContentView: NSView {
    override func resetCursorRects() {
        let b = bounds
        let t = cursorEdgeThickness
        // Non-overlapping bands: vertical strips full height, horizontal
        // strips between them, draggable interior in the middle.
        addCursorRect(NSRect(x: b.minX, y: b.minY, width: t, height: b.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.maxX - t, y: b.minY, width: t, height: b.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: b.minX + t, y: b.minY, width: b.width - 2 * t, height: t), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: b.minX + t, y: b.maxY - t, width: b.width - 2 * t, height: t), cursor: .resizeUpDown)
        addCursorRect(b.insetBy(dx: t, dy: t), cursor: .openHand)
    }
}

/// Borderless, non-activating overlay showing the current lyric line with its
/// surrounding lines (same window as the popover). Owns the panel, content,
/// sizing, positioning and show/hide. All lyric state lives in the app
/// delegate; this just renders the lines it is given.
final class FloatingLyricsPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let stack = NSStackView()
    private var labels: [NSTextField] = []
    private var lastWindow: LyricsWindow?
    private var lastIsPlaceholder = false
    private var maxVisibleLines = panelLineCount

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelDefaultWidth, height: 180),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.title = "Floating Lyrics"
        panel.minSize = panelMinSize
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: panelDefaultContentSize.height)

        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = panelCornerRadius
        material.layer?.masksToBounds = true
        material.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = panelLineSpacing
        stack.wantsLayer = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<panelLineCount {
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.font = surroundingLineFont
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            labels.append(label)
            stack.addArrangedSubview(label)
        }
        labels.first?.setAccessibilityLabel("Floating lyrics")

        let content = FloatingPanelContentView()
        content.addSubview(material)
        material.addSubview(stack)
        panel.contentView = content

        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            material.topAnchor.constraint(equalTo: content.topAnchor),
            material.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: panelHorizontalPadding),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -panelHorizontalPadding),
            stack.topAnchor.constraint(equalTo: material.topAnchor, constant: panelVerticalPadding),
            stack.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -panelVerticalPadding),
        ])

        super.init()
        panel.delegate = self

        // Restore the last frame (clamped to currently connected screens by
        // AppKit), or fall back to a default size at top-center, below the
        // menu bar.
        if !panel.setFrameUsingName(panelAutosaveName) {
            panel.setContentSize(panelDefaultContentSize)
            moveToDefaultPosition()
        } else {
            enforceMinimumSize()
        }
        panel.setFrameAutosaveName(panelAutosaveName)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Shows the panel if hidden and updates the displayed lines. Main thread only.
    func update(_ presentation: LyricsPresentation) {
        guard let window = presentation.window else {
            hide()
            return
        }
        let previousCurrent = lastWindow?.current?.text
        let wasPlaceholder = lastIsPlaceholder
        let wasVisible = panel.isVisible
        lastWindow = window
        lastIsPlaceholder = presentation.isPlaceholder
        renderLines()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        scrollToCurrentLine(from: previousCurrent, wasPlaceholder: wasPlaceholder, wasVisible: wasVisible)
    }

    /// MiniLyrics-style roll: when the current line moves by exactly one line,
    /// start the new content shifted one line and animate it back, so lines
    /// slide instead of jumping. First show, seek, resize and placeholder
    /// changes snap.
    private func scrollToCurrentLine(from previousCurrent: String?, wasPlaceholder: Bool, wasVisible: Bool) {
        guard wasVisible, !lastIsPlaceholder, !wasPlaceholder,
              let previous = previousCurrent,
              let window = lastWindow,
              window.current?.text != previous
        else {
            cancelScrollAnimation()
            return
        }
        let stride = panelLineHeight + panelLineSpacing
        // AppKit's backing layer may or may not be geometry-flipped; translate
        // in whichever direction reads as "down" on this layer.
        let down: CGFloat = (stack.layer?.isGeometryFlipped ?? stack.isFlipped) ? 1 : -1
        // Seamless only when the previous current line is now exactly one slot
        // over; anything further is a seek and snaps.
        let rows = window.rows(radius: LyricsWindow.radius)
        let center = LyricsWindow.radius
        let before = rows[center - 1]?.text
        let after = rows[center + 1]?.text
        let offset: CGFloat
        if before == previous {
            offset = -down * stride // advanced: new lines enter from below
        } else if after == previous {
            offset = down * stride // retreated: new lines enter from above
        } else {
            cancelScrollAnimation()
            return
        }
        animateScroll(offset: offset)
    }

    private func animateScroll(offset: CGFloat) {
        guard let layer = stack.layer else { return }
        layer.removeAnimation(forKey: scrollAnimationKey)
        layer.transform = CATransform3DIdentity
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, offset, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = scrollAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: scrollAnimationKey)
    }

    private func cancelScrollAnimation() {
        stack.layer?.removeAnimation(forKey: scrollAnimationKey)
        stack.layer?.transform = CATransform3DIdentity
    }

    func windowDidResize(_ notification: Notification) {
        guard let content = panel.contentView else { return }
        let available = content.bounds.height - panelVerticalPadding * 2
        var n = Int((available + panelLineSpacing) / (panelLineHeight + panelLineSpacing))
        n = min(panelLineCount, max(1, n))
        if n % 2 == 0 { n -= 1 }
        n = max(1, n)
        if n != maxVisibleLines {
            maxVisibleLines = n
            cancelScrollAnimation()
            renderLines()
        }
    }

    /// Maps the window's slots onto the label slots, hiding outer pairs that
    /// don't fit the panel's current height.
    private func renderLines() {
        guard let window = lastWindow else {
            labels.forEach { $0.isHidden = true }
            return
        }
        let rows = window.rows(radius: LyricsWindow.radius)
        let half = maxVisibleLines / 2
        let center = LyricsWindow.radius
        for (i, label) in labels.enumerated() {
            let withinHeight = i >= center - half && i <= center + half
            guard withinHeight, let line = rows[i], !line.text.isEmpty else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.stringValue = line.text
            if i == center {
                label.font = currentLineFont
                label.textColor = lastIsPlaceholder ? .secondaryLabelColor : .labelColor
            } else {
                label.font = surroundingLineFont
                label.textColor = .labelColor.withAlphaComponent(lineAlpha(forSlot: i) * 0.8)
            }
        }
    }

    func hide() {
        cancelScrollAnimation()
        panel.orderOut(nil)
    }

    @objc private func screenParametersChanged() {
        clampToVisibleScreen()
    }

    /// Frames saved by older single-line versions are too short for the
    /// multi-line layout; grow them back to the default, keeping position.
    private func enforceMinimumSize() {
        var frame = panel.frame
        let size = panelDefaultContentSize
        guard frame.height < panelMinSize.height || frame.width < panelMinSize.width else { return }
        let topCenter = NSPoint(x: frame.midX, y: frame.maxY)
        frame.size = NSSize(width: max(frame.width, size.width), height: max(frame.height, size.height))
        frame.origin.x = topCenter.x - frame.width / 2
        frame.origin.y = topCenter.y - frame.height
        panel.setFrame(frame, display: false)
    }

    private func moveToDefaultPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - panelTopMargin
        ))
    }

    private func clampToVisibleScreen() {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
        }
    }
}
