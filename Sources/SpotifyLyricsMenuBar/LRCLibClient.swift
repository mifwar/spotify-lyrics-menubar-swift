import Foundation

private let userAgent = "SpotifyLyricsMenuBarSwift/1.0 (personal use)"
private let maxLyricsMatchScore = 5_000.0
private let lrclibSearchBaseURL = "https://lrclib.net/search/"

/// How long one lyric or artwork request may take before it is abandoned. The
/// wait and the request timeout are the same number, so a hung server can never
/// hold a background poll longer than this.
private let networkTimeout: TimeInterval = 5

private let ephemeralSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    return URLSession(configuration: config)
}()

/// The app's one blocking GET: URLSession plus a semaphore, shared by the lyrics
/// client and the artwork cache so the subtle waiting pattern has a single home.
/// Only call it from a background queue.
func blockingGet(_ url: URL, headers: [String: String] = [:]) -> (data: Data, statusCode: Int)? {
    var request = URLRequest(url: url)
    request.timeoutInterval = networkTimeout
    for (field, value) in headers {
        request.setValue(value, forHTTPHeaderField: field)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: (data: Data, statusCode: Int)?
    ephemeralSession.dataTask(with: request) { data, response, _ in
        if let data {
            result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        semaphore.signal()
    }.resume()

    _ = semaphore.wait(timeout: .now() + networkTimeout)
    return result
}

struct LRCLibResponse: Codable {
    let trackName: String?
    let artistName: String?
    let syncedLyrics: String?
    let plainLyrics: String?
    let duration: Double?
}

struct LyricsLookup {
    let track: String
    let artist: String
    let duration: TimeInterval
    let cacheKey: String
}

/// Lyrics plus where their timing came from: plain lyrics spread over the
/// track duration are a guess, and nothing may seek or truncate against them.
struct FetchedLyrics {
    let lines: [LyricLine]
    let isExact: Bool

    static let empty = FetchedLyrics(lines: [], isExact: false)
}

/// LRCLib search, fetch, parse and cache pipeline. Blocking: call it from a
/// background queue.
final class LRCLibClient {
    private let cache: LyricsCache
    private let decoder = JSONDecoder()

    init(cache: LyricsCache) {
        self.cache = cache
    }

    func lookup(track: String, artist: String, duration: TimeInterval) -> LyricsLookup {
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

    func searchPageURL(track: String, artist: String, duration: TimeInterval) -> URL? {
        let lookup = lookup(track: track, artist: artist, duration: duration)
        let query = lookup.track.isEmpty ? track : lookup.track
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: lrclibSearchBaseURL + encodedQuery)
    }

    /// Cache first, then /api/get by exact metadata, then two /api/search
    /// passes. An empty result is cached only by the fetch paths that found
    /// something, so a later attempt can still succeed.
    func fetchLyrics(lookup: LyricsLookup, forcePlain: Bool, bypassCache: Bool = false) -> FetchedLyrics {
        if !bypassCache, let cachedResponse = cache.response(for: lookup.cacheKey) {
            let cachedLyrics = lyrics(from: cachedResponse, duration: lookup.duration, forcePlain: forcePlain)
            if !cachedLyrics.lines.isEmpty {
                return cachedLyrics
            }
        }

        if !bypassCache,
           let cachedResponse = cache.response(track: lookup.track, artist: lookup.artist, duration: lookup.duration) {
            let cachedLyrics = lyrics(from: cachedResponse, duration: lookup.duration, forcePlain: forcePlain)
            if !cachedLyrics.lines.isEmpty {
                cache.store(cachedResponse, for: lookup.cacheKey)
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
                if !parsed.lines.isEmpty, lyricsMatchScore(result: response, lookup: lookup) < maxLyricsMatchScore {
                    cache.store(response, for: lookup.cacheKey)
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

        return .empty
    }

    /// Parses pasted LRC text as if LRCLib had returned it, so an imported
    /// song caches and renders exactly like a fetched one.
    func importedLyrics(from text: String, lookup: LyricsLookup) -> [LyricLine] {
        let response = LRCLibResponse(
            trackName: lookup.track,
            artistName: lookup.artist,
            syncedLyrics: normalizedLRCText(text),
            plainLyrics: nil,
            duration: lookup.duration
        )
        let parsed = lyrics(from: response, duration: lookup.duration, forcePlain: false)
        guard !parsed.lines.isEmpty else { return [] }
        cache.store(response, for: lookup.cacheKey)
        return parsed.lines
    }

    private func searchLyrics(query: [URLQueryItem], lookup: LyricsLookup, forcePlain: Bool) -> FetchedLyrics? {
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
            guard !parsed.lines.isEmpty else { return nil }
            cache.store(best, for: lookup.cacheKey)
            return parsed
        } catch {
            return nil
        }
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

    private func lyrics(from response: LRCLibResponse, duration: TimeInterval, forcePlain: Bool) -> FetchedLyrics {
        if !forcePlain, let syncedLyrics = response.syncedLyrics, !syncedLyrics.isEmpty {
            let parsed = parseLRC(syncedLyrics)
            return FetchedLyrics(lines: parsed, isExact: !parsed.isEmpty)
        }

        guard let plainLyrics = response.plainLyrics, duration > 0 else {
            return .empty
        }

        let lines = plainLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return .empty }
        let step = duration / TimeInterval(lines.count)
        let timed = lines.enumerated().map { index, line in
            LyricLine(timestamp: TimeInterval(index) * step, text: line)
        }
        return FetchedLyrics(lines: timed, isExact: false)
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

    /// LRCLib's endpoint is synchronous here because every caller is already
    /// on a background queue and the lyric timeline must not race the UI.
    private func requestLRCLib(path: String, query: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = query

        guard let url = components.url,
              let response = blockingGet(url, headers: ["User-Agent": userAgent]),
              response.statusCode == 200
        else {
            return nil
        }
        return response.data
    }
}
