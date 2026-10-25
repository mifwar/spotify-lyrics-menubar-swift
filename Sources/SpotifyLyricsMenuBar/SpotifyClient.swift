import Cocoa

struct SpotifyState {
    let track: String
    let artist: String
    let position: TimeInterval
    let duration: TimeInterval
    let id: String
    let playing: Bool
}

/// AppleScript access to Spotify: one serialized queue for every call, because
/// NSAppleScript is not safe to execute from two threads at once.
final class SpotifyClient {
    private let queue = DispatchQueue(label: "SpotifyLyricsMenuBar.appleScript")
    // Seeks go out on their own queue: a write takes ~100 ms, which is a
    // quarter of the 0.4 s lyric poll and must never delay it.
    private let seekQueue = DispatchQueue(label: "SpotifyLyricsMenuBar.spotifySeek")
    private let checkRunningScript: NSAppleScript
    private let fetchStateScript: NSAppleScript
    private let artworkScript: NSAppleScript

    init() {
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
        let artworkSource = """
        tell application "Spotify"
            if player state is playing or player state is paused then
                return artwork url of current track
            else
                return ""
            end if
        end tell
        """

        self.checkRunningScript = NSAppleScript(source: checkSource)!
        self.fetchStateScript = NSAppleScript(source: fetchSource)!
        self.artworkScript = NSAppleScript(source: artworkSource)!

        // Compile and run both once at launch: the automation permission
        // prompt then appears while the app is starting instead of on the
        // first 2 s poll, where a denied prompt used to read as "no track".
        queue.sync {
            var error: NSDictionary?
            _ = self.checkRunningScript.executeAndReturnError(&error)
            _ = self.fetchStateScript.executeAndReturnError(&error)
        }
    }

    /// nil when Spotify is not running or reports no track.
    func currentState() -> SpotifyState? {
        let output = queue.sync { () -> String in
            guard run(checkRunningScript) == "true" else { return "" }
            return run(fetchStateScript)
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

    /// Artwork URL for the current track. Local files and some podcasts have
    /// none: an empty or unreadable result is `nil`, never an error.
    func currentArtworkURL() -> URL? {
        let output = queue.sync { () -> String in
            guard run(checkRunningScript) == "true" else { return "" }
            return run(artworkScript)
        }
        guard !output.isEmpty else { return nil }
        return URL(string: output)
    }

    private func run(_ script: NSAppleScript) -> String {
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return "" }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Fire-and-forget: clamps, compiles and sends on the seek queue, ignoring
    /// every failure. Play/pause is left untouched — Spotify only moves its
    /// player position here.
    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let source = Self.seekSource(to: seconds)
        seekQueue.async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
        }
    }

    /// Script text for one seek. Kept separate from sending it so the seconds
    /// formatting and the script itself can be compiled and checked without
    /// touching the user's playback.
    static func seekSource(to seconds: TimeInterval) -> String {
        """
        tell application "Spotify" to set player position to \(max(0, seconds))
        """
    }
}

/// Decoded cover art, one image per track key, kept in memory for the length of
/// the session. Downloads are synchronous on purpose: the only caller is the
/// engine's detached artwork block, which runs once per song, and the surfaces
/// then read an image that is already there.
final class ArtworkCache {
    /// Enough for a long listening session without holding a whole library.
    private static let maxEntries = 32

    private let lock = NSLock()
    private var images: [String: NSImage] = [:]
    private var order: [String] = []

    /// Already loaded image for `key`; nil while it has not loaded (or if the
    /// track has no artwork). Safe from any thread.
    func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    /// Fetches and decodes `url` once per key. Never call from the main thread:
    /// it waits for the download. A nil, unfetchable or undecodable URL just
    /// leaves the track without artwork.
    func load(key: String, url: URL?) {
        guard let url else { return }
        lock.lock()
        let alreadyLoaded = images[key] != nil
        lock.unlock()
        guard !alreadyLoaded else { return }

        guard let response = blockingGet(url), let image = NSImage(data: response.data) else { return }
        store(image, for: key)
    }

    private func store(_ image: NSImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if images[key] == nil {
            order.append(key)
        }
        images[key] = image
        while order.count > Self.maxEntries {
            images[order.removeFirst()] = nil
        }
    }
}
