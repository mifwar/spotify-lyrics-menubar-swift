import Foundation

private let lyricsCacheFilename = "lyrics-cache.json"

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

/// Lyrics responses plus the per-song offset the user tuned, persisted as one
/// JSON file so an offset survives relaunches with the lyrics it belongs to.
final class LyricsCache {
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

    /// Nearest cached duration for the same track/artist: a re-release or a
    /// slightly different duration still matches the lyrics we already have.
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
