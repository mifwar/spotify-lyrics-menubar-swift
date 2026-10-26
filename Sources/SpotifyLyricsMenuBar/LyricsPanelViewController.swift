import Cocoa

let lyricsPanelWidth: CGFloat = 480
let lyricsPanelMinHeight: CGFloat = 84
private let lyricsPanelVerticalPadding: CGFloat = 24
private let lyricsPanelLineHeight: CGFloat = 19
private let lyricsPanelLineSpacing: CGFloat = 4

/// Popover surface: the same window the floating panel draws, sized down to the
/// lines that actually have text.
final class LyricsPanelViewController: NSViewController {
    private var labels: [NSTextField] = []

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        for _ in 0..<(LyricsWindow.radius * 2 + 1) {
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

    func update(_ window: LyricsWindow) {
        var visibleCount = 0
        for (i, label) in labels.enumerated() {
            guard window.lines.indices.contains(i),
                  let line = window.lines[i],
                  !line.text.isEmpty
            else {
                label.isHidden = true
                continue
            }
            visibleCount += 1
            label.isHidden = false
            label.stringValue = line.text
            if i == window.currentIndex {
                label.font = NSFont.boldSystemFont(ofSize: 14)
                label.textColor = .labelColor
            } else {
                label.font = NSFont.systemFont(ofSize: 13)
                label.textColor = .secondaryLabelColor
            }
        }

        let spacing = max(0, CGFloat(visibleCount - 1)) * lyricsPanelLineSpacing
        let height = max(lyricsPanelMinHeight, lyricsPanelVerticalPadding + CGFloat(visibleCount) * lyricsPanelLineHeight + spacing)
        preferredContentSize = NSSize(width: lyricsPanelWidth, height: height)
    }
}
