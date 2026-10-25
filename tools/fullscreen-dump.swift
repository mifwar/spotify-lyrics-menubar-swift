// Throwaway harness: prints the live fullscreen answer on this machine and
// exercises the pure predicate with synthetic windows. Not part of the app
// target and not referenced by the Makefile's app rule.
//
// FullscreenApps.swift is a separate source file, and a multi-file swiftc build
// only accepts top-level code in a file named main.swift, so the harness is
// linked under that name. From the repository root:
//
//   mkdir -p build/fullscreen-dump
//   ln -sfn "$PWD/tools/fullscreen-dump.swift" build/fullscreen-dump/main.swift
//   CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" swiftc \
//     -target "$(uname -m)-apple-macos12.0" -framework Cocoa \
//     -o build/fullscreen-dump/fullscreen-dump \
//     Sources/SpotifyLyricsMenuBar/FullscreenApps.swift build/fullscreen-dump/main.swift
//   ./build/fullscreen-dump/fullscreen-dump

import Cocoa

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
let ignored = FullscreenApps.ignoredBundleIDs

func screen(_ frame: NSRect, dockHeight: CGFloat = 0, menuBarHeight: CGFloat = 0) -> FullscreenApps.ScreenBounds {
    let visible = NSRect(
        x: frame.minX,
        y: frame.minY + dockHeight,
        width: frame.width,
        height: frame.height - dockHeight - menuBarHeight
    )
    return FullscreenApps.ScreenBounds(frame: frame, visibleFrame: visible)
}

func window(
    _ rect: NSRect,
    layer: Int = 0,
    pid: Int32 = 2000,
    bundle: String? = "com.example.app"
) -> FullscreenApps.Window {
    FullscreenApps.Window(bounds: rect, ownerPID: pid, layer: layer, bundleID: bundle)
}

// A notched laptop with a menu bar and a Dock, and a big external display with
// only a Dock: the tolerance and the per-screen answer differ between them.
let laptop = screen(NSRect(x: 0, y: 0, width: 1512, height: 982), dockHeight: 70, menuBarHeight: 32)
let external = screen(NSRect(x: 1512, y: 0, width: 2560, height: 1440), dockHeight: 90)
print("screens under test")
print("  laptop   frame \(laptop.frame) menuBar \(laptop.menuBarHeight) menuBar band")
print("  external frame \(external.frame) menuBar \(external.menuBarHeight) menuBar band")

print("\nsynthetic windows")
check(
    FullscreenApps.isBlocking(window(NSRect(x: 0, y: 0, width: 1512, height: 982)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "exact screen coverage blocks"
)
check(
    FullscreenApps.isBlocking(window(NSRect(x: 0, y: 0, width: 1512, height: 950)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "top edge stopping at the menu bar still blocks (menu bar tolerance)"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 4, y: 4, width: 1504, height: 974)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "slightly inset on every side does not block (conservative)"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 70, width: 1512, height: 912)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a window above a visible Dock does not block"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 600, y: 400, width: 300, height: 200)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a tiny window does not block"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 0, width: 1512, height: 982), layer: 20), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "the Dock's layer does not block"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 950, width: 1512, height: 32), layer: 24), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "the menu bar's layer does not block"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 0, width: 1512, height: 982), layer: 2147483646), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "the window server's own layer does not block"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 0, width: 1512, height: 982), pid: ownPID), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "our own pid does not block"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 0, width: 1512, height: 982), bundle: "com.spotify.client"), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "Spotify is on the ignore list"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 950, width: 1512, height: 32), bundle: "local.spotify-lyrics-menubar"), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a second copy of ourselves is on the ignore list"
)
check(
    FullscreenApps.isBlocking(window(NSRect(x: -30, y: -30, width: 1572, height: 1042)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a window larger than the screen (shadow overshoot) blocks"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: 0, y: 0, width: 0, height: 0)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a zero-sized window does not block"
)
check(
    !FullscreenApps.isBlocking(window(NSRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan)), on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "NaN geometry does not block"
)
check(
    FullscreenApps.isBlocking(
        windows: [
            window(NSRect(x: 600, y: 400, width: 300, height: 200)),
            window(NSRect(x: 1512, y: 0, width: 2560, height: 1440)),
        ],
        on: external, ownPID: ownPID, ignoredBundleIDs: ignored
    ),
    "any blocking window in the list is enough"
)

print("\nmulti-display")
let externalFullscreen = window(NSRect(x: 1512, y: 0, width: 2560, height: 1440), bundle: "com.example.game")
check(
    !FullscreenApps.isBlocking(windows: [externalFullscreen], on: laptop, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a fullscreen app on the external display does not block the laptop"
)
check(
    FullscreenApps.isBlocking(windows: [externalFullscreen], on: external, ownPID: ownPID, ignoredBundleIDs: ignored),
    "the same window blocks its own display"
)
check(
    FullscreenApps.isBlocking(windows: [window(NSRect(x: 1512, y: 0, width: 2560, height: 1440))], on: external, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a display without a menu bar needs exact coverage, no tolerance"
)
check(
    !FullscreenApps.isBlocking(windows: [window(NSRect(x: 1512, y: 0, width: 2560, height: 1340))], on: external, ownPID: ownPID, ignoredBundleIDs: ignored),
    "a display without a menu bar rejects a 100 pt gap"
)

// MARK: - Live window list

print("\nlive window list")
let liveWindows = FullscreenApps.currentWindows()
print("  windows: \(liveWindows.count)")

// The window server always owns a window covering each display exactly; it is
// the conversion oracle: if the y flip or the offset were wrong, these would
// not land on the AppKit screen frames.
for screen in NSScreen.screens {
    let exact = liveWindows.contains { abs($0.bounds.minX - screen.frame.minX) < 0.5 && abs($0.bounds.minY - screen.frame.minY) < 0.5 && abs($0.bounds.width - screen.frame.width) < 0.5 && abs($0.bounds.height - screen.frame.height) < 0.5 }
    check(exact, "a live window converts to exactly \(screen.localizedName)'s frame \(screen.frame)")
}

if let primary = NSScreen.screens.first,
   let menuBar = liveWindows.filter({ $0.layer == 24 }).max(by: { $0.bounds.height < $1.bounds.height }) {
    check(
        abs(menuBar.bounds.maxY - primary.frame.maxY) < 0.5,
        "the live menu-bar window converts to the top edge (maxY \(menuBar.bounds.maxY) vs screen \(primary.frame.maxY))"
    )
} else {
    print("  --   no layer-24 menu-bar window in the list; top-edge check skipped")
}

let primaryAppWindows = liveWindows.filter { $0.layer == 0 && $0.bundleID != nil }
print("  layer-0 app windows: \(primaryAppWindows.count)")
for window in primaryAppWindows.prefix(8) {
    print("    \(window.bundleID ?? "?") pid=\(window.ownerPID) bounds=\(window.bounds)")
}

print("\nlive answers")
for screen in NSScreen.screens {
    let bounds = FullscreenApps.ScreenBounds(frame: screen.frame, visibleFrame: screen.visibleFrame)
    let blocking = liveWindows.filter { FullscreenApps.isBlocking($0, on: bounds, ownPID: ownPID, ignoredBundleIDs: ignored) }
    let answer = FullscreenApps.isBlocking(screen: screen, ownPID: ownPID)
    print("  \(screen.localizedName): menuBarHeight=\(bounds.menuBarHeight) blockingWindows=\(blocking.map { $0.bundleID ?? "pid \($0.ownerPID)" }) -> isBlocking=\(answer)")
    check(
        blocking.isEmpty || answer,
        "the per-window and per-screen answers agree on \(screen.localizedName)"
    )
    check(
        !blocking.contains { $0.ownerPID == ownPID },
        "no window of our own pid blocks \(screen.localizedName)"
    )
}

if failures == 0 {
    print("\nPASS: all checks passed")
} else {
    print("\nFAIL: \(failures) check(s) failed")
}
exit(failures == 0 ? 0 : 1)
