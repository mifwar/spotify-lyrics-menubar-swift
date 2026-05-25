import Cocoa
import Foundation

private let maxChars = 70
private let pollInterval: TimeInterval = 0.4
private let trackCheckInterval: TimeInterval = 2.0
private let placeholder = "♪ Lyrics"
private let userAgent = "SpotifyLyricsMenuBarSwift/1.0 (personal use)"
private let lyricOffsetKey = "lyricOffset"

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

private struct LRCLibResponse: Decodable {
    let syncedLyrics: String?
    let plainLyrics: String?
}

private final class SpotifyLyricsApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let nowPlayingItem = NSMenuItem(title: "Now Playing: -", action: nil, keyEquivalent: "")
    private let offsetItem = NSMenuItem(title: "Offset: 0.0s", action: nil, keyEquivalent: "")
    private let stateQueue = DispatchQueue(label: "SpotifyLyricsMenuBar.state")

    private var currentTrackID: String?
    private var lyrics: [LyricLine] = []
    private var lastDisplayed = ""
    private var lyricOffset = UserDefaults.standard.double(forKey: lyricOffsetKey)
    private var trackTimer: Timer?
    private var lyricTimer: Timer?

    private let checkRunningScript: NSAppleScript
    private let fetchStateScript: NSAppleScript
    private let decoder = JSONDecoder()
    private lazy var ephemeralSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

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

        var error: NSDictionary?
        _ = self.checkRunningScript.executeAndReturnError(&error)
        _ = self.fetchStateScript.executeAndReturnError(&error)

        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem.button?.title = placeholder

        let menu = NSMenu()
        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Refresh Lyrics", action: #selector(forceRefresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(offsetItem)
        menu.addItem(menuItem(title: "Lyrics Later (-0.5s)", action: #selector(decreaseOffset), keyEquivalent: "["))
        menu.addItem(menuItem(title: "Lyrics Earlier (+0.5s)", action: #selector(increaseOffset), keyEquivalent: "]"))
        menu.addItem(menuItem(title: "Reset Offset", action: #selector(resetOffset), keyEquivalent: "0"))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        updateOffsetMenuItem()

        trackTimer = Timer.scheduledTimer(withTimeInterval: trackCheckInterval, repeats: true) { [weak self] _ in
            self?.checkTrack()
        }
        lyricTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.updateLyric()
        }

        checkTrack()
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func forceRefresh() {
        stateQueue.sync {
            currentTrackID = nil
        }
        checkTrack()
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
        stateQueue.sync {
            lyricOffset = roundedOffset
            lastDisplayed = ""
        }
        UserDefaults.standard.set(roundedOffset, forKey: lyricOffsetKey)
        updateOffsetMenuItem()
        updateLyric()
    }

    private func updateOffsetMenuItem() {
        let offset = stateQueue.sync { lyricOffset }
        offsetItem.title = String(format: "Offset: %+.1fs", offset)
    }

    private func checkTrack() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            autoreleasepool {
                guard let self else { return }

                guard let state = self.getSpotifyState() else {
                    self.stateQueue.sync {
                        self.currentTrackID = nil
                        self.lyrics = []
                        self.lastDisplayed = ""
                    }
                    DispatchQueue.main.async {
                        self.statusItem.button?.title = placeholder
                        self.nowPlayingItem.title = "Now Playing: -"
                    }
                    return
                }

                let changed = self.stateQueue.sync { state.id != self.currentTrackID }
                guard changed else { return }

                self.stateQueue.sync {
                    self.currentTrackID = state.id
                    self.lyrics = []
                    self.lastDisplayed = ""
                }

                DispatchQueue.main.async {
                    self.nowPlayingItem.title = "♪ \(state.track) — \(state.artist)"
                    self.statusItem.button?.title = "Loading lyrics..."
                }

                let fetchedLyrics = self.fetchLyrics(track: state.track, artist: state.artist, duration: state.duration)
                self.stateQueue.sync {
                    self.lyrics = fetchedLyrics
                }

                if fetchedLyrics.isEmpty {
                    DispatchQueue.main.async {
                        self.statusItem.button?.title = "♪ (no lyrics found)"
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

                guard !currentLine.isEmpty, currentLine != snapshot.2 else { return }
                let displayed = Self.truncated(currentLine)

                self.stateQueue.sync {
                    self.lastDisplayed = currentLine
                }
                DispatchQueue.main.async {
                    self.statusItem.button?.title = displayed
                }
            }
        }
    }

    private func getSpotifyState() -> SpotifyState? {
        guard executeAppleScript(checkRunningScript) == "true" else {
            return nil
        }

        let output = executeAppleScript(fetchStateScript)
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

    private func executeAppleScript(_ script: NSAppleScript) -> String {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return "" }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func fetchLyrics(track: String, artist: String, duration: TimeInterval) -> [LyricLine] {
        let cleanTrack = track.replacingOccurrences(
            of: #"\s*[\(\[].*?[\)\]]\s*"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? artist

        if let data = requestLRCLib(
            path: "/api/get",
            query: [
                URLQueryItem(name: "track_name", value: cleanTrack),
                URLQueryItem(name: "artist_name", value: cleanArtist),
                URLQueryItem(name: "duration", value: "\(Int(duration))")
            ]
        ) {
            let parsed = parseLRCLib(data: data, duration: duration)
            if !parsed.isEmpty {
                return parsed
            }
        }

        guard let searchData = requestLRCLib(
            path: "/api/search",
            query: [
                URLQueryItem(name: "track_name", value: cleanTrack),
                URLQueryItem(name: "artist_name", value: cleanArtist)
            ]
        ) else {
            return []
        }

        do {
            let results = try decoder.decode([LRCLibResponse].self, from: searchData)
            guard let first = results.first else { return [] }
            return lyrics(from: first, duration: duration)
        } catch {
            return []
        }
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

    private func parseLRCLib(data: Data, duration: TimeInterval) -> [LyricLine] {
        do {
            let response = try decoder.decode(LRCLibResponse.self, from: data)
            return lyrics(from: response, duration: duration)
        } catch {
            return []
        }
    }

    private func lyrics(from response: LRCLibResponse, duration: TimeInterval) -> [LyricLine] {
        if let syncedLyrics = response.syncedLyrics, !syncedLyrics.isEmpty {
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

    private static let lrcRegex = try! NSRegularExpression(pattern: #"^\[(\d+):(\d+\.?\d*)\](.*)$"#)

    private func parseLRC(_ lrcText: String) -> [LyricLine] {
        let lines = lrcText.components(separatedBy: .newlines).compactMap { line -> LyricLine? in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = Self.lrcRegex.firstMatch(in: line, range: range), match.numberOfRanges == 4 else {
                return nil
            }
            guard
                let minuteRange = Range(match.range(at: 1), in: line),
                let secondRange = Range(match.range(at: 2), in: line),
                let textRange = Range(match.range(at: 3), in: line),
                let minutes = TimeInterval(line[minuteRange]),
                let seconds = TimeInterval(line[secondRange])
            else {
                return nil
            }

            let text = line[textRange].trimmingCharacters(in: .whitespacesAndNewlines)
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
