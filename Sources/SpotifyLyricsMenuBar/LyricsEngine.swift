import Foundation

private let pollInterval: TimeInterval = 0.4
private let trackCheckInterval: TimeInterval = 2.0
private let lyricsRefetchInterval: TimeInterval = 20.0

/// Owns everything about the current song: which track is playing, its parsed
/// lyrics and offset, the polling timers, and the presentation every surface
/// draws. Surfaces never read this state; they render what it emits.
///
/// The engine never measures or shapes text: the current line goes out exactly
/// as it was parsed, and whatever a surface does with widths, halves or
/// truncation owns that itself.
///
/// Every callback fires on the main thread.
final class LyricsEngine {
    /// The current moment for the display mode that is active.
    var onPresentation: ((LyricsPresentation) -> Void)?
    /// Track metadata for the menu; nil when Spotify is gone.
    var onTrackChanged: ((SpotifyState?) -> Void)?
    var onOffsetChanged: (() -> Void)?
    var onPlainLyricsChanged: (() -> Void)?
    /// Nothing is left to show: close the popover.
    var onTrackCleared: (() -> Void)?

    private let client: SpotifyClient
    private let lrclib: LRCLibClient
    private let cache: LyricsCache
    private let artwork = ArtworkCache()
    private let stateQueue = DispatchQueue(label: "SpotifyLyricsMenuBar.state")

    private var currentTrackID: String?
    private var currentLyricsCacheKey: String?
    private var lyrics: [LyricLine] = []
    private var isTimingExact = false
    private var lyricOffset: TimeInterval = 0
    private var forcePlainLyrics = false
    private var shouldBypassLyricsCache = false
    private var lastLyricsFetchAttempt: Date?
    private var lyricsFetchToken = UUID()
    private var playback: PlaybackState = .none
    private var trackTimer: Timer?
    private var lyricTimer: Timer?

    init(client: SpotifyClient, lrclib: LRCLibClient, cache: LyricsCache) {
        self.client = client
        self.lrclib = lrclib
        self.cache = cache
    }

    var offset: TimeInterval {
        stateQueue.sync { lyricOffset }
    }

    var isPlainLyrics: Bool {
        stateQueue.sync { forcePlainLyrics }
    }

    /// Starts the two polling timers and looks at Spotify once immediately.
    func start() {
        trackTimer = Timer.scheduledTimer(withTimeInterval: trackCheckInterval, repeats: true) { [weak self] _ in
            self?.checkTrack()
        }
        lyricTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.updateLyric()
        }
        checkTrack()
    }

    /// Drops the current song and refetches, bypassing the lyrics cache.
    func refresh() {
        stateQueue.sync {
            currentTrackID = nil
            shouldBypassLyricsCache = true
        }
        checkTrack()
    }

    /// Re-fetches the current song as timed or plain lyrics.
    func togglePlainLyrics() {
        let shouldRefetch = stateQueue.sync { () -> Bool in
            forcePlainLyrics.toggle()
            guard currentTrackID != nil else { return false }
            // The old lines are no longer wanted; the refetch fills them back in.
            lyrics = []
            isTimingExact = false
            return true
        }
        onPlainLyricsChanged?()
        guard shouldRefetch else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let state = self.client.currentState() else { return }
            let lookup = self.lrclib.lookup(track: state.track, artist: state.artist, duration: state.duration)
            self.fetchAndApply(lookup, bypassCache: false)
        }
    }

    func adjustOffset(by delta: TimeInterval) {
        setOffset(offset + delta)
    }

    func setOffset(_ offset: TimeInterval) {
        let roundedOffset = (offset * 2).rounded() / 2
        let cacheKey = stateQueue.sync { currentLyricsCacheKey }
        stateQueue.sync {
            lyricOffset = roundedOffset
        }
        if let cacheKey {
            cache.storeOffset(roundedOffset, for: cacheKey)
        }
        onOffsetChanged?()
        updateLyric()
    }

    /// Seeks so `timestamp` becomes the current line under the user's offset.
    /// Ignored for estimated timing (plain lyrics spread over the duration),
    /// whose timestamps are invented and would land anywhere in the song.
    /// Fire-and-forget: the write lands on the next 0.4 s poll.
    func seek(to timestamp: TimeInterval) {
        let target = stateQueue.sync { () -> TimeInterval? in
            guard isTimingExact else { return nil }
            return timestamp - lyricOffset
        }
        guard let target else { return }
        client.seek(to: target)
    }

    /// Replaces the current song's lyrics with LRC text pasted by the user.
    /// Main thread only: it reports through the callbacks immediately.
    func importLyrics(_ text: String) {
        guard let state = client.currentState() else { return }
        let lookup = lrclib.lookup(track: state.track, artist: state.artist, duration: state.duration)
        let imported = lrclib.importedLyrics(from: text, lookup: lookup)
        guard !imported.isEmpty else {
            emit(presentation(
                title: "♪ (invalid lyrics)",
                window: .message("Invalid clipboard lyrics"),
                isPlaceholder: true,
                playback: stateQueue.sync { playback }
            ))
            return
        }

        stateQueue.sync {
            currentTrackID = state.id
            currentLyricsCacheKey = lookup.cacheKey
            lyrics = imported
            isTimingExact = true
            lyricOffset = storedLyricOffset(for: lookup.cacheKey)
            forcePlainLyrics = false
            shouldBypassLyricsCache = false
            lastLyricsFetchAttempt = nil
            lyricsFetchToken = UUID()
        }
        onTrackChanged?(state)
        onPlainLyricsChanged?()
        updateLyric()
    }

    /// Window for a surface that just appeared (the popover): reads the live
    /// position instead of waiting for the next 0.4 s tick.
    func freshWindow() -> LyricsWindow? {
        guard let state = client.currentState() else { return nil }
        let snapshot = stateQueue.sync { (lyrics, lyricOffset) }
        guard !snapshot.0.isEmpty else { return nil }
        return LyricsWindow.around(snapshot.0, at: state.position + snapshot.1)
    }

    // MARK: - Polling

    private struct FetchDecision {
        let isNewTrack: Bool
        let bypassCache: Bool
        let token: UUID
    }

    private func checkTrack() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            autoreleasepool {
                guard let self else { return }

                guard let state = self.client.currentState() else {
                    self.stateQueue.sync { self.clearTrack() }
                    DispatchQueue.main.async {
                        self.emit(self.presentation(title: placeholder, window: nil, playback: .none))
                        self.onTrackChanged?(nil)
                        self.onOffsetChanged?()
                        self.onPlainLyricsChanged?()
                        self.onTrackCleared?()
                    }
                    return
                }

                // Pause/resume and the return to nothing are announced even though
                // the lyric itself did not move: that transition is the only idle
                // signal the surfaces get.
                if let transition = self.notePlayback(state) {
                    let moment = self.moment(state: state, playback: transition)
                    DispatchQueue.main.async { self.emit(moment) }
                }
                guard state.playing else { return }

                let lookup = self.lrclib.lookup(track: state.track, artist: state.artist, duration: state.duration)
                guard let decision = self.fetchDecision(for: state, lookup: lookup) else { return }

                DispatchQueue.main.async {
                    self.onTrackChanged?(state)
                    self.emit(self.presentation(
                        title: loadingPlaceholder,
                        window: .message("Loading lyrics…"),
                        isPlaceholder: true,
                        trackKey: state.id,
                        playback: .playing
                    ))
                    if decision.isNewTrack {
                        self.onOffsetChanged?()
                        self.onPlainLyricsChanged?()
                    }
                }

                guard let fetched = self.fetchAndApply(
                    lookup,
                    bypassCache: decision.bypassCache,
                    token: decision.token
                ) else {
                    return
                }
                if fetched.lines.isEmpty {
                    DispatchQueue.main.async {
                        self.emit(self.presentation(
                            title: "♪ (no lyrics found)",
                            window: .message("No lyrics found"),
                            isPlaceholder: true,
                            trackKey: state.id,
                            playback: .playing
                        ))
                    }
                }
                // Independent of the lyric and never in front of it (R7): a slow
                // cover must not delay a line.
                self.loadArtwork(for: state.id)
            }
        }
    }

    /// Decides whether this poll fetches at all and mints the token that fences
    /// the result, both under the one lock so a track change cannot slip between.
    private func fetchDecision(for state: SpotifyState, lookup: LyricsLookup) -> FetchDecision? {
        stateQueue.sync {
            let now = Date()

            if state.id != currentTrackID {
                let decision = FetchDecision(
                    isNewTrack: true,
                    bypassCache: shouldBypassLyricsCache,
                    token: UUID()
                )
                currentTrackID = state.id
                currentLyricsCacheKey = lookup.cacheKey
                lyrics = []
                isTimingExact = false
                lyricOffset = storedLyricOffset(for: lookup.cacheKey)
                forcePlainLyrics = false
                shouldBypassLyricsCache = false
                lastLyricsFetchAttempt = now
                lyricsFetchToken = decision.token
                return decision
            }

            guard lyrics.isEmpty else { return nil }
            if let lastAttempt = lastLyricsFetchAttempt,
               now.timeIntervalSince(lastAttempt) < lyricsRefetchInterval {
                return nil
            }
            let decision = FetchDecision(isNewTrack: false, bypassCache: true, token: UUID())
            lastLyricsFetchAttempt = now
            lyricsFetchToken = decision.token
            return decision
        }
    }

    /// The one token-fenced fetch: mint or take a token, fetch off the main
    /// thread, apply only if no newer fetch has started meanwhile. Blocking, so
    /// call it from a background queue. Returns nil when a newer fetch won.
    @discardableResult
    private func fetchAndApply(_ lookup: LyricsLookup, bypassCache: Bool, token: UUID? = nil) -> FetchedLyrics? {
        let fetchToken = token ?? stateQueue.sync { () -> UUID in
            let token = UUID()
            lyricsFetchToken = token
            return token
        }
        let forcePlain = stateQueue.sync { forcePlainLyrics }
        let fetched = lrclib.fetchLyrics(lookup: lookup, forcePlain: forcePlain, bypassCache: bypassCache)
        let applied = stateQueue.sync { () -> Bool in
            guard lyricsFetchToken == fetchToken else { return false }
            lyrics = fetched.lines
            isTimingExact = fetched.isExact
            return true
        }
        guard applied else { return nil }
        DispatchQueue.main.async {
            self.updateLyric()
        }
        return fetched
    }

    /// Cover art on its own background block, after the lyric has been applied.
    private func loadArtwork(for trackKey: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.artwork.image(for: trackKey) == nil else { return }
            self.artwork.load(key: trackKey, url: self.client.currentArtworkURL())
        }
    }

    /// Forgets everything about the current song. Call under `stateQueue`.
    private func clearTrack() {
        currentTrackID = nil
        currentLyricsCacheKey = nil
        lyrics = []
        isTimingExact = false
        lyricOffset = 0
        forcePlainLyrics = false
        shouldBypassLyricsCache = false
        lastLyricsFetchAttempt = nil
        lyricsFetchToken = UUID()
        playback = .none
    }

    private func updateLyric() {
        // With no track at all there is nothing to follow and nothing to idle;
        // the 2 s track poll owns that state. Paused still polls, because the
        // resume transition is what brings the surfaces back to life.
        guard stateQueue.sync(execute: { playback != .none }) else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                guard let state = self.client.currentState() else { return }

                if let transition = self.notePlayback(state) {
                    let moment = self.moment(state: state, playback: transition)
                    DispatchQueue.main.async {
                        self.emit(moment)
                    }
                }
                guard state.playing else { return }
                guard self.stateQueue.sync(execute: { self.currentTrackID != nil && !self.lyrics.isEmpty }) else {
                    return
                }

                let moment = self.moment(state: state, playback: .playing)
                DispatchQueue.main.async {
                    self.emit(moment)
                }
            }
        }
    }

    private func storedLyricOffset(for cacheKey: String) -> TimeInterval {
        let cachedOffset = cache.offset(for: cacheKey)
        if cachedOffset != 0 {
            return cachedOffset
        }
        let legacyOffsets = UserDefaults.standard.dictionary(forKey: "lyricOffsets") as? [String: Double]
        guard let legacyOffset = legacyOffsets?[cacheKey] else { return 0 }
        cache.storeOffset(legacyOffset, for: cacheKey)
        return legacyOffset
    }

    /// The one place that assembles what a surface sees, so the metadata every
    /// surface depends on cannot drift between the emit sites.
    private func presentation(
        title: String,
        window: LyricsWindow?,
        lineElapsed: TimeInterval = 0,
        lineDuration: TimeInterval = 0,
        isPlaceholder: Bool = false,
        isTimingExact: Bool = false,
        trackKey: String? = nil,
        playback: PlaybackState
    ) -> LyricsPresentation {
        LyricsPresentation(
            currentLine: title,
            window: window,
            lineElapsed: lineElapsed,
            lineDuration: lineDuration,
            isPlaceholder: isPlaceholder,
            isTimingExact: isTimingExact,
            trackKey: trackKey,
            artwork: trackKey.flatMap { artwork.image(for: $0) },
            playback: playback
        )
    }

    /// The moment for this state: the raw current line, the window around it, how
    /// far into that line the playhead is, the artwork and the playback. Built
    /// from the state every time — nothing is patched onto an older presentation.
    private func moment(state: SpotifyState, playback: PlaybackState) -> LyricsPresentation {
        let snapshot = stateQueue.sync {
            (lyrics: lyrics, offset: lyricOffset, isTimingExact: isTimingExact)
        }
        let playhead = state.position + snapshot.offset
        guard let line = Self.currentLine(in: snapshot.lyrics, at: playhead, trackDuration: state.duration) else {
            return presentation(title: placeholder, window: nil, playback: playback)
        }
        return presentation(
            title: line.text,
            window: LyricsWindow.around(snapshot.lyrics, at: playhead),
            lineElapsed: line.elapsed,
            lineDuration: line.duration,
            isTimingExact: snapshot.isTimingExact,
            trackKey: state.id,
            playback: playback
        )
    }

    /// The line the playhead is inside, how far into it we are and how long it
    /// runs. Before the first timestamp the first line is current, which is what
    /// every surface has always shown during a song's intro.
    private static func currentLine(
        in lyrics: [LyricLine],
        at position: TimeInterval,
        trackDuration: TimeInterval
    ) -> (text: String, elapsed: TimeInterval, duration: TimeInterval)? {
        guard !lyrics.isEmpty else { return nil }

        var text = ""
        var start = lyrics[0].timestamp
        var end = trackDuration
        for lyric in lyrics {
            if lyric.timestamp <= position {
                text = lyric.text
                start = lyric.timestamp
            } else {
                end = lyric.timestamp
                break
            }
        }
        if text.isEmpty {
            text = lyrics[0].text
            end = lyrics.count > 1 ? lyrics[1].timestamp : trackDuration
        }
        return (text, max(0, position - start), max(0, end - start))
    }

    /// Records Spotify's playback state and returns it only when it changed, so
    /// one transition is announced once however often it is observed.
    private func notePlayback(_ state: SpotifyState) -> PlaybackState? {
        stateQueue.sync {
            let next: PlaybackState = state.playing ? .playing : .paused
            guard next != playback else { return nil }
            playback = next
            return next
        }
    }

    /// Main thread only.
    private func emit(_ presentation: LyricsPresentation) {
        onPresentation?(presentation)
    }
}
