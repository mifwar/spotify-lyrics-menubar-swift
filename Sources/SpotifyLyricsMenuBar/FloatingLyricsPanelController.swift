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
private let panelLineCount = 7
private let panelDefaultContentSize = NSSize(
    width: 480,
    height: 12 * 2 + CGFloat(7) * 19 + CGFloat(6) * 4
)
private let currentLineFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
private let surroundingLineFont = NSFont.systemFont(ofSize: 13)
private let panelAutosaveName = "FloatingLyricsPanel"

private let cursorEdgeThickness: CGFloat = 8

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
    private var labels: [NSTextField] = []
    private var lastLines: [(text: String, isCurrent: Bool)] = []
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

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = panelLineSpacing
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
    func update(lines: [(text: String, isCurrent: Bool)], isPlaceholder: Bool) {
        lastLines = lines
        lastIsPlaceholder = isPlaceholder
        renderLines()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
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
            renderLines()
        }
    }

    /// Maps the incoming lines onto the label slots, centered on the current
    /// line, hiding outer pairs that don't fit the panel's current height.
    private func renderLines() {
        let base = max(0, (panelLineCount - lastLines.count) / 2)
        let half = maxVisibleLines / 2
        for (i, label) in labels.enumerated() {
            let withinHeight = i >= 3 - half && i <= 3 + half
            let source = i - base
            guard withinHeight, source >= 0, source < lastLines.count, !lastLines[source].text.isEmpty else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.stringValue = lastLines[source].text
            if lastLines[source].isCurrent {
                label.font = currentLineFont
                label.textColor = lastIsPlaceholder ? .secondaryLabelColor : .labelColor
            } else {
                label.font = surroundingLineFont
                label.textColor = .labelColor.withAlphaComponent(lineAlpha(forSlot: i) * 0.8)
            }
        }
    }

    func hide() {
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
