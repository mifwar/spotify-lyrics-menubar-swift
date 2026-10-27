import Cocoa

let placeholder = "♪ Lyrics"
let loadingPlaceholder = "♪···"
let floatingPlaceholder = "♪"

struct LyricLine {
    /// 0 when the timing is estimated.
    let timestamp: TimeInterval
    let text: String
}

/// Fixed-shape window around the current line, so renderers never recompute
/// which line is current.
struct LyricsWindow {
    /// 7 slots, enough for the floating panel; the notch surface shows the
    /// inner 5 (current ±2).
    static let radius = 3

    let lines: [LyricLine?] // exactly 2*radius+1, nil = padding
    let currentIndex: Int   // index into `lines` of the current line

    var current: LyricLine? { lines.indices.contains(currentIndex) ? lines[currentIndex] : nil }
}

extension LyricsWindow {
    /// Centered on the last line that starts at or before `position`. Before
    /// the first timestamp the first line is current, which is what the menu
    /// bar and panel have always shown during a song's intro.
    static func around(_ lyrics: [LyricLine], at position: TimeInterval) -> LyricsWindow {
        var index = -1
        for (i, lyric) in lyrics.enumerated() {
            if lyric.timestamp <= position {
                index = i
            } else {
                break
            }
        }
        if index < 0 {
            index = 0
        }

        var slots: [LyricLine?] = []
        for offset in -radius...radius {
            let source = index + offset
            slots.append(lyrics.indices.contains(source) ? lyrics[source] : nil)
        }
        return LyricsWindow(lines: slots, currentIndex: radius)
    }

    /// The slots within `radius` of the current line, in drawing order. Slots
    /// past either end of the song are padding (nil), so surfaces never range-
    /// check the window or re-derive where the current line sits.
    func rows(radius: Int) -> [LyricLine?] {
        (-radius...radius).map { offset in
            let index = currentIndex + offset
            return lines.indices.contains(index) ? lines[index] : nil
        }
    }

    /// One centered message with empty padding. Loading, no-lyrics and import
    /// errors all go through this so every surface shows the same copy.
    static func message(_ text: String) -> LyricsWindow {
        var slots = [LyricLine?](repeating: nil, count: radius * 2 + 1)
        slots[radius] = LyricLine(timestamp: 0, text: text)
        return LyricsWindow(lines: slots, currentIndex: radius)
    }
}

/// Everything a surface draws for the current moment: the current line, the
/// lyric window, the metadata the fuller surfaces need (placeholder styling,
/// whether clicking a line can seek, artwork) and Spotify's transport state.
///
/// Deliberately surface-neutral: the engine never measures text, so anything a
/// surface does with widths, halves or truncation belongs to that surface.
struct LyricsPresentation {
    /// The current line as the engine sees it, untruncated and unsplit. The
    /// status item fits, splits and truncates it against its own width.
    var currentLine: String = placeholder
    var window: LyricsWindow?       // nil = nothing to show for this surface
    /// How far the playhead is into `currentLine`, and how long that line runs.
    /// A surface that rolls a too-long line between two halves caps the
    /// duration itself; 0/0 means "no line".
    var lineElapsed: TimeInterval = 0
    var lineDuration: TimeInterval = 0
    var isPlaceholder: Bool = false
    var isTimingExact: Bool = false // false ⇒ plain/estimated ⇒ seek disabled
    var trackKey: String?           // artwork cache key
    var artwork: NSImage?           // nil = none, or not fetched yet
    var playback: PlaybackState = .none // Spotify's state, not the surface's
}

/// Spotify's transport state. Surfaces derive their idle behaviour from it
/// (paused → dot, none → hide); it is not something the surface controls.
enum PlaybackState {
    case playing, paused, none
}

/// Transport intent from a surface. The surface never talks to the player: it
/// reports what was clicked and the engine decides what it means. It lives with
/// the shared contract because the engine, the style, the card and the wiring
/// all speak it.
enum TransportCommand {
    case playPause, next, previous
}
