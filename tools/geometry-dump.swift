// Throwaway harness: prints the notch geometry the app resolves for every
// attached display and checks the invariants behind it. Not part of the app
// target and not referenced by the Makefile.
//
// NotchGeometry.swift is a separate source file, and a multi-file swiftc build
// only accepts top-level code in a file named main.swift, so the harness is
// linked under that name. Build and run from the repository root:
//
//   mkdir -p build/geometry-dump
//   ln -sfn "$PWD/tools/geometry-dump.swift" build/geometry-dump/main.swift
//   CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" swiftc \
//     -target "$(uname -m)-apple-macos12.0" -framework Cocoa \
//     -o build/geometry-dump/geometry-dump \
//     Sources/SpotifyLyricsMenuBar/NotchGeometry.swift build/geometry-dump/main.swift
//   ./build/geometry-dump/geometry-dump

import Cocoa

var failures = 0

func check(_ condition: Bool, _ label: String) {
    print("  \(condition ? "ok  " : "FAIL") \(label)")
    if !condition { failures += 1 }
}

func describe(_ rect: NSRect?) -> String {
    guard let rect else { return "nil" }
    return String(format: "x %.0f  y %.0f  w %.0f  h %.0f", rect.minX, rect.minY, rect.width, rect.height)
}

func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return number.map { CGDirectDisplayID($0.uint32Value) }
}

func isBuiltIn(_ screen: NSScreen) -> Bool {
    displayID(screen).map { CGDisplayIsBuiltin($0) != 0 } ?? false
}

func label(_ screen: NSScreen) -> String {
    "\(screen.localizedName) [\(NotchDisplays.id(of: screen))]"
}

/// Compares screens by id: the harness must not depend on AppKit handing back
/// the same NSScreen instance, even though it usually does.
func isSameScreen(_ lhs: NSScreen?, _ rhs: NSScreen?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (lhs?, rhs?): return NotchDisplays.id(of: lhs) == NotchDisplays.id(of: rhs)
    default: return false
    }
}

let screens = NSScreen.screens
print("attached screens: \(screens.count)")

for (index, screen) in screens.enumerated() {
    let frame = screen.frame
    let geometry = NotchDisplays.geometry(for: screen)
    print("\n[\(index)] \(label(screen))")
    print("  frame                 \(describe(frame))")
    print("  safeAreaInsets.top    \(screen.safeAreaInsets.top)")
    print("  auxiliaryTopLeftArea  \(describe(screen.auxiliaryTopLeftArea))")
    print("  auxiliaryTopRightArea \(describe(screen.auxiliaryTopRightArea))")
    print("  notchFrame            \(describe(geometry.notchFrame))")
    print("  isSimulated           \(geometry.isSimulated)")

    check(isSameScreen(geometry.screen, screen), "geometry carries this screen")
    check(abs(geometry.notchFrame.maxY - frame.maxY) < 0.5, "notch touches the top edge")
    check(abs(geometry.notchFrame.midX - frame.midX) < 0.5, "notch is horizontally centered")
    check(frame.contains(geometry.notchFrame), "notch lies inside the screen")
    check((screen.safeAreaInsets.top > 0) == !geometry.isSimulated, "simulated exactly where there is no top inset")

    let screenID = NotchDisplays.id(of: screen)
    check(!screenID.isEmpty && screenID == NotchDisplays.id(of: screen), "screen id \(screenID) is non-empty and repeatable")

    if geometry.isSimulated {
        check(geometry.notchFrame.size == NSSize(width: 200, height: 32), "simulated notch is 200x32")
    } else {
        check(geometry.notchFrame.height == screen.safeAreaInsets.top, "notch height equals the top safe-area inset")
        check(geometry.notchFrame.width > 0, "notch has a positive width")
    }
}

print("\npreferredScreen")
let expectedDefault = screens.first { isBuiltIn($0) && !NotchDisplays.geometry(for: $0).isSimulated } ?? screens.first
let defaultScreen = NotchDisplays.preferredScreen(override: nil)
check(defaultScreen != nil, "returns a screen")
check(isSameScreen(defaultScreen, expectedDefault), "defaults to built-in notched display, else the menu-bar display")
print("  default          -> \(defaultScreen.map(label) ?? "nil")")

if let first = screens.first {
    let attached = NotchDisplays.preferredScreen(override: NotchDisplays.id(of: first))
    check(isSameScreen(attached, first), "an attached override wins")
    print("  attached id      -> \(attached.map(label) ?? "nil")")
}

let stale = NotchDisplays.preferredScreen(override: "00000000-0000-0000-0000-000000000000")
check(isSameScreen(stale, expectedDefault), "a stale override falls back to the default")
print("  stale id         -> \(stale.map(label) ?? "nil")")

print("\n" + (failures == 0 ? "PASS: all checks passed" : "FAIL: \(failures) check(s) failed"))
exit(failures == 0 ? 0 : 1)
