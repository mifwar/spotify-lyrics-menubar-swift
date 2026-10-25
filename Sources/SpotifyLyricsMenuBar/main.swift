import Cocoa
import Foundation

private let displayModeDefaultsKey = "lyricsDisplayMode"

private enum LyricsDisplayMode: String {
    case menuBar
    case floating
}

private final class SpotifyLyricsApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let nowPlayingItem = NSMenuItem(title: "Now Playing: -", action: nil, keyEquivalent: "")
    private let offsetItem = NSMenuItem(title: "Offset: 0.0s", action: nil, keyEquivalent: "")
    private let plainLyricsItem = NSMenuItem(title: "Use Plain Lyrics", action: #selector(togglePlainLyrics), keyEquivalent: "p")
    private let menuBarModeItem = NSMenuItem(title: "Menu Bar", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
    private let floatingModeItem = NSMenuItem(title: "Floating", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
    private lazy var floatingPanelController = FloatingLyricsPanelController()
    private let spotifyClient = SpotifyClient()
    private let lyricsCache = LyricsCache()
    private lazy var lrclibClient = LRCLibClient(cache: lyricsCache)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Draw the initial state before the first presentation arrives.
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
        displayModeSubmenu.addItem(menuBarModeItem)
        displayModeSubmenu.addItem(floatingModeItem)
        displayModeItem.submenu = displayModeSubmenu
        menu.addItem(displayModeItem)
        menu.addItem(.separator())
        menu.addItem(offsetItem)
        menu.addItem(menuItem(title: "Lyrics Later (-0.5s)", action: #selector(decreaseOffset), keyEquivalent: "["))
        menu.addItem(menuItem(title: "Lyrics Earlier (+0.5s)", action: #selector(increaseOffset), keyEquivalent: "]"))
        menu.addItem(menuItem(title: "Reset Offset", action: #selector(resetOffset), keyEquivalent: "0"))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        self.statusMenu = menu
        plainLyricsItem.target = self
        updateOffsetMenuItem()
        updatePlainLyricsMenuItem()
        refreshMenuState()

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
              LyricsDisplayMode(rawValue: rawMode) != nil
        else {
            return
        }
        UserDefaults.standard.set(rawMode, forKey: displayModeDefaultsKey)
        refresh()
    }

    /// Re-evaluates what a mode change can affect: the menu reflects the new
    /// state, then the active surface is re-rendered.
    private func refresh() {
        refreshMenuState()
        renderPresentation()
    }

    /// Everything in the menu that depends on the mode, in one place: built at
    /// launch and refreshed on mode changes.
    private func refreshMenuState() {
        let mode = displayMode
        menuBarModeItem.state = mode == .menuBar ? .on : .off
        floatingModeItem.state = mode == .floating ? .on : .off
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
        // follows the song while it is open, not on every tick.
        if popover.isShown, let window = presentation.window {
            updateLyricsPanel(window)
        }
        switch displayMode {
        case .menuBar:
            floatingPanelController.hide()
            setStatusTitle(StatusItemTitle.text(for: presentation))
        case .floating:
            setStatusTitle(floatingPlaceholder)
            floatingPanelController.update(presentation)
        }
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
