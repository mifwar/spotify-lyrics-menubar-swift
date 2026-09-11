import Cocoa
import Foundation

private let maxChars = 70
private let pollInterval: TimeInterval = 0.4
private let trackCheckInterval: TimeInterval = 2.0
private let lyricsRefetchInterval: TimeInterval = 20.0
private let minStatusItemWidth: CGFloat = 72
private let maxStatusItemWidth: CGFloat = 360
private let statusItemHorizontalPadding: CGFloat = 24
private let lyricsPanelWidth: CGFloat = 480
private let lyricsPanelMinHeight: CGFloat = 84
private let lyricsPanelVerticalPadding: CGFloat = 24
private let lyricsPanelLineHeight: CGFloat = 19
private let lyricsPanelLineSpacing: CGFloat = 4
private let placeholder = "♪ Lyrics"
private let loadingPlaceholder = "♪···"
private let floatingPlaceholder = "♪"
private let displayModeDefaultsKey = "lyricsDisplayMode"
private let userAgent = "SpotifyLyricsMenuBarSwift/1.0 (personal use)"
private let maxLyricsMatchScore = 5_000.0
private let lyricsCacheFilename = "lyrics-cache.json"
private let lrclibSearchBaseURL = "https://lrclib.net/search/"

private enum LyricsDisplayMode: String {
    case menuBar
    case floating
}

/// Last rendered presentation, replayed when the display mode changes.
/// Main thread only.
private struct LyricsPresentation {
    var menuBarTitle = placeholder
    var floatingLines: [(text: String, isCurrent: Bool)]?
    var isPlaceholder = false
}

private struct SpotifyState {
    let track: String
    let artist: String
    let position: TimeInterval
    let duration: TimeInterval
    let id: String
    let playing: Bool
}

private struct LyricLine {
    let timestamp: TimeInterval
    let text: String
}

private struct LyricsLookup {
    let track: String
    let artist: String
    let duration: TimeInterval
    let cacheKey: String
}

private struct LRCLibResponse: Codable {
    let trackName: String?
    let artistName: String?
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?
}

private struct CachedLyrics: Codable {
    let response: LRCLibResponse
    let cachedAt: Date
    let offset: Double

    init(response: LRCLibResponse, cachedAt: Date, offset: Double = 0) {
        self.response = response
        self.cachedAt = cachedAt
        self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        response = try container.decode(LRCLibResponse.self, forKey: .response)
        cachedAt = try container.decode(Date.self, forKey: .cachedAt)
        offset = try container.decodeIfPresent(Double.self, forKey: .offset) ?? 0
    }
}

private final class LyricsCache {
    private let queue = DispatchQueue(label: "SpotifyLyricsMenuBar.lyricsCache")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL?
    private var entries: [String: CachedLyrics] = [:]

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpotifyLyricsMenuBar", isDirectory: true)
        self.fileURL = directory?.appendingPathComponent(lyricsCacheFilename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let directory, let fileURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? decoder.decode([String: CachedLyrics].self, from: data)) ?? [:]
        if !entries.isEmpty {
            save()
        }
    }

    func response(for key: String) -> LRCLibResponse? {
        queue.sync {
            entries[key]?.response
        }
    }

    func response(track: String, artist: String, duration: TimeInterval) -> LRCLibResponse? {
        queue.sync {
            let prefix = "\(track.lowercased())|\(artist.lowercased())|"
            return entries
                .compactMap { key, entry -> (LRCLibResponse, Double)? in
                    guard key.hasPrefix(prefix),
                          let cachedDuration = Double(key.dropFirst(prefix.count))
                    else {
                        return nil
                    }
                    return (entry.response, abs(cachedDuration - duration.rounded()))
                }
                .min(by: { $0.1 < $1.1 })?
                .0
        }
    }

    func store(_ response: LRCLibResponse, for key: String) {
        queue.sync {
            let offset = entries[key]?.offset ?? 0
            entries[key] = CachedLyrics(response: response, cachedAt: Date(), offset: offset)
            save()
        }
    }

    func offset(for key: String) -> Double {
        queue.sync {
            entries[key]?.offset ?? 0
        }
    }

    func storeOffset(_ offset: Double, for key: String) {
        queue.sync {
            guard let entry = entries[key] else { return }
            entries[key] = CachedLyrics(response: entry.response, cachedAt: entry.cachedAt, offset: offset)
            save()
        }
    }

    private func save() {
        guard let fileURL, let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private final class LyricsPanelViewController: NSViewController {
    private var labels: [NSTextField] = []

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        for _ in 0..<7 {
            let label = NSTextField(labelWithString: "")
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            labels.append(label)
            stack.addArrangedSubview(label)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])

        self.view = container
    }

    func update(lines: [(text: String, isCurrent: Bool)]) {
        var visibleCount = 0
        for (i, line) in lines.enumerated() {
            guard i < labels.count else { break }
            if line.text.isEmpty {
                labels[i].isHidden = true
            } else {
                visibleCount += 1
                labels[i].isHidden = false
                labels[i].stringValue = line.text
                if line.isCurrent {
                    labels[i].font = NSFont.boldSystemFont(ofSize: 14)
                    labels[i].textColor = .labelColor
                } else {
                    labels[i].font = NSFont.systemFont(ofSize: 13)
                    labels[i].textColor = .secondaryLabelColor
                }
            }
        }

        let spacing = max(0, CGFloat(visibleCount - 1)) * lyricsPanelLineSpacing
        let height = max(lyricsPanelMinHeight, lyricsPanelVerticalPadding + CGFloat(visibleCount) * lyricsPanelLineHeight + spacing)
        preferredContentSize = NSSize(width: lyricsPanelWidth, height: height)
    }
}

private final class SpotifyLyricsApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let nowPlayingItem = NSMenuItem(title: "Now Playing: -", action: nil, keyEquivalent: "")
    private let offsetItem = NSMenuItem(title: "Offset: 0.0s", action: nil, keyEquivalent: "")
    private let plainLyricsItem = NSMenuItem(title: "Use Plain Lyrics", action: #selector(togglePlainLyrics), keyEquivalent: "p")
    private let menuBarModeItem = NSMenuItem(title: "Menu Bar", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
    private let floatingModeItem = NSMenuItem(title: "Floating", action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
    private lazy var floatingPanelController = FloatingLyricsPanelController()
    private var presentation = LyricsPresentation()
    private let stateQueue = DispatchQueue(label: "SpotifyLyricsMenuBar.state")
    private let appleScriptQueue = DispatchQueue(label: "SpotifyLyricsMenuBar.appleScript")

    private var currentTrackID: String?
    private var currentLyricsCacheKey: String?
    private var lyrics: [LyricLine] = []
    private var lastDisplayed = ""
    private var lyricOffset: TimeInterval = 0
    private var forcePlainLyrics = false
    private var shouldBypassLyricsCache = false
    private var lastLyricsFetchAttempt: Date?
    private var lyricsFetchToken = UUID()
    private var currentStatusTitle = placeholder
    private var trackTimer: Timer?
    private var lyricTimer: Timer?

    private let checkRunningScript: NSAppleScript
    private let fetchStateScript: NSAppleScript
    private let lyricsCache = LyricsCache()
    private let decoder = JSONDecoder()
    private lazy var ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private let popover = NSPopover()
    private let lyricsPanelVC = LyricsPanelViewController()
    private var statusMenu: NSMenu!

    override init() {
        let checkSource = "application \"Spotify\" is running"
        let fetchSource = """
        tell application "Spotify"
            if player state is playing or player state is paused then
                set t to name of current track
                set a to artist of current track
                set p to player position
                set d to (duration of current track) / 1000
                set i to id of current track
                set s to player state as string
                return t & "||" & a & "||" & p & "||" & d & "||" & i & "||" & s
            else
                return ""
            end if
        end tell
        """

        self.checkRunningScript = NSAppleScript(source: checkSource)!
        self.fetchStateScript = NSAppleScript(source: fetchSource)!

        super.init()

        appleScriptQueue.sync {
            var error: NSDictionary?
            _ = self.checkRunningScript.executeAndReturnError(&error)
            _ = self.fetchStateScript.executeAndReturnError(&error)
        }
    }

    private var displayMode: LyricsDisplayMode {
        LyricsDisplayMode(rawValue: UserDefaults.standard.string(forKey: displayModeDefaultsKey) ?? "") ?? .menuBar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        presentStatus(title: placeholder, floatingLines: nil)
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
        updateDisplayModeMenuItems()

        trackTimer = Timer.scheduledTimer(withTimeInterval: trackCheckInterval, repeats: true) { [weak self] _ in
            self?.checkTrack()
        }
        lyricTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.updateLyric()
        }

        checkTrack()
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
            let snapshot = stateQueue.sync { (lyrics, lyricOffset) }
            if let state = getSpotifyState(), !snapshot.0.isEmpty {
                let lines = panelLines(at: state.position + snapshot.1, in: snapshot.0)
                updateLyricsPanel(lines: lines)
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

    private func updateLyricsPanel(lines: [(text: String, isCurrent: Bool)]) {
        lyricsPanelVC.update(lines: lines)
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
        let width = ceil((currentStatusTitle as NSString).size(withAttributes: [.font: font]).width + statusItemHorizontalPadding)
        statusItem.length = min(max(width, minStatusItemWidth), maxStatusItemWidth)
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
        stateQueue.sync {
            currentTrackID = nil
            shouldBypassLyricsCache = true
        }
        checkTrack()
    }

    @objc private func openLRCLibSearch() {
        guard let state = getSpotifyState() else { return }
        let lookup = lyricsLookup(track: state.track, artist: state.artist, duration: state.duration)
        let query = lookup.track.isEmpty ? state.track : lookup.track
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: lrclibSearchBaseURL + encodedQuery)
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func importLyricsFromClipboard() {
        guard let state = getSpotifyState(),
              let pasted = NSPasteboard.general.string(forType: .string)
        else {
            return
        }

        let lookup = lyricsLookup(track: state.track, artist: state.artist, duration: state.duration)
        let syncedLyrics = normalizedLRCText(pasted)
        let response = LRCLibResponse(
            trackName: lookup.track,
            artistName: lookup.artist,
            syncedLyrics: syncedLyrics,
            plainLyrics: nil,
            duration: lookup.duration
        )
        let importedLyrics = lyrics(from: response, duration: lookup.duration, forcePlain: false)
        guard !importedLyrics.isEmpty else {
            DispatchQueue.main.async {
                self.presentStatus(title: "♪ (invalid lyrics)", floatingLines: [("Invalid clipboard lyrics", true)], isPlaceholder: true)
                self.updateLyricsPanel(lines: [("", false), ("", false), ("", false), ("Invalid clipboard lyrics", true), ("", false), ("", false), ("", false)])
            }
            return
        }

        lyricsCache.store(response, for: lookup.cacheKey)
        stateQueue.sync {
            currentTrackID = state.id
            currentLyricsCacheKey = lookup.cacheKey
            lyrics = importedLyrics
            lastDisplayed = ""
            lyricOffset = storedLyricOffset(for: lookup.cacheKey)
            forcePlainLyrics = false
            shouldBypassLyricsCache = false
            lastLyricsFetchAttempt = nil
            lyricsFetchToken = UUID()
        }
        DispatchQueue.main.async {
            self.nowPlayingItem.title = "♪ \(state.track) — \(state.artist)"
            self.updatePlainLyricsMenuItem()
            self.updateLyric()
        }
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let rawMode = sender.representedObject as? String,
              LyricsDisplayMode(rawValue: rawMode) != nil
        else {
            return
        }
        UserDefaults.standard.set(rawMode, forKey: displayModeDefaultsKey)
        updateDisplayModeMenuItems()
        renderPresentation()
    }

    private func updateDisplayModeMenuItems() {
        let mode = displayMode
        menuBarModeItem.state = mode == .menuBar ? .on : .off
        floatingModeItem.state = mode == .floating ? .on : .off
    }

    /// Single presentation path: every lyric/status update flows through here
    /// and is rendered to the menu bar title and/or the floating panel.
    /// Main thread only.
    private func presentStatus(title: String, floatingLines: [(text: String, isCurrent: Bool)]?, isPlaceholder: Bool = false) {
        presentation = LyricsPresentation(menuBarTitle: title, floatingLines: floatingLines, isPlaceholder: isPlaceholder)
        renderPresentation()
    }

    private func renderPresentation() {
        switch displayMode {
        case .menuBar:
            floatingPanelController.hide()
            setStatusTitle(presentation.menuBarTitle)
        case .floating:
            setStatusTitle(floatingPlaceholder)
            if let lines = presentation.floatingLines {
                floatingPanelController.update(lines: lines, isPlaceholder: presentation.isPlaceholder)
            } else {
                floatingPanelController.hide()
            }
        }
    }

    @objc private func togglePlainLyrics() {
        let shouldRefetch = stateQueue.sync {
            forcePlainLyrics.toggle()
            let should = currentTrackID != nil
            if should {
                lyrics = []
                lastDisplayed = ""
            }
            return should
        }
        updatePlainLyricsMenuItem()
        if shouldRefetch {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self, let state = self.getSpotifyState() else { return }
                let fetchToken = self.stateQueue.sync { () -> UUID in
                    let token = UUID()
                    self.lyricsFetchToken = token
                    return token
                }
                let fetched = self.fetchLyrics(track: state.track, artist: state.artist, duration: state.duration)
                let shouldApplyFetch = self.stateQueue.sync { () -> Bool in
                    guard self.lyricsFetchToken == fetchToken else { return false }
                    self.lyrics = fetched
                    return true
                }
                guard shouldApplyFetch else { return }
                DispatchQueue.main.async {
                    self.updateLyric()
                }
            }
        }
    }

    @objc private func decreaseOffset() {
        adjustOffset(by: -0.5)
    }

    @objc private func increaseOffset() {
        adjustOffset(by: 0.5)
    }

    @objc private func resetOffset() {
        setOffset(0)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func adjustOffset(by delta: TimeInterval) {
        let nextOffset = stateQueue.sync { lyricOffset + delta }
        setOffset(nextOffset)
    }

    private func setOffset(_ offset: TimeInterval) {
        let roundedOffset = (offset * 2).rounded() / 2
        let cacheKey = stateQueue.sync { currentLyricsCacheKey }
        stateQueue.sync {
            lyricOffset = roundedOffset
            lastDisplayed = ""
        }
        if let cacheKey {
            storeLyricOffset(roundedOffset, for: cacheKey)
        }
        updateOffsetMenuItem()
        updateLyric()
    }

    private func updateOffsetMenuItem() {
        let offset = stateQueue.sync { lyricOffset }
        offsetItem.title = String(format: "Offset: %+.1fs", offset)
    }

    private func storedLyricOffset(for cacheKey: String) -> TimeInterval {
        let cachedOffset = lyricsCache.offset(for: cacheKey)
        if cachedOffset != 0 {
            return cachedOffset
        }
        let legacyOffsets = UserDefaults.standard.dictionary(forKey: "lyricOffsets") as? [String: Double]
        guard let legacyOffset = legacyOffsets?[cacheKey] else { return 0 }
        lyricsCache.storeOffset(legacyOffset, for: cacheKey)
        return legacyOffset
    }

    private func storeLyricOffset(_ offset: TimeInterval, for cacheKey: String) {
        lyricsCache.storeOffset(offset, for: cacheKey)
    }

    private func updatePlainLyricsMenuItem() {
        let isPlain = stateQueue.sync { forcePlainLyrics }
        plainLyricsItem.state = isPlain ? .on : .off
    }

    private func checkTrack() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            autoreleasepool {
                guard let self else { return }

                guard let state = self.getSpotifyState() else {
                    self.stateQueue.sync {
                        self.currentTrackID = nil
                        self.currentLyricsCacheKey = nil
                        self.lyrics = []
                        self.lastDisplayed = ""
                        self.lyricOffset = 0
                        self.forcePlainLyrics = false
                        self.shouldBypassLyricsCache = false
                        self.lastLyricsFetchAttempt = nil
                        self.lyricsFetchToken = UUID()
                    }
                    DispatchQueue.main.async {
                        self.presentStatus(title: placeholder, floatingLines: nil)
                        self.nowPlayingItem.title = "Now Playing: -"
                        self.updateOffsetMenuItem()
                        self.updatePlainLyricsMenuItem()
                        self.popover.performClose(nil)
                    }
                    return
                }

                guard state.playing else { return }

                let lookup = self.lyricsLookup(track: state.track, artist: state.artist, duration: state.duration)
                let fetchInfo = self.stateQueue.sync { () -> (shouldFetch: Bool, isNewTrack: Bool, bypassCache: Bool, token: UUID) in
                    let now = Date()

                    if state.id != self.currentTrackID {
                        let bypassCache = self.shouldBypassLyricsCache
                        let token = UUID()
                        self.currentTrackID = state.id
                        self.currentLyricsCacheKey = lookup.cacheKey
                        self.lyrics = []
                        self.lastDisplayed = ""
                        self.lyricOffset = self.storedLyricOffset(for: lookup.cacheKey)
                        self.forcePlainLyrics = false
                        self.shouldBypassLyricsCache = false
                        self.lastLyricsFetchAttempt = now
                        self.lyricsFetchToken = token
                        return (true, true, bypassCache, token)
                    }

                    guard self.lyrics.isEmpty else {
                        return (false, false, false, self.lyricsFetchToken)
                    }

                    if let lastAttempt = self.lastLyricsFetchAttempt,
                       now.timeIntervalSince(lastAttempt) < lyricsRefetchInterval {
                        return (false, false, false, self.lyricsFetchToken)
                    }

                    let token = UUID()
                    self.lastDisplayed = ""
                    self.lastLyricsFetchAttempt = now
                    self.lyricsFetchToken = token
                    return (true, false, true, token)
                }
                guard fetchInfo.shouldFetch else { return }

                DispatchQueue.main.async {
                    self.nowPlayingItem.title = "♪ \(state.track) — \(state.artist)"
                    self.presentStatus(title: loadingPlaceholder, floatingLines: [("Loading lyrics…", true)], isPlaceholder: true)
                    if fetchInfo.isNewTrack {
                        self.updateOffsetMenuItem()
                        self.updatePlainLyricsMenuItem()
                    }
                    self.updateLyricsPanel(lines: [("", false), ("", false), ("", false), ("Loading...", true), ("", false), ("", false), ("", false)])
                }

                let fetchedLyrics = self.fetchLyrics(
                    track: state.track,
                    artist: state.artist,
                    duration: state.duration,
                    bypassCache: fetchInfo.bypassCache
                )
                let shouldApplyFetch = self.stateQueue.sync { () -> Bool in
                    guard self.lyricsFetchToken == fetchInfo.token else { return false }
                    self.lyrics = fetchedLyrics
                    return true
                }
                guard shouldApplyFetch else { return }
                DispatchQueue.main.async {
                    self.updateLyric()
                }

                if fetchedLyrics.isEmpty {
                    DispatchQueue.main.async {
                        self.presentStatus(title: "♪ (no lyrics found)", floatingLines: [("No lyrics found", true)], isPlaceholder: true)
                        self.updateLyricsPanel(lines: [("", false), ("", false), ("", false), ("(no lyrics)", true), ("", false), ("", false), ("", false)])
                    }
                }
            }
        }
    }

    private func updateLyric() {
        let hasTrack = stateQueue.sync { currentTrackID != nil && !lyrics.isEmpty }
        guard hasTrack else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            autoreleasepool {
                guard let self else { return }

                let snapshot = self.stateQueue.sync { (self.currentTrackID, self.lyrics, self.lastDisplayed, self.lyricOffset) }
                guard snapshot.0 != nil, !snapshot.1.isEmpty else { return }
                guard let state = self.getSpotifyState(), state.playing else { return }

                let adjustedPosition = state.position + snapshot.3
                var currentLine = ""
                for lyric in snapshot.1 {
                    if lyric.timestamp <= adjustedPosition {
                        currentLine = lyric.text
                    } else {
                        break
                    }
                }
                if currentLine.isEmpty, let first = snapshot.1.first {
                    currentLine = first.text
                }

                let panelLines = self.panelLines(at: adjustedPosition, in: snapshot.1)

                guard currentLine != snapshot.2 else {
                    DispatchQueue.main.async {
                        self.updateLyricsPanel(lines: panelLines)
                    }
                    return
                }

                let displayed = Self.truncated(currentLine)
                self.stateQueue.sync {
                    self.lastDisplayed = currentLine
                }
                DispatchQueue.main.async {
                    self.presentStatus(title: displayed, floatingLines: panelLines)
                    self.updateLyricsPanel(lines: panelLines)
                }
            }
        }
    }

    private func panelLines(at position: TimeInterval, in lyrics: [LyricLine]) -> [(text: String, isCurrent: Bool)] {
        var currentIdx = -1
        for (i, lyric) in lyrics.enumerated() {
            if lyric.timestamp <= position {
                currentIdx = i
            } else {
                break
            }
        }
        if currentIdx < 0 {
            currentIdx = 0
        }

        var lines: [(text: String, isCurrent: Bool)] = []
        for offset in -3...3 {
            let idx = currentIdx + offset
            if idx >= 0 && idx < lyrics.count {
                lines.append((lyrics[idx].text, offset == 0))
            } else {
                lines.append(("", false))
            }
        }
        return lines
    }

    private func getSpotifyState() -> SpotifyState? {
        let output = appleScriptQueue.sync { () -> String in
            guard executeAppleScriptUnlocked(checkRunningScript) == "true" else {
                return ""
            }
            return executeAppleScriptUnlocked(fetchStateScript)
        }
        let parts = output.components(separatedBy: "||")
        guard parts.count >= 6 else { return nil }

        guard
            let position = TimeInterval(parts[2].replacingOccurrences(of: ",", with: ".")),
            let duration = TimeInterval(parts[3].replacingOccurrences(of: ",", with: "."))
        else {
            return nil
        }

        return SpotifyState(
            track: parts[0],
            artist: parts[1],
            position: position,
            duration: duration,
            id: parts[4],
            playing: parts[5] == "playing"
        )
    }

    private func executeAppleScriptUnlocked(_ script: NSAppleScript) -> String {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return "" }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func fetchLyrics(
        track: String,
        artist: String,
        duration: TimeInterval,
        bypassCache: Bool = false
    ) -> [LyricLine] {
        let forcePlain = stateQueue.sync { forcePlainLyrics }
        let lookup = lyricsLookup(track: track, artist: artist, duration: duration)

        if !bypassCache, let cachedResponse = lyricsCache.response(for: lookup.cacheKey) {
            let cachedLyrics = lyrics(from: cachedResponse, duration: lookup.duration, forcePlain: forcePlain)
            if !cachedLyrics.isEmpty {
                return cachedLyrics
            }
        }

        if !bypassCache,
           let cachedResponse = lyricsCache.response(track: lookup.track, artist: lookup.artist, duration: lookup.duration) {
            let cachedLyrics = lyrics(from: cachedResponse, duration: lookup.duration, forcePlain: forcePlain)
            if !cachedLyrics.isEmpty {
                lyricsCache.store(cachedResponse, for: lookup.cacheKey)
                return cachedLyrics
            }
        }

        if let data = requestLRCLib(
            path: "/api/get",
            query: [
                URLQueryItem(name: "track_name", value: lookup.track),
                URLQueryItem(name: "artist_name", value: lookup.artist),
                URLQueryItem(name: "duration", value: "\(Int(lookup.duration))"),
            ]
        ) {
            if let response = try? decoder.decode(LRCLibResponse.self, from: data) {
                let parsed = lyrics(from: response, duration: lookup.duration, forcePlain: forcePlain)
                if !parsed.isEmpty, lyricsMatchScore(result: response, lookup: lookup) < maxLyricsMatchScore {
                    lyricsCache.store(response, for: lookup.cacheKey)
                    return parsed
                }
            }
        }

        if let parsed = searchLyrics(
            query: [
                URLQueryItem(name: "track_name", value: lookup.track),
                URLQueryItem(name: "artist_name", value: lookup.artist),
            ],
            lookup: lookup,
            forcePlain: forcePlain
        ) {
            return parsed
        }

        if let parsed = searchLyrics(
            query: [URLQueryItem(name: "q", value: "\(lookup.track) \(lookup.artist)")],
            lookup: lookup,
            forcePlain: forcePlain
        ) {
            return parsed
        }

        return []
    }

    private func searchLyrics(query: [URLQueryItem], lookup: LyricsLookup, forcePlain: Bool) -> [LyricLine]? {
        guard let searchData = requestLRCLib(
            path: "/api/search",
            query: query
        ) else {
            return nil
        }

        do {
            let results = try decoder.decode([LRCLibResponse].self, from: searchData)

            let scored = results.compactMap { result -> (LRCLibResponse, Double)? in
                guard result.syncedLyrics != nil || result.plainLyrics != nil else { return nil }
                let score = lyricsMatchScore(result: result, lookup: lookup)
                guard score < maxLyricsMatchScore else { return nil }
                return (result, score)
            }

            guard let best = scored.min(by: { $0.1 < $1.1 })?.0 else { return nil }
            let parsed = lyrics(from: best, duration: lookup.duration, forcePlain: forcePlain)
            guard !parsed.isEmpty else { return nil }
            if !parsed.isEmpty {
                lyricsCache.store(best, for: lookup.cacheKey)
            }
            return parsed
        } catch {
            return nil
        }
    }

    private func lyricsLookup(track: String, artist: String, duration: TimeInterval) -> LyricsLookup {
        let cleanTrack = track.replacingOccurrences(
            of: #"\s*[\(\[].*?[\)\]]\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? artist
        return LyricsLookup(
            track: cleanTrack,
            artist: cleanArtist,
            duration: duration,
            cacheKey: lyricsCacheKey(track: cleanTrack, artist: cleanArtist, duration: duration)
        )
    }

    private func lyricsMatchScore(result: LRCLibResponse, lookup: LyricsLookup) -> Double {
        let titlePenalty = textMatchPenalty(expected: lookup.track, actual: result.trackName)
        let artistPenalty = textMatchPenalty(expected: lookup.artist, actual: result.artistName)
        let durationDelta = abs((result.duration ?? lookup.duration) - lookup.duration)
        return titlePenalty * 100 + artistPenalty * 50 + durationDelta
    }

    private func textMatchPenalty(expected: String, actual: String?) -> Double {
        let expectedText = normalizedMatchText(expected)
        guard !expectedText.isEmpty else { return 0 }
        guard let actual, !actual.isEmpty else { return 20 }

        let actualText = normalizedMatchText(actual)
        if actualText == expectedText { return 0 }
        if actualText.contains(expectedText) || expectedText.contains(actualText) { return 1 }
        return 100
    }

    private func normalizedMatchText(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func lyricsCacheKey(track: String, artist: String, duration: TimeInterval) -> String {
        [
            track.lowercased(),
            artist.lowercased(),
            String(Int(duration.rounded())),
        ].joined(separator: "|")
    }

    private func normalizedLRCText(_ text: String) -> String {
        let withoutControls = text.replacingOccurrences(of: "\u{001B}[106;5u", with: "\n")

        var normalized = ""
        var index = withoutControls.startIndex
        while index < withoutControls.endIndex {
            if index != withoutControls.startIndex,
               withoutControls[index] == "[",
               isTimestampStart(in: withoutControls, at: index),
               !normalized.hasSuffix("\n") {
                normalized.append("\n")
            }
            normalized.append(withoutControls[index])
            index = withoutControls.index(after: index)
        }

        return normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isTimestampStart(in text: String, at index: String.Index) -> Bool {
        let next = text.index(after: index)
        guard next < text.endIndex, text[next].isNumber else { return false }

        var cursor = next
        while cursor < text.endIndex, text[cursor].isNumber {
            cursor = text.index(after: cursor)
        }

        guard cursor < text.endIndex, text[cursor] == ":" else { return false }
        cursor = text.index(after: cursor)
        guard cursor < text.endIndex, text[cursor].isNumber else { return false }

        return true
    }

    private func requestLRCLib(path: String, query: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = query

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var statusCode = 0

        ephemeralSession.dataTask(with: request) { data, response, _ in
            resultData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        guard statusCode == 200 else { return nil }
        return resultData
    }

    private func parseLRCLib(data: Data, duration: TimeInterval, forcePlain: Bool) -> [LyricLine] {
        do {
            let response = try decoder.decode(LRCLibResponse.self, from: data)
            return lyrics(from: response, duration: duration, forcePlain: forcePlain)
        } catch {
            return []
        }
    }

    private func lyrics(from response: LRCLibResponse, duration: TimeInterval, forcePlain: Bool) -> [LyricLine] {
        if !forcePlain, let syncedLyrics = response.syncedLyrics, !syncedLyrics.isEmpty {
            return parseLRC(syncedLyrics)
        }

        guard let plainLyrics = response.plainLyrics, duration > 0 else {
            return []
        }

        let lines = plainLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }
        let step = duration / TimeInterval(lines.count)
        return lines.enumerated().map { index, line in
            LyricLine(timestamp: TimeInterval(index) * step, text: line)
        }
    }

    private static let lrcRegex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+\.?\d*)\]([^\[]*)"#)

    private func parseLRC(_ lrcText: String) -> [LyricLine] {
        let normalizedText = normalizedLRCText(lrcText)
        let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        let matches = Self.lrcRegex.matches(in: normalizedText, range: range)

        let lines = matches.compactMap { match -> LyricLine? in
            guard
                let minuteRange = Range(match.range(at: 1), in: normalizedText),
                let secondRange = Range(match.range(at: 2), in: normalizedText),
                let textRange = Range(match.range(at: 3), in: normalizedText),
                let minutes = TimeInterval(normalizedText[minuteRange]),
                let seconds = TimeInterval(normalizedText[secondRange])
            else {
                return nil
            }

            let text = normalizedText[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return LyricLine(timestamp: minutes * 60 + seconds, text: text)
        }

        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars - 1)) + "…"
    }
}

let app = NSApplication.shared
private let delegate = SpotifyLyricsApp()
app.delegate = delegate
app.run()
