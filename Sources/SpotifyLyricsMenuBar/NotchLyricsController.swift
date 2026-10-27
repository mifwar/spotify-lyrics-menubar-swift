import Cocoa

/// What the surface is doing right now. Derived from the current inputs on every
/// change and never patched by hand, so pin, hover, pause and obscuring cannot
/// disagree about it.
enum Presence {
    case hidden, dot, collapsed, expanded
}

/// Draws the current lyric on the notch, expands while hovered or pinned, and
/// shrinks to a dot when there is nothing to say. Main thread only, like every
/// AppKit surface.
final class NotchLyricsController: NSObject {
    /// Called with the timestamp of the line that was clicked.
    var onSeek: ((TimeInterval) -> Void)?
    /// Called with screen coordinates when the card or the dot asks for the menu.
    var onMenuRequest: ((NSPoint) -> Void)?

    private(set) var isPinned = false

    private static let dwellDelay: TimeInterval = 0.15
    private static let graceDelay: TimeInterval = 0.4
    private static let watchdogInterval: TimeInterval = 0.25
    private static let idleDelay: TimeInterval = 3
    private static let idlePollInterval: TimeInterval = 0.5

    private let panel: NotchPanel
    private let card: NotchCardView

    private var presentation = LyricsPresentation()
    private var geometry: NotchGeometry?
    private var currentPresence: Presence = .hidden
    private var isObscured = false
    /// True once the pointer has rested for the dwell delay; the grace delay
    /// keeps it true on the way out, so "hovered" means settled, not recent.
    private var isHovered = false
    /// When Spotify became paused; survives obscuring and re-presenting.
    private var pausedAt: Date?

    private var hoverTimer: Timer?
    private var watchdogTimer: Timer?
    private var idleTimer: Timer?

    override init() {
        let card = NotchCardView(frame: .zero)
        panel = NotchPanel.make(card: card)
        self.card = card
        super.init()

        card.onHoverChanged = { [weak self] hovered in self?.setHovered(hovered) }
        card.onClick = { [weak self] point in self?.click(at: point) }
        card.onRightClick = { [weak self] point in self?.requestMenu(at: point) }
    }

    deinit {
        stopTimers()
    }

    // MARK: - Notify

    /// Main thread only. `isObscured` hides the window (a fullscreen app is in
    /// front) without touching the pin, the hover state or the pause clock.
    func present(_ presentation: LyricsPresentation, geometry: NotchGeometry, isObscured: Bool = false) {
        let previousPlayback = self.presentation.playback
        self.presentation = presentation
        self.geometry = geometry
        self.isObscured = isObscured

        if presentation.playback == .paused {
            if previousPlayback != .paused || pausedAt == nil {
                pausedAt = Date()
            }
        } else {
            pausedAt = nil
        }
        apply(resolvedPresence())
    }

    /// Stops rendering entirely (leaving notch mode). An obscure is different:
    /// that only takes the window off screen and keeps every input.
    func dismiss() {
        currentPresence = .hidden
        stopTimers()
        panel.orderOut(nil)
        isPinned = false
        isHovered = false
        pausedAt = nil
    }

    // MARK: - Presence policy

    /// The single decision: what should the surface be showing? Every branch
    /// reads facts of the moment; none reads the previous presence.
    static func presence(
        playback: PlaybackState,
        hasLine: Bool,
        isPinned: Bool,
        isHovered: Bool,
        isObscured: Bool,
        pausedFor: TimeInterval?
    ) -> Presence {
        // Obscured outranks everything: the window goes away, the inputs stay.
        if isObscured { return .hidden }
        // Pin outranks playback and hover: the user asked to keep it open.
        if isPinned { return .expanded }
        switch playback {
        case .none:
            // The status item is hidden in notch mode, so the dot is the only
            // way back to the menu when Spotify is closed.
            return .dot
        case .paused:
            guard hasLine else { return .dot }
            if !isHovered, (pausedFor ?? 0) >= idleDelay { return .dot }
            return isHovered ? .expanded : .collapsed
        case .playing:
            guard hasLine else { return .dot }
            return isHovered ? .expanded : .collapsed
        }
    }

    private func resolvedPresence() -> Presence {
        let line = presentation.window?.current
        return Self.presence(
            playback: presentation.playback,
            hasLine: line?.text.isEmpty == false,
            isPinned: isPinned,
            isHovered: isHovered,
            isObscured: isObscured,
            pausedFor: pausedAt.map { Date().timeIntervalSince($0) }
        )
    }

    /// The only place that touches the card, the clocks and the window. Called
    /// after every input change, including the timers, so no transition patches
    /// state by hand.
    private func apply(_ target: Presence) {
        currentPresence = target

        card.isExpanded = target == .expanded
        if let geometry {
            card.isSimulated = geometry.isSimulated
            card.contentTop = NotchStyle.contentTop(for: geometry)
        }
        card.setContent(lyrics: target == .dot ? nil : presentation.window, artwork: presentation.artwork)

        setTimers(for: target)
        place(target)
    }

    private func place(_ target: Presence) {
        guard target != .hidden else {
            if panel.isVisible {
                panel.orderOut(nil)
            }
            return
        }
        guard let targetFrame = frame(for: target) else { return }
        guard !panel.isVisible || panel.frame != targetFrame else { return }

        let wasVisible = panel.isVisible
        // Installing the frame before it animates makes the hit area final, so a
        // stationary cursor cannot fall outside the panel mid-resize.
        panel.setFrame(targetFrame, display: wasVisible, animate: wasVisible)
        if !wasVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Screen rect for a presence. Every form hangs from the notch: same centre,
    /// top edge at the screen top, except the dot which sits in the content row.
    private func frame(for presence: Presence) -> NSRect? {
        guard let geometry else { return nil }
        let notch = geometry.notchFrame
        let currentLine = presentation.window?.current?.text ?? ""
        let size: NSSize
        switch presence {
        case .expanded:
            size = NotchStyle.expandedSize(for: geometry, currentLine: currentLine)
        case .collapsed:
            size = NotchStyle.collapsedSize(for: geometry, text: currentLine)
        case .dot:
            size = NSSize(width: NotchStyle.dotHitSize, height: NotchStyle.dotHitSize)
        case .hidden:
            return nil
        }
        let top: CGFloat
        if presence == .dot {
            let contentCenter = notch.maxY - NotchStyle.contentTop(for: geometry) - NotchStyle.collapsedLineHeight / 2
            top = contentCenter + size.height / 2
        } else {
            top = notch.maxY
        }
        return NSRect(x: notch.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    // MARK: - Clocks

    /// Which clocks run, as a table: the idle clock only while a paused line can
    /// still become a dot, the watchdog only while the card is open and unpinned.
    private func setTimers(for presence: Presence) {
        let watchdog = presence == .expanded && !isPinned ? Self.watchdogInterval : nil
        watchdogTimer = clock(watchdogTimer, every: watchdog) { $0.watchdogTick() }
        let idle = presence == .collapsed && presentation.playback == .paused ? Self.idlePollInterval : nil
        idleTimer = clock(idleTimer, every: idle) { $0.idleTick() }
    }

    /// Starts, keeps or stops one repeating clock, so no transition can leave a
    /// timer running or forget to cancel one.
    private func clock(
        _ timer: Timer?,
        every interval: TimeInterval?,
        _ tick: @escaping (NotchLyricsController) -> Void
    ) -> Timer? {
        guard let interval else {
            timer?.invalidate()
            return nil
        }
        guard timer == nil else { return timer }
        return schedule(after: interval, repeating: true) { [weak self] in
            guard let self else { return }
            tick(self)
        }
    }

    private func idleTick() {
        apply(resolvedPresence())
    }

    /// Backs up the tracking area: a card that grows under a still cursor does
    /// not always produce a mouseExited, so ask the pointer where it is.
    private func watchdogTick() {
        guard hoverTimer == nil, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        setHovered(false)
    }

    /// The card view reports the pointer entering or leaving its bounds. Dwell
    /// and grace live here only because they are the pointer's own clocks.
    func setHovered(_ hovered: Bool) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard hovered != isHovered else { return }

        if hovered {
            hoverTimer = schedule(after: Self.dwellDelay) { [weak self] in
                guard let self else { return }
                self.hoverTimer = nil
                self.isHovered = true
                self.apply(self.resolvedPresence())
            }
        } else {
            hoverTimer = schedule(after: Self.graceDelay) { [weak self] in
                self?.endHoverIfPointerLeft()
            }
        }
    }

    /// The grace re-verifies the pointer: it may have come back while the timer
    /// ran, and the exit may have been about a frame that has since moved.
    private func endHoverIfPointerLeft() {
        hoverTimer = nil
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        isHovered = false
        apply(resolvedPresence())
    }

    // MARK: - Clicks

    /// A click in card coordinates. A dot opens the menu: the status item is
    /// hidden in notch mode, so it is the only way back. The current line or
    /// padding pins, another line seeks when the timing is exact.
    func click(at point: NSPoint) {
        guard panel.isVisible else { return }
        if currentPresence == .dot {
            requestMenu(at: point)
            return
        }
        guard currentPresence == .expanded,
              let slot = card.slot(at: point),
              let line = card.line(at: slot),
              !line.text.isEmpty,
              slot != NotchStyle.rowRadius
        else {
            isPinned.toggle()
            apply(resolvedPresence())
            return
        }
        guard presentation.isTimingExact, line.timestamp > 0 else { return }
        onSeek?(line.timestamp)
    }

    private func requestMenu(at point: NSPoint) {
        onMenuRequest?(screenPoint(for: point))
    }

    private func screenPoint(for point: NSPoint) -> NSPoint {
        panel.convertPoint(toScreen: card.convert(point, to: nil))
    }

    // MARK: - Plumbing

    private func schedule(after delay: TimeInterval, repeating: Bool = false, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: repeating) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func stopTimers() {
        hoverTimer?.invalidate()
        watchdogTimer?.invalidate()
        idleTimer?.invalidate()
        hoverTimer = nil
        watchdogTimer = nil
        idleTimer = nil
    }
}
