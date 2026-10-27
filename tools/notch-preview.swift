// Renders the notch surface in four states for both notch variants — a
// simulated pill and a synthetic hardware notch — and checks the presence
// policy, so the surface can be reviewed on a machine without a notch and
// without screen-recording rights. Not part of the app target.
//
// The controller is the real one, driven through the same entry points the
// tracking area and mouse handlers use, against geometry parked off every
// display: nothing flashes on the user's screen while this runs.
//
// Build and run from the repository root (top-level code needs a file named
// main.swift in a multi-file swiftc build, hence the symlink):
//
//   mkdir -p build/notch-preview
//   ln -sfn "$PWD/tools/notch-preview.swift" build/notch-preview/main.swift
//   CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" swiftc \
//     -target "$(uname -m)-apple-macos12.0" -framework Cocoa \
//     -o build/notch-preview/notch-preview \
//     Sources/SpotifyLyricsMenuBar/LyricsPresentation.swift \
//     Sources/SpotifyLyricsMenuBar/NotchGeometry.swift \
//     Sources/SpotifyLyricsMenuBar/NotchStyle.swift \
//     Sources/SpotifyLyricsMenuBar/NotchCardView.swift \
//     Sources/SpotifyLyricsMenuBar/NotchLyricsController.swift \
//     build/notch-preview/main.swift
//   ./build/notch-preview/notch-preview /Users/eros/.crew/notch-lyrics/out

import Cocoa

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "out",
    isDirectory: true
)
var failures = 0

func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "ok  " : "FAIL") \(label)")
    if !condition { failures += 1 }
}

func describe(_ rect: NSRect) -> String {
    String(format: "x %.0f y %.0f w %.0f h %.0f", rect.minX, rect.minY, rect.width, rect.height)
}

/// Runs the main run loop: the controller's clocks need it, and this process has
/// no NSApplication.run().
func wait(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NotchDisplays.preferredScreen(override: nil) else {
    print("FAIL: no attached screen")
    exit(1)
}

/// One controller for both variants, so the preview has one panel to find and
/// the second run starts from the same state as the first.
let controller = NotchLyricsController()
var seeks: [TimeInterval] = []
var menuPoints: [NSPoint] = []
controller.onSeek = { seeks.append($0) }
var transports: [TransportCommand] = []
controller.onTransport = { transports.append($0) }
controller.onMenuRequest = { menuPoints.append($0) }

func panel() -> NSPanel {
    guard let panel = NSApp.windows.compactMap({ $0 as? NSPanel }).first else {
        print("FAIL: controller did not create a panel")
        exit(1)
    }
    return panel
}

func card() -> NSView {
    guard let card = panel().contentView else {
        print("FAIL: panel has no card view")
        exit(1)
    }
    return card
}

let lyrics = [
    LyricLine(timestamp: 0, text: "So close, no matter how far"),
    LyricLine(timestamp: 10, text: "Couldn't be much more from the heart"),
    LyricLine(timestamp: 20, text: "Forever trusting who we are"),
    LyricLine(timestamp: 30, text: "And nothing else matters"),
    LyricLine(timestamp: 40, text: "Never opened myself this way"),
    LyricLine(timestamp: 50, text: "Life is ours, we live it our way"),
    LyricLine(timestamp: 60, text: "All these words I don't just say"),
]

func presentation(_ playback: PlaybackState, exact: Bool = true) -> LyricsPresentation {
    LyricsPresentation(
        window: LyricsWindow.around(lyrics, at: 35), // current: index 3, timestamp 30
        isTimingExact: exact,
        trackKey: "preview",
        playback: playback
    )
}

/// A simulated notch shape, or a synthetic hardware one, parked off every
/// display so the window server never shows it.
func syntheticGeometry(simulated: Bool) -> NotchGeometry {
    NotchGeometry(
        screen: screen,
        notchFrame: NSRect(x: -4000, y: 600, width: 200, height: 32),
        isSimulated: simulated
    )
}

/// Square top corners (flush with the screen), rounded bottom: a cutout.
func cutoutPath(in rect: NSRect) -> NSBezierPath {
    let radius: CGFloat = 8
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
    path.appendArc(
        withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius),
        radius: radius,
        startAngle: 180,
        endAngle: 270
    )
    path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
    path.appendArc(
        withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius),
        radius: radius,
        startAngle: 270,
        endAngle: 360
    )
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    path.close()
    return path
}

func snapshot(_ name: String, geometry: NotchGeometry) {
    let view = card()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        check(false, "no bitmap for \(name)")
        return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    let cardImage = NSImage(size: view.bounds.size)
    cardImage.addRepresentation(rep)

    // A neutral strip so the black card reads in a PR. The card is placed at its
    // real distance from the screen's top edge, which is what shows the dot
    // clearing a hardware cutout.
    let margin: CGFloat = 40
    let width = max(480, cardImage.size.width + 2 * margin)
    let topOffset = geometry.notchFrame.maxY - panel().frame.maxY
    let canvas = NSImage(size: NSSize(width: width, height: topOffset + cardImage.size.height + margin))
    canvas.lockFocus()
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvas.size).fill()

    if !geometry.isSimulated {
        // Synthetic cutout: the card must never draw content here, and a dot on
        // a notched display sits below it.
        NSColor.black.setFill()
        cutoutPath(in: NSRect(
            x: (width - geometry.notchFrame.width) / 2,
            y: canvas.size.height - geometry.notchFrame.height,
            width: geometry.notchFrame.width,
            height: geometry.notchFrame.height
        )).fill()
    }

    cardImage.draw(in: NSRect(
        x: (width - cardImage.size.width) / 2,
        y: canvas.size.height - topOffset - cardImage.size.height,
        width: cardImage.size.width,
        height: cardImage.size.height
    ))
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        check(false, "could not encode \(name)")
        return
    }
    do {
        // The caller names any path; make it instead of failing every render
        // on a fresh directory, which reads like a code failure.
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try png.write(to: outputDirectory.appendingPathComponent("T18-\(name).png"))
        print("wrote T18-\(name).png (\(Int(cardImage.size.width))×\(Int(cardImage.size.height)) card)")
    } catch {
        check(false, "could not write \(name): \(error.localizedDescription)")
    }
}

/// Hover is for reading, pin is for controlling: the transport row exists only
/// while pinned, and once there it owns the whole band.
///
/// The harness discovers the targets by probing instead of recomputing their
/// positions: the only arithmetic it may do is measure what the card laid out.
func checkPinnedTransport(_ variant: String, geometry: NotchGeometry) {
    let view = cardView()
    check(view.showsTransport, "\(variant): the pinned card shows transport")
    check(view.isExpanded, "\(variant): the pinned card is expanded")

    // Every 1 pt probe that reports a command, grouped into bounding boxes.
    var boxes: [TransportCommand: NSRect] = [:]
    for y in stride(from: 0.0, through: view.bounds.height, by: 1.0) {
        for x in stride(from: 0.0, through: view.bounds.width, by: 1.0) {
            guard let command = view.transportCommand(at: NSPoint(x: x, y: y)) else { continue }
            boxes[command] = boxes[command]?.union(NSRect(x: x, y: y, width: 1, height: 1))
                ?? NSRect(x: x, y: y, width: 1, height: 1)
        }
    }
    let expected: [TransportCommand] = [.previous, .playPause, .next]
    check(Set(boxes.keys) == Set(expected), "\(variant): all three transport targets are reachable")

    for command in expected {
        guard let box = boxes[command] else {
            check(false, "\(variant): \(command) has no target")
            continue
        }
        let centre = NSPoint(x: box.midX, y: box.midY)
        check(
            abs(box.width - NotchStyle.transportButtonSize) <= 1 && abs(box.height - NotchStyle.transportButtonSize) <= 1,
            "\(variant): \(command) target is \(Int(box.width))×\(Int(box.height)) pt"
        )
        check(view.transportCommand(at: centre) == command, "\(variant): \(command) centre maps to itself")
        check(view.isInTransportRow(centre), "\(variant): \(command) is inside the transport band")
    }

    let ordered = expected.compactMap { boxes[$0] }
    if ordered.count == 3 {
        check(ordered[0].maxX < ordered[1].minX && ordered[1].maxX < ordered[2].minX,
              "\(variant): previous, play/pause and next sit left to right")
        let gap = ordered[1].minX - ordered[0].maxX
        print("[\(variant)] transport targets: \(ordered.map { "\(Int($0.minX))-\(Int($0.maxX))" }.joined(separator: ", ")), gap \(Int(gap)) pt")
        check(gap > NotchStyle.transportButtonSize,
              "\(variant): the gap (\(Int(gap)) pt) is wider than a target (\(Int(NotchStyle.transportButtonSize)) pt)")
        let gapPoint = NSPoint(x: ordered[0].maxX + gap / 2, y: ordered[0].midY)
        check(view.transportCommand(at: gapPoint) == nil, "\(variant): the gap between targets hits no button")
        check(view.isInTransportRow(gapPoint), "\(variant): the gap is still inside the transport band")

        // Clicking a button reports its command and changes nothing else.
        let pinnedBefore = controller.isPinned
        let seeksBefore = seeks.count
        controller.click(at: NSPoint(x: ordered[0].midX, y: ordered[0].midY))
        check(transports.last == .previous, "\(variant): clicking previous reports previous")
        check(controller.isPinned == pinnedBefore, "\(variant): a button click does not unpin")
        check(seeks.count == seeksBefore, "\(variant): a button click does not seek")

        // Clicking a gap does nothing at all: no command, no pin flip, no seek.
        let commandsBefore = transports.count
        controller.click(at: gapPoint)
        check(transports.count == commandsBefore, "\(variant): clicking a gap sends no command")
        check(controller.isPinned == pinnedBefore, "\(variant): clicking a gap does not unpin")
        check(seeks.count == seeksBefore, "\(variant): clicking a gap does not seek")
    }

    // The glyph follows the player: pause while playing, play while paused.
    check(
        NotchStyle.transportSymbol(.playPause, playback: .playing) == "pause.fill",
        "\(variant): playing shows pause"
    )
    check(
        NotchStyle.transportSymbol(.playPause, playback: .paused) == "play.fill",
        "\(variant): paused shows play"
    )
    check(NotchStyle.transportSymbol(.previous, playback: .playing) == "backward.fill", "\(variant): previous glyph")
    check(NotchStyle.transportSymbol(.next, playback: .playing) == "forward.fill", "\(variant): next glyph")
    check(view.playback == .playing, "\(variant): the card knows the current playback state")

    // The glyph is drawn from that state: a paused player shows play, even with
    // the pin holding the card open.
    if variant == "simulated" {
        controller.present(presentation(.paused), geometry: geometry, isObscured: false)
        wait(0.15)
        check(view.playback == .paused, "\(variant): the paused card knows the playback state")
        snapshot("\(variant)-pinned-paused", geometry: geometry)
        controller.present(presentation(.playing), geometry: geometry, isObscured: false)
        wait(0.15)
    }
}

/// While pinned the card grows by exactly the transport row, and its height
/// math stays the single source of truth.
func checkPinnedHeight(_ variant: String, geometry: NotchGeometry) {
    let view = cardView()
    let expanded = NotchStyle.expandedSize(for: geometry, currentLine: "And nothing else matters", showsTransport: false)
    let pinned = NotchStyle.expandedSize(for: geometry, currentLine: "And nothing else matters", showsTransport: true)
    check(
        abs((pinned.height - expanded.height) - NotchStyle.transportRowHeight) < 0.5,
        "\(variant): the card grows by exactly the transport row (\(Int(expanded.height)) -> \(Int(pinned.height)) pt)"
    )
    check(
        abs(view.bounds.height - pinned.height) < 0.5,
        "\(variant): the pinned window matches the transport height (\(Int(view.bounds.height)) pt)"
    )
}

/// Hover-expanded cards must have no transport row at all.
func checkHoverHasNoTransport(_ variant: String, geometry: NotchGeometry) {
    let view = cardView()
    check(!view.showsTransport, "\(variant): a hover-expanded card shows no transport")
    let rowTop = view.bounds.height - NotchStyle.transportRowHeight
    let centre = NSPoint(x: view.bounds.midX, y: rowTop + NotchStyle.transportRowHeight / 2)
    check(view.transportCommand(at: centre) == nil, "\(variant): no button is hit without pinning")
    check(!view.isInTransportRow(centre), "\(variant): no transport band without pinning")
    let expected = NotchStyle.expandedSize(for: geometry, currentLine: "And nothing else matters", showsTransport: false)
    check(
        abs(view.bounds.height - expected.height) < 0.5,
        "\(variant): hover height has no transport row (\(Int(view.bounds.height)) pt)"
    )
}

/// The policy is pure, so its whole truth table is checked directly instead of
/// being inferred from pixel states.
func checkPolicy() {
    check(
        NotchLyricsController.presence(playback: .paused, hasLine: true, isPinned: true, isHovered: false, isObscured: false, pausedFor: 30) == .expanded,
        "policy: pin wins over the paused idle dot"
    )
    check(
        NotchLyricsController.presence(playback: .paused, hasLine: true, isPinned: true, isHovered: false, isObscured: true, pausedFor: 30) == .hidden,
        "policy: obscuring hides even a pinned card"
    )
    check(
        NotchLyricsController.presence(playback: .paused, hasLine: true, isPinned: false, isHovered: false, isObscured: false, pausedFor: 30) == .dot,
        "policy: paused 3 s is a dot"
    )
    check(
        NotchLyricsController.presence(playback: .paused, hasLine: true, isPinned: false, isHovered: false, isObscured: false, pausedFor: 2) == .collapsed,
        "policy: a fresh pause keeps the line"
    )
    check(
        NotchLyricsController.presence(playback: .paused, hasLine: true, isPinned: false, isHovered: true, isObscured: false, pausedFor: 30) == .expanded,
        "policy: hovering wakes the dot"
    )
    check(
        NotchLyricsController.presence(playback: .none, hasLine: false, isPinned: false, isHovered: false, isObscured: false, pausedFor: nil) == .dot,
        "policy: no track still shows the dot"
    )
    check(
        NotchLyricsController.presence(playback: .playing, hasLine: false, isPinned: false, isHovered: false, isObscured: false, pausedFor: nil) == .dot,
        "policy: playing without a line shows the dot"
    )
    check(
        NotchLyricsController.presence(playback: .playing, hasLine: true, isPinned: false, isHovered: false, isObscured: false, pausedFor: nil) == .collapsed,
        "policy: playing shows the line"
    )
    check(
        NotchLyricsController.presence(playback: .playing, hasLine: true, isPinned: false, isHovered: true, isObscured: false, pausedFor: nil) == .expanded,
        "policy: hovering expands"
    )
}

func renderSequence(_ variant: String, geometry: NotchGeometry) {
    // Centre of the first visible row, above the current line in the middle.
    let firstRowCenter = NotchStyle.contentTop(for: geometry) + NotchStyle.verticalPadding + NotchStyle.lineHeight / 2

    // 1. Playing: the current line only.
    controller.present(presentation(.playing), geometry: geometry, isObscured: false)
    wait(0.35)
    let collapsed = panel().frame
    print("[\(variant)] collapsed \(describe(collapsed))")
    check(panel().isVisible, "\(variant): playing shows the surface")
    check(collapsed.width >= geometry.notchFrame.width, "\(variant): collapsed is at least the notch wide")
    check(collapsed.maxY == geometry.notchFrame.maxY, "\(variant): card is flush with the screen top")
    snapshot("\(variant)-collapsed", geometry: geometry)

    // 2. Hover expands downward after the dwell.
    controller.setHovered(true)
    wait(0.5)
    let expanded = panel().frame
    print("[\(variant)] expanded  \(describe(expanded))")
    check(expanded.width > collapsed.width, "\(variant): hover grows the card wider")
    check(expanded.height > collapsed.height, "\(variant): hover grows the card downward")
    checkHoverHasNoTransport("\(variant)", geometry: geometry)
    snapshot("\(variant)-expanded", geometry: geometry)

    // 3. A click on an earlier line seeks to its timestamp.
    let seeksBefore = seeks.count
    controller.click(at: NSPoint(x: card().bounds.midX, y: firstRowCenter))
    check(
        seeks.count == seeksBefore + 1 && seeks.last == 10,
        "\(variant): clicking an earlier line seeks to 10 s"
    )

    // 4. Padding pins, and the pin outlives the pointer.
    controller.click(at: NSPoint(x: 4, y: card().bounds.midY))
    check(controller.isPinned, "\(variant): clicking padding pins")
    controller.setHovered(false)
    wait(0.9)
    check(controller.isPinned, "\(variant): pin survives the pointer leaving")
    check(panel().frame.height > collapsed.height, "\(variant): pinned card stays expanded")
    checkPinnedTransport("\(variant)", geometry: geometry)
    checkPinnedHeight("\(variant)", geometry: geometry)
    snapshot("\(variant)-pinned", geometry: geometry)

    // 5. Unpinning with the pointer away collapses after the grace period.
    controller.click(at: NSPoint(x: 4, y: card().bounds.midY))
    check(!controller.isPinned, "\(variant): clicking padding again unpins")
    wait(0.75)
    check(panel().frame.height == collapsed.height, "\(variant): unpinned card collapses after the grace")

    // 6. Pause: the line lingers for 3 s, then the surface becomes a dot.
    controller.present(presentation(.paused), geometry: geometry, isObscured: false)
    wait(2.5)
    check(panel().frame.width > 100, "\(variant): no dot before 3 s paused")
    wait(1.1)
    check(panel().frame.width == NotchStyle.dotHitSize, "\(variant): dot after 3 s paused")
    if !geometry.isSimulated {
        check(panel().frame.maxY <= geometry.notchFrame.minY, "\(variant): dot clears the hardware cutout")
    }
    print("[\(variant)] dot       \(describe(panel().frame))")
    snapshot("\(variant)-idle-dot", geometry: geometry)

    // 7. Resume brings the line back.
    controller.present(presentation(.playing), geometry: geometry, isObscured: false)
    wait(0.4)
    check(panel().frame.width > 100, "\(variant): resume brings the line back")

    // 8. Estimated timing disables seeking.
    controller.present(presentation(.playing, exact: false), geometry: geometry, isObscured: false)
    controller.setHovered(true)
    wait(0.5)
    let seeksBeforeEstimated = seeks.count
    controller.click(at: NSPoint(x: card().bounds.midX, y: firstRowCenter))
    check(seeks.count == seeksBeforeEstimated, "\(variant): seek is disabled with estimated timing")
    controller.setHovered(false)
    wait(0.5)

    // 9. Right-click asks for the menu.
    let menuBefore = menuPoints.count
    if let event = NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: NSPoint(x: card().bounds.midX, y: card().bounds.midY),
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: panel().windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ) {
        card().rightMouseDown(with: event)
    }
    check(menuPoints.count == menuBefore + 1, "\(variant): right-click requests the menu")

    // 10. No track leaves the dot, and a left click on it opens the menu.
    controller.present(LyricsPresentation(playback: .none), geometry: geometry, isObscured: false)
    wait(0.3)
    check(panel().isVisible, "\(variant): no track still shows the surface")
    check(panel().frame.width == NotchStyle.dotHitSize, "\(variant): no-track surface is the dot")
    let menuBeforeDot = menuPoints.count
    controller.click(at: NSPoint(x: card().bounds.midX, y: card().bounds.midY))
    check(menuPoints.count == menuBeforeDot + 1, "\(variant): left click on the dot opens the menu")
    let dotFrame = panel().frame
    controller.present(LyricsPresentation(playback: .none), geometry: geometry, isObscured: false)
    wait(0.4)
    check(panel().frame == dotFrame && panel().isVisible, "\(variant): repeated no-track presents are idempotent")

    // 11. Obscuring hides the window, keeps the pin, and restores it after.
    controller.present(presentation(.playing), geometry: geometry, isObscured: false)
    wait(0.2)
    controller.setHovered(true)
    wait(0.5)
    controller.click(at: NSPoint(x: 4, y: card().bounds.midY))
    check(controller.isPinned, "\(variant): pinned before obscuring")
    let pinnedFrame = panel().frame
    controller.present(presentation(.playing), geometry: geometry, isObscured: true)
    check(!panel().isVisible, "\(variant): obscuring hides the window")
    check(controller.isPinned, "\(variant): obscuring keeps the pin")
    controller.present(presentation(.playing), geometry: geometry, isObscured: false)
    wait(0.3)
    check(
        panel().isVisible && panel().frame == pinnedFrame,
        "\(variant): unobscured restores the pinned card"
    )

    // 12. Dismiss really stops rendering, unlike an obscure.
    transports.removeAll()
    controller.dismiss()
    wait(0.15)
    check(!panel().isVisible, "\(variant): dismiss stops rendering")
}

/// Row rects are private, so the harness probes them the way a click does: walk
/// the card downwards in 1 pt steps and record which slot each y reports.
func probeRows() -> [(y: CGFloat, slot: Int?)] {
    var probes: [(CGFloat, Int?)] = []
    var y: CGFloat = 0
    while y <= card().bounds.height {
        probes.append((y, cardView().slot(at: NSPoint(x: card().bounds.midX, y: y))))
        y += 1
    }
    return probes
}

func cardView() -> NotchCardView {
    guard let view = card() as? NotchCardView else {
        print("FAIL: panel content is not a NotchCardView")
        exit(1)
    }
    return view
}

/// The current row must wrap, never ellipsize; context rows stay one line.
func checkWrapping(_ variant: String, geometry: NotchGeometry) {
    let longText = "Sisa dunia seakan berputar ke arah yang sebaliknya dan aku terdiam"   // 458 pt: 2 rows
    let hugeText = "Sisa dunia seakan berputar ke arah yang sebaliknya tanpa henti dan tanpa arah yang jelas sama sekali sampai lupa waktu"

    func presentation(current: String) -> LyricsPresentation {
        var window = LyricsWindow.around(lyrics, at: 35)
        var lines = window.lines
        if let index = lines.firstIndex(where: { $0?.timestamp == 30 }) {
            lines[index] = LyricLine(timestamp: 30, text: current)
        }
        window = LyricsWindow(lines: lines, currentIndex: window.currentIndex)
        return LyricsPresentation(window: window, isTimingExact: true, trackKey: "preview", playback: .playing)
    }
    let column = NotchStyle.textColumnWidth(for: NotchStyle.maxWidth)
    print("[\(variant)] text column \(Int(column)) pt, card width \(Int(NotchStyle.maxWidth)) pt")
    check(NotchStyle.maxWidth == 460, "\(variant): expanded card is 460 pt wide")
    check(NotchStyle.collapsedMaxWidth == 420, "\(variant): the collapsed pill still caps at 420 pt")

    // (a) two rows, no ellipsis anywhere.
    let two = NotchText.wrapped(longText, font: NotchStyle.currentFont, to: column, maxRows: 2)
    for (index, row) in two.enumerated() {
        print("[\(variant)]   row \(index + 1): \"\(row)\" (\(Int(NotchText.width(of: row, font: NotchStyle.currentFont))) pt)")
    }
    check(two.count == 2, "\(variant): the long current line wraps to 2 rows")
    check(!two.contains { $0.contains("…") }, "\(variant): the wrapped current line has no ellipsis")
    check(
        two.joined(separator: " ") == longText,
        "\(variant): the 2 rows lose no characters"
    )
    check(two.allSatisfy { NotchText.width(of: $0, font: NotchStyle.currentFont) <= column }, "\(variant): both rows fit the column")

    // The card grows by exactly one row relative to a one-line current line.
    let oneRowHeight = NotchStyle.expandedSize(for: geometry, currentLine: "And nothing else matters", showsTransport: false).height
    let twoRowsHeight = NotchStyle.expandedSize(for: geometry, currentLine: longText, showsTransport: false).height
    check(
        abs((twoRowsHeight - oneRowHeight) - (NotchStyle.lineHeight + NotchStyle.wrappedLineSpacing)) < 0.5,
        "\(variant): the card grows by exactly one wrapped row (\(Int(oneRowHeight)) -> \(Int(twoRowsHeight)) pt)"
    )

    controller.dismiss()
    controller.present(presentation(current: longText), geometry: geometry, isObscured: false)
    wait(0.2)
    controller.setHovered(true)
    wait(0.5)
    check(
        abs(panel().frame.height - twoRowsHeight) < 0.5,
        "\(variant): the window matches the wrapped height (\(Int(panel().frame.height)) pt)"
    )
    snapshot("\(variant)-wrapped-two-rows", geometry: geometry)

    // (c) hit testing against the wrapped layout.
    let probes = probeRows()
    let slots = probes.compactMap { $0.slot }
    check(Set(slots) == Set(0...(NotchStyle.rowRadius * 2)), "\(variant): every slot is clickable")
    check(slots.contains(NotchStyle.rowRadius), "\(variant): the current row is clickable")

    // Each row's vertical run maps to its own slot, in order, and no slot's run
    // is interrupted by another slot.
    func runs() -> [(slot: Int, from: CGFloat, to: CGFloat)] {
        var result: [(Int, CGFloat, CGFloat)] = []
        for probe in probes {
            guard let slot = probe.slot else { continue }
            if let last = result.last, last.0 == slot {
                result[result.count - 1].2 = probe.y
            } else {
                result.append((slot, probe.y, probe.y))
            }
        }
        return result
    }
    let rowRuns = runs()
    for run in rowRuns {
        print("[\(variant)]   slot \(run.slot): y \(Int(run.from))-\(Int(run.to))")
    }
    check(rowRuns.map(\.slot) == Array(0...(NotchStyle.rowRadius * 2)), "\(variant): rows map to slots in order")
    check(
        rowRuns.first { $0.slot == NotchStyle.rowRadius }.map { $0.to - $0.from + 1 } ?? 0 > NotchStyle.lineHeight + 5,
        "\(variant): the current row's clickable run is taller than one line"
    )
    let gaps = probes.filter { $0.slot == nil }.count
    check(gaps > 0, "\(variant): the gaps between rows are misses (\(gaps) pt of \(Int(card().bounds.height)))")

    // A click in the middle of the current row seeks nothing and pins instead.
    if let currentRun = rowRuns.first(where: { $0.slot == NotchStyle.rowRadius }) {
        let before = seeks.count
        let pinnedBefore = controller.isPinned
        controller.click(at: NSPoint(x: card().bounds.midX, y: (currentRun.from + currentRun.to) / 2))
        check(seeks.count == before, "\(variant): clicking the current row does not seek")
        check(controller.isPinned != pinnedBefore, "\(variant): clicking the current row pins")
        controller.click(at: NSPoint(x: card().bounds.midX, y: (currentRun.from + currentRun.to) / 2))
        check(controller.isPinned == pinnedBefore, "\(variant): clicking it again unpins")
    }

    // (b) three rows needed: the second row is ellipsized, never a third line.
    let three = NotchText.wrapped(hugeText, font: NotchStyle.currentFont, to: column, maxRows: 2)
    for (index, row) in three.enumerated() {
        print("[\(variant)]   fallback row \(index + 1): \"\(row)\"")
    }
    check(three.count == 2, "\(variant): a too-long line stays at 2 rows")
    check(three.last?.hasSuffix("…") == true, "\(variant): the second row is the ellipsized fallback")
    check(
        NotchStyle.currentLineCount(hugeText) == 2,
        "\(variant): the height math also stops at 2 rows"
    )
    // From a clean expanded state, so the grace timer from the pin toggles above
    // cannot leave the card collapsed while it is being measured.
    controller.dismiss()
    controller.present(presentation(current: hugeText), geometry: geometry, isObscured: false)
    wait(0.15)
    controller.setHovered(true)
    wait(0.5)
    check(
        abs(panel().frame.height - twoRowsHeight) < 0.5,
        "\(variant): the fallback keeps the same height (no third line)"
    )
    snapshot("\(variant)-wrapped-fallback", geometry: geometry)

    // Context rows keep one line with a tail ellipsis.
    let context = NotchText.fitted(hugeText, font: NotchStyle.lineFont, to: column)
    check(
        NotchText.width(of: context, font: NotchStyle.lineFont) <= column && context.hasSuffix("…"),
        "\(variant): a context row is one ellipsized line"
    )
    controller.dismiss()
    seeks.removeAll()
}

checkPolicy()
renderSequence("simulated", geometry: syntheticGeometry(simulated: true))
renderSequence("hardware", geometry: syntheticGeometry(simulated: false))
checkWrapping("simulated", geometry: syntheticGeometry(simulated: true))
checkWrapping("hardware", geometry: syntheticGeometry(simulated: false))

print(failures == 0 ? "PASS: all checks passed" : "FAIL: \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
