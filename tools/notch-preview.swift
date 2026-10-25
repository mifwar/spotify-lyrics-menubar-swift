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
        try png.write(to: outputDirectory.appendingPathComponent("T10-\(name).png"))
        print("wrote T10-\(name).png (\(Int(cardImage.size.width))×\(Int(cardImage.size.height)) card)")
    } catch {
        check(false, "could not write \(name): \(error.localizedDescription)")
    }
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
    controller.dismiss()
    wait(0.15)
    check(!panel().isVisible, "\(variant): dismiss stops rendering")
}

checkPolicy()
renderSequence("simulated", geometry: syntheticGeometry(simulated: true))
renderSequence("hardware", geometry: syntheticGeometry(simulated: false))

print(failures == 0 ? "PASS: all checks passed" : "FAIL: \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
