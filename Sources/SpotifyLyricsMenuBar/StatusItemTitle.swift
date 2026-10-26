import Cocoa

/// Everything the status item does with text: how wide it may grow, how a line
/// that is too wide is rolled in two halves, and the final truncation.
///
/// Pure functions over strings and widths — no delegate state — so the app
/// delegate stays menu, mode routing and surface wiring.
enum StatusItemTitle {
    /// How wide the item may grow, and the padding the title keeps inside it.
    static let minWidth: CGFloat = 72
    static let maxWidth: CGFloat = 360
    static let horizontalPadding: CGFloat = 24

    /// A line longer than the item is rolled in two halves; this caps how far
    /// into it the switch can be stretched, so a long instrumental gap after a
    /// line doesn't hold the first half on screen.
    private static let maxRollDuration: TimeInterval = 8
    /// Last resort for a single word that will not fit even as half a line.
    private static let maxChars = 70

    /// The text to show for a presentation. The engine hands over the raw
    /// current line; fitting it to this item's width happens here.
    static func text(for presentation: LyricsPresentation) -> String {
        let line = presentation.currentLine
        guard !presentation.isPlaceholder,
              !line.isEmpty,
              !fits(line),
              let (first, second) = splitInTwo(line)
        else {
            return truncated(line)
        }
        let cappedDuration = min(presentation.lineDuration, maxRollDuration)
        let switchAt = cappedDuration * Double(first.count) / Double(line.count)
        return truncated(presentation.lineElapsed < switchAt ? first : second)
    }

    private static func fits(_ text: String) -> Bool {
        let width = (text as NSString).size(withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]).width
        return width + horizontalPadding <= maxWidth
    }

    /// Splits at the space nearest the middle; nil when there is no space.
    private static func splitInTwo(_ text: String) -> (String, String)? {
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        let candidates = [text[..<mid].lastIndex(of: " "), text[mid...].firstIndex(of: " ")].compactMap { $0 }
        guard let split = candidates.min(by: {
            abs(text.distance(from: $0, to: mid)) < abs(text.distance(from: $1, to: mid))
        }) else { return nil }
        return (String(text[..<split]), String(text[text.index(after: split)...]))
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars - 1)) + "…"
    }
}
