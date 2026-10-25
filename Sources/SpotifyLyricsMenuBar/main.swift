import Cocoa
import Foundation

private let displayModeDefaultsKey = "lyricsDisplayMode"
private let notchDisplayDefaultsKey = "notchDisplayID"
private let showOverFullscreenDefaultsKey = "showOverFullscreenApps"

private enum LyricsDisplayMode: String {
    case menuBar
    case floating
    case notch
}

private final class SpotifyLyricsApp: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let nowPlayingItem = NSMenuItem(title: "Now Playing: -", action: nil, keyEquivalent: "")
    private let offsetItem = NSMenuItem(title: "Offset: 0.0s", action: nil, keyEquivalent: "")
    private let plainLyricsItem = NSMenuItem(title: "Use Plain Lyrics", action: #selector(togglePlainLyrics), keyEquivalent: "p")
    private let menuBarModeItem = NSMenuItem(title: "Menu Bar", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
    private let floatingModeItem = NSMenuItem(title: "Floating", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
    private let notchModeItem = NSMenuItem(title: "Notch", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
    private let displayMenuItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
    private let showOverFullscreenItem = NSMenuItem(title: "Show over Fullscreen Apps", action: #selector(toggleShowOverFullscreenApps), keyEquivalent: "")
    private lazy var floatingPanelController = FloatingLyricsPanelController()
    private lazy var notchController = NotchLyricsController()
    private let spotifyClient = SpotifyClient()
    private let lyricsCache = LyricsCache()
    private lazy var lrclibClient = LRCLibClient(cache: lyricsCache)
    /// Cached window-server answer: only a mode, display, checkbox or space
    /// change can alter it, not a lyric tick.
    private var isFullscreenBlocking = false
    /// Last rendered presentation, replayed when the display mode changes.
    /// Main thread only.
    private var presentation = LyricsPresentation()
    private var currentStatusTitle = placeholder

    private lazy var engine: LyricsEngine = {
        let engine = LyricsEngine(client: spotifyClient, lrclib: lrclibClient, cache: lyricsCache)
        engine.onPresentation = { [weak self] presentation in
            self?.apply(presentation)
        }
        engine.onTrackChanged = { [weak self] state in
            self?.nowPlayingItem.title = state.map { "♪ \($0.track) — \($0.artist)" } ?? "Now Playing: -"
        }
        engine.onOffsetChanged = { [weak self] in
            self?.updateOffsetMenuItem()
        }
        engine.onPlainLyricsChanged = { [weak self] in
            self?.updatePlainLyricsMenuItem()
        }
        engine.onTrackCleared = { [weak self] in
            self?.popover.performClose(nil)
        }
        return engine
    }()

    private let popover = NSPopover()
    private let lyricsPanelVC = LyricsPanelViewController()
    private var statusMenu: NSMenu!

    private var displayMode: LyricsDisplayMode {
        LyricsDisplayMode(rawValue: UserDefaults.standard.string(forKey: displayModeDefaultsKey) ?? "") ?? .menuBar
    }

    private var notchDisplayOverride: String? {
        UserDefaults.standard.string(forKey: notchDisplayDefaultsKey)
    }

    private var showOverFullscreenApps: Bool {
        UserDefaults.standard.bool(forKey: showOverFullscreenDefaultsKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Before the first render: launching in notch mode with a fullscreen app
        // in front must not flash the pill on.
        refresh()
        configureStatusButton()

        lyricsPanelVC.preferredContentSize = NSSize(width: lyricsPanelWidth, height: lyricsPanelMinHeight)
        popover.contentViewController = lyricsPanelVC
        popover.contentSize = lyricsPanelVC.preferredContentSize
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Refresh Lyrics", action: #selector(forceRefresh), keyEquivalent: "r"))
        menu.addItem(menuItem(title: "Open LRCLib Search", action: #selector(openLRCLibSearch), keyEquivalent: "s"))
        menu.addItem(menuItem(title: "Import Lyrics from Clipboard", action: #selector(importLyricsFromClipboard), keyEquivalent: "i"))
        menu.addItem(.separator())
        menu.addItem(plainLyricsItem)
        menu.addItem(.separator())
        let displayModeItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
        let displayModeSubmenu = NSMenu()
        menuBarModeItem.target = self
        menuBarModeItem.representedObject = LyricsDisplayMode.menuBar.rawValue
        floatingModeItem.target = self
        floatingModeItem.representedObject = LyricsDisplayMode.floating.rawValue
        notchModeItem.target = self
        notchModeItem.representedObject = LyricsDisplayMode.notch.rawValue
        displayModeSubmenu.addItem(menuBarModeItem)
        displayModeSubmenu.addItem(floatingModeItem)
        displayModeSubmenu.addItem(notchModeItem)
        displayModeItem.submenu = displayModeSubmenu
        menu.addItem(displayModeItem)
        // Only meaningful for the notch surface, so hidden in the other modes;
        // the submenu is rebuilt whenever the menu state refreshes.
        displayMenuItem.submenu = NSMenu()
        menu.addItem(displayMenuItem)
        showOverFullscreenItem.target = self
        menu.addItem(showOverFullscreenItem)
        menu.addItem(.separator())
        menu.addItem(offsetItem)
        menu.addItem(menuItem(title: "Lyrics Later (-0.5s)", action: #selector(decreaseOffset), keyEquivalent: "["))
        menu.addItem(menuItem(title: "Lyrics Earlier (+0.5s)", action: #selector(increaseOffset), keyEquivalent: "]"))
        menu.addItem(menuItem(title: "Reset Offset", action: #selector(resetOffset), keyEquivalent: "0"))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        self.statusMenu = menu
        menu.delegate = self
        plainLyricsItem.target = self
        updateOffsetMenuItem()
        updatePlainLyricsMenuItem()
        refreshMenuState()

        // The pill is a surface like the others: it reports intent, the app
        // delegate decides. Nothing in it touches the engine directly.
        notchController.onSeek = { [weak self] timestamp in
            self?.engine.seek(to: timestamp)
        }
        notchController.onMenuRequest = { [weak self] screenPoint in
            self?.showStatusMenu(at: screenPoint)
        }
        // Fullscreen, screen arrangement and app switches change the answer to
        // "is the pill obscured" without any lyric update.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspaceCenter.addObserver(self, selector: #selector(surfaceEnvironmentChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(surfaceEnvironmentChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        engine.start()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            if let menu = statusMenu {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
            }
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            updateStatusItemLength()
        } else if let button = statusItem.button {
            statusItem.length = button.bounds.width
            showPopover(relativeTo: button)
            if let window = engine.freshWindow() {
                updateLyricsPanel(window)
            }
        }
    }

    private func setStatusTitle(_ title: String) {
        currentStatusTitle = title
        statusItem.button?.title = title
        if !popover.isShown {
            updateStatusItemLength()
        }
    }

    private func updateLyricsPanel(_ window: LyricsWindow) {
        lyricsPanelVC.update(window)
        popover.contentSize = lyricsPanelVC.preferredContentSize
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.alignment = .right
        button.cell?.lineBreakMode = .byTruncatingHead
        button.cell?.usesSingleLineMode = true
        button.cell?.wraps = false
    }

    private func updateStatusItemLength() {
        let font = statusItem.button?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let width = ceil((currentStatusTitle as NSString).size(withAttributes: [.font: font]).width + StatusItemTitle.horizontalPadding)
        statusItem.length = min(max(width, StatusItemTitle.minWidth), StatusItemTitle.maxWidth)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        let anchorRect = NSRect(x: button.bounds.maxX - 1, y: 0, width: 1, height: button.bounds.height)
        popover.show(relativeTo: anchorRect, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        updateStatusItemLength()
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func forceRefresh() {
        engine.refresh()
    }

    @objc private func openLRCLibSearch() {
        guard let state = spotifyClient.currentState(),
              let url = lrclibClient.searchPageURL(track: state.track, artist: state.artist, duration: state.duration)
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func importLyricsFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        engine.importLyrics(pasted)
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let rawMode = sender.representedObject as? String,
              let mode = LyricsDisplayMode(rawValue: rawMode)
        else {
            return
        }
        let wasNotch = displayMode == .notch
        UserDefaults.standard.set(rawMode, forKey: displayModeDefaultsKey)
        if wasNotch, mode != .notch {
            // Leaving notch mode is the one case where the surface must stop
            // rendering at all (it keeps pin and pause state otherwise).
            notchController.dismiss()
        }
        refresh()
    }

    /// Re-evaluates everything a mode, screen, fullscreen or preference change
    /// can affect, in the one order that is load-bearing: the menu reflects the
    /// new state, the fullscreen answer is refreshed, and only then does the
    /// active surface read it. Call this instead of the three steps by hand.
    private func refresh() {
        refreshMenuState()
        refreshFullscreenState()
        renderPresentation()
    }

    /// Everything in the menu that depends on mode, screens or the persisted
    /// choices, in one place: built at launch and on mode changes, and refreshed
    /// each time the menu opens (and before a programmatic pop-up from the pill).
    private func refreshMenuState() {
        let mode = displayMode
        menuBarModeItem.state = mode == .menuBar ? .on : .off
        floatingModeItem.state = mode == .floating ? .on : .off
        notchModeItem.state = mode == .notch ? .on : .off
        showOverFullscreenItem.state = showOverFullscreenApps ? .on : .off
        displayMenuItem.isHidden = mode != .notch
        showOverFullscreenItem.isHidden = mode != .notch
        rebuildDisplaySubmenu()
    }

    /// Single presentation path: every lyric/status update flows through here
    /// and is rendered to the menu bar title and/or the floating panel.
    /// Main thread only.
    private func apply(_ presentation: LyricsPresentation) {
        self.presentation = presentation
        renderPresentation()
    }

    private func renderPresentation() {
        // Only surfaces that are actually on screen are touched: the popover
        // follows the song while it is open, and the pill is dismissed once when
        // notch mode is left (see selectDisplayMode), not on every tick.
        if popover.isShown, let window = presentation.window {
            updateLyricsPanel(window)
        }
        switch displayMode {
        case .menuBar:
            setStatusItemVisible(true)
            floatingPanelController.hide()
            setStatusTitle(StatusItemTitle.text(for: presentation))
        case .floating:
            setStatusItemVisible(true)
            setStatusTitle(floatingPlaceholder)
            floatingPanelController.update(presentation)
        case .notch:
            floatingPanelController.hide()
            if popover.isShown {
                popover.performClose(nil)
            }
            // The pill sits on the menu bar's centre, so the item gets out of
            // its way; the same menu is reachable from the pill's right-click.
            setStatusItemVisible(false)
            refreshNotchSurface()
        }
    }

    private func setStatusItemVisible(_ visible: Bool) {
        guard statusItem.isVisible != visible else { return }
        statusItem.isVisible = visible
        if visible {
            updateStatusItemLength()
        }
    }

    /// Everything the pill needs before it may show: notch mode and a display to
    /// attach to. Being obscured by a fullscreen app is a separate input — it
    /// hides the window without clearing pin, hover or pause state (T9 R4).
    private func refreshNotchSurface() {
        guard displayMode == .notch,
              let screen = NotchDisplays.preferredScreen(override: notchDisplayOverride)
        else {
            notchController.dismiss()
            return
        }
        notchController.present(
            presentation,
            geometry: NotchDisplays.geometry(for: screen),
            isObscured: isFullscreenBlocking
        )
    }

    /// Re-runs the one environment question that costs a window-server query.
    /// Called on mode, display, checkbox and space/screen changes only.
    private func refreshFullscreenState() {
        guard displayMode == .notch,
              !showOverFullscreenApps,
              let screen = NotchDisplays.preferredScreen(override: notchDisplayOverride)
        else {
            isFullscreenBlocking = false
            return
        }
        isFullscreenBlocking = FullscreenApps.isBlocking(screen: screen)
    }

    /// Right-click on the pill: the same menu the status item shows.
    private func showStatusMenu(at screenPoint: NSPoint) {
        statusMenu.popUp(positioning: nil, at: screenPoint, in: nil)
    }

    /// Displays come and go, so their list is rebuilt here; `menuWillOpen` and
    /// every decision path call that.
    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func rebuildDisplaySubmenu() {
        let effectiveID = NotchDisplays.preferredScreen(override: notchDisplayOverride).map { NotchDisplays.id(of: $0) }
        let submenu = NSMenu()
        for screen in NSScreen.screens {
            let id = NotchDisplays.id(of: screen)
            let item = NSMenuItem(title: screen.localizedName, action: #selector(selectNotchDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = id == effectiveID ? .on : .off
            submenu.addItem(item)
        }
        displayMenuItem.submenu = submenu
    }

    @objc private func selectNotchDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: notchDisplayDefaultsKey)
        refresh()
    }

    @objc private func toggleShowOverFullscreenApps() {
        UserDefaults.standard.set(!showOverFullscreenApps, forKey: showOverFullscreenDefaultsKey)
        refresh()
    }

    @objc private func surfaceEnvironmentChanged() {
        refresh()
    }

    @objc private func togglePlainLyrics() {
        engine.togglePlainLyrics()
    }

    @objc private func decreaseOffset() {
        engine.adjustOffset(by: -0.5)
    }

    @objc private func increaseOffset() {
        engine.adjustOffset(by: 0.5)
    }

    @objc private func resetOffset() {
        engine.setOffset(0)
    }

    private func updateOffsetMenuItem() {
        offsetItem.title = String(format: "Offset: %+.1fs", engine.offset)
    }

    private func updatePlainLyricsMenuItem() {
        plainLyricsItem.state = engine.isPlainLyrics ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
private let delegate = SpotifyLyricsApp()
app.delegate = delegate
app.run()
